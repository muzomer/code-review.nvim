-- A review agent that needs no open terminal: a coding agent started in the
-- background (`claude -p`, `codex exec`, `opencode run`, `gemini -p`; see
-- agents.lua), one conversation per review.
--
-- The first poke starts a new session and remembers it in
-- <root>/.code-review/headless.json; every later poke resumes it, so the agent
-- keeps what it learned about the PR. Runs start in <root>, because agents file
-- their sessions by directory. A poke can also run a throwaway fork of another
-- session (agents that support it), which is never saved. `:CodeReview chat`
-- opens the review's conversation interactively.
local store = require("code-review.store")
local agents = require("code-review.agents")

local api = vim.api
local uv = vim.uv or vim.loop

local M = {}

M.MAX_LINES = 500 -- output lines kept per run

local runs = {} -- root -> { handle, lines, status = "working"|"done"|"failed", error?, t0, queued? }
local chats = {} -- root -> terminal job id of an open `:CodeReview chat`

local function cfg()
  return require("code-review").config.headless or {}
end

local function notify(msg, level)
  vim.notify("code-review: " .. msg, level or vim.log.levels.INFO)
end

---The adapter of the background agent (config.headless.agent, default "claude").
---@param name? string another adapter (e.g. the agent of a session to fork)
function M.adapter(name)
  return agents.get(name or cfg().agent or "claude") or agents.claude
end

---Its executable: config.headless.cmd for the configured agent, else the adapter's.
function M.command(name)
  local own = not name or name == (cfg().agent or "claude")
  return own and cfg().cmd or M.adapter(name).cmd
end

---Can that agent (default: the configured one) be started here?
function M.available(name)
  return vim.fn.executable(M.command(name)) == 1
end

-- Session id -------------------------------------------------------------------

local function session_file(root)
  return (store.paths(root)) .. "/headless.json"
end

---The id of this review's background session, if one was started with the
---configured agent.
---@return string?
function M.session_id(root)
  local f = io.open(session_file(root), "r")
  if not f then
    return nil
  end
  local s = f:read("a")
  f:close()
  local ok, data = pcall(vim.json.decode, s)
  if not (ok and type(data) == "table") then
    return nil
  end
  if (data.agent or "claude") ~= (cfg().agent or "claude") then
    return nil -- started with another agent: start anew
  end
  return data.session_id
end

local function save_session_id(root, id)
  store.ensure_dir(root)
  local f = assert(io.open(session_file(root), "w"))
  f:write(vim.json.encode({ session_id = id, agent = cfg().agent or "claude" }), "\n")
  f:close()
end

---Forget this review's session (the next poke starts a new conversation).
function M.forget(root)
  os.remove(session_file(root))
end

---A random (version 4) UUID, the form `--session-id` accepts.
function M.uuid()
  local b = { uv.random(16):byte(1, 16) }
  b[7] = bit.bor(bit.band(b[7], 0x0f), 0x40)
  b[9] = bit.bor(bit.band(b[9], 0x3f), 0x80)
  local hex = {}
  for i, v in ipairs(b) do
    hex[i] = string.format("%02x", v)
  end
  local h = table.concat(hex)
  return string.format("%s-%s-%s-%s-%s", h:sub(1, 8), h:sub(9, 12), h:sub(13, 16), h:sub(17, 20), h:sub(21, 32))
end

-- Arguments ---------------------------------------------------------------------

M.DEFAULT_TOOLS = agents.claude.DEFAULT_TOOLS

---Command line of a run. `resume` = id of the session to continue, `new_id` =
---id for a new one (agents that take one), `fork` = id of a session to copy.
---@param opts { resume?: string, new_id?: string, fork?: string, agent?: string, cwd?: string }
function M.args(root, text, opts)
  local a = M.adapter(opts.agent)
  local dirs = {}
  -- the snapshots of a PR review live in the cache, outside the session root
  local s = require("code-review.session").load(root)
  local pr = s and s.kind == "pr"
  if pr and s.cache then
    dirs[1] = s.cache
  end
  local cwd = opts.cwd or root
  if not pr and vim.fs.normalize(cwd) ~= vim.fs.normalize(root) then
    dirs[#dirs + 1] = root -- a fork runs where its session started: give it the reviewed project
  end
  local args = a.args({
    cmd = M.command(opts.agent), prompt = text, cwd = cwd, dirs = dirs, cfg = cfg(),
    new_id = opts.new_id, resume = opts.resume, fork = opts.fork,
    edit = not pr and root or nil, -- a local review asks for code changes; a PR has no checkout to change
  })
  vim.list_extend(args, cfg().args or {})
  return args
end

-- Output ----------------------------------------------------------------------------

local function one_line(s, max)
  s = tostring(s or ""):gsub("%s+", " ")
  return #s > max and (s:sub(1, max - 1) .. "…") or s
end

---Readable lines for one Claude Code stream-json event (kept for callers and tests).
---@return string[] lines
---@return table? result the final "result" event
function M.describe(event)
  local r = agents.claude.parse(event) or {}
  return r.lines or {}, r.done and event or nil
end

local function push(run, lines)
  for _, l in ipairs(lines) do
    run.lines[#run.lines + 1] = l
  end
  if #run.lines > M.MAX_LINES then
    run.lines = vim.list_slice(run.lines, #run.lines - M.MAX_LINES + 1, #run.lines)
  end
end

---Output of the current (or last) run of this review.
function M.lines(root)
  local run = runs[root]
  return run and run.lines or {}
end

---@return { status: "working"|"done"|"failed", error?: string, seq: integer }?
function M.status(root)
  local run = runs[root]
  return run and { status = run.status, error = run.error, seq = run.seq }
end

function M.running(root)
  return runs[root] ~= nil and runs[root].status == "working"
end

-- Process ---------------------------------------------------------------------------

---Start a process, calling `on_line` for each line of stdout and `on_exit` at
---the end, both on the main loop. Replaceable in tests.
---@return { kill: fun() }
M.spawn = function(args, cwd, on_line, on_exit, env)
  local pending = ""
  local h = vim.system(args, {
    cwd = cwd,
    -- `code-review` resolves even before setup() put it on PATH (unless the user opted out)
    env = require("code-review").config.add_bin_to_path ~= false
        and vim.tbl_extend("force", env or {}, { PATH = agents.path_with_bin(vim.env.PATH) })
      or env,
    text = true,
    stdin = "",
    stdout = function(_, data)
      if not data then
        return
      end
      pending = pending .. data
      while true do
        local nl = pending:find("\n", 1, true)
        if not nl then
          break
        end
        local line = pending:sub(1, nl - 1)
        pending = pending:sub(nl + 1)
        vim.schedule(function()
          on_line(line)
        end)
      end
    end,
  }, function(res)
    vim.schedule(function()
      if pending ~= "" then -- a last line without a newline (often the result)
        on_line(pending)
        pending = ""
      end
      on_exit(res.code, res.stderr or "", res.signal)
    end)
  end)
  return {
    kill = function()
      pcall(h.kill, h, "sigterm")
    end,
  }
end

local start -- forward: queued pokes start again from the exit handler

---What to do with a poke that arrives while this review's agent is still busy.
---@param run table the run in progress (run.t0: start time, run.seq, run.queued)
---@return "queue"|"restart"|"ignore"
function M.busy_policy(run)
  -- TODO(human)
  return "queue"
end

---@param on_start? fun() called each time a run starts (also a queued one)
---@param fork? { id: string, cwd: string, agent?: string } run a throwaway copy of this session instead
start = function(root, text, on_start, retried, fork)
  local a = M.adapter(fork and fork.agent)
  local saved = not fork and M.session_id(root) or nil
  local new_id = not fork and not saved and a.preset_id and M.uuid() or nil
  if new_id then
    save_session_id(root, new_id) -- before the run, so a second poke resumes it
  end
  local prev = runs[root]
  local run = {
    lines = {},
    status = "working",
    t0 = uv.hrtime(),
    seq = (prev and prev.seq or 0) + 1,
    text = text,
    on_start = on_start,
    fork = fork,
  }
  runs[root] = run
  local first = fork and ("fork of session " .. fork.id)
    or saved and ("resuming session " .. saved)
    or ("new session" .. (new_id and (" " .. new_id) or ""))
  push(run, { string.format("● %s · %s", a.name, first) })
  local cwd = fork and fork.cwd or root -- agents file sessions by the directory they started in
  local partial -- text streamed in pieces (delta events), shown as it grows
  local function flush()
    partial = nil
  end
  local function on_line(line)
    local ok, event = pcall(vim.json.decode, line, { luanil = { object = true, array = true } })
    if not ok or type(event) ~= "table" then
      flush()
      return push(run, { line })
    end
    local r = a.parse(event) or {}
    if r.session_id and not fork and not saved and not new_id and r.session_id ~= M.session_id(root) then
      save_session_id(root, r.session_id) -- agents that pick their own id
    end
    if r.append then
      if partial then
        run.lines[#run.lines] = run.lines[#run.lines] .. r.append
      else
        push(run, { r.append })
        partial = true
      end
      local last = run.lines[#run.lines]
      if last:find("\n", 1, true) then -- keep one line per row
        run.lines[#run.lines] = nil
        push(run, vim.split(last, "\n", { plain = true }))
      end
    elseif r.lines and #r.lines > 0 then
      flush()
      push(run, r.lines)
    end
    if r.error and not r.done then
      push(run, { "⚠ " .. one_line(r.error, 200) })
    end
    if r.done then
      run.result = r
    end
  end
  local function on_exit(code, stderr, signal)
    if runs[root] ~= run then
      return -- replaced (restarted) meanwhile
    end
    local r = run.result
    if signal and signal ~= 0 and not (r and r.done) then
      code = code ~= 0 and code or 128 + signal -- killed (OOM, pkill): not "done"
      stderr = vim.trim(stderr .. " killed by signal " .. signal)
    end
    if code == 0 and not (r and r.error) then
      run.status = "done"
      push(run, { "✓ done" .. (r and r.cost and string.format(" · $%.2f", r.cost) or "") })
    else
      local err = vim.trim((r and r.error) or stderr or "")
      if err == "" then
        err = "exit code " .. tostring(code)
      end
      -- the saved session is gone (deleted, or never written): start a new one once
      if saved and not retried and a.lost_session and a.lost_session(err) then
        M.forget(root)
        local again = start(root, text, on_start, true)
        if again then
          again.queued = run.queued -- a poke that waited for this run still waits
        elseif run.queued then -- the retry could not start (already reported): try the queued poke
          start(root, run.queued.text, run.queued.on_start, nil, run.queued.fork)
        end
        return
      end
      run.status, run.error = "failed", one_line(err, 200)
      push(run, { "✗ " .. run.error })
      if require("code-review").config.progress == false then -- nothing else reports it
        notify(string.format("%s failed: %s", a.name, run.error), vim.log.levels.ERROR)
      end
    end
    local q = run.queued
    if q then
      start(root, q.text, q.on_start, nil, q.fork)
    end
  end
  -- M.args (a bad config.headless.args) and vim.system (missing command or
  -- directory) can throw: the run must not stay "working" then
  local spawned, handle = pcall(function()
    local args = M.args(root, text, { resume = saved, new_id = new_id, fork = fork and fork.id, agent = fork and fork.agent, cwd = cwd })
    -- a fork runs where its session started: point the CLI at this project anyway
    return M.spawn(args, cwd, on_line, on_exit, { NVIM_CODE_REVIEW_ROOT = root })
  end)
  if not spawned then -- vim.system throws when the command or its directory is missing
    if new_id then
      M.forget(root) -- that session was never created
    end
    run.status, run.error = "failed", one_line(tostring(handle), 200)
    push(run, { "✗ " .. run.error })
    notify(string.format("could not start %s: %s", a.name, run.error), vim.log.levels.ERROR)
    return nil
  end
  run.handle = handle
  if on_start then
    on_start()
  end
  return run
end

---Send `text` to this review's background agent, starting or resuming it.
---@param on_start? fun() called when a run starts (now, or later for a queued poke)
---@param opts? { fork?: { id: string, cwd: string, agent?: string } } run a throwaway fork of that session
---@return boolean started false when the poke was queued or ignored
---@return boolean accepted false when nothing will deliver it (ignored, or a chat is open)
function M.send(root, text, on_start, opts)
  opts = opts or {}
  if chats[root] then
    vim.fn.setreg('"', text)
    pcall(vim.fn.setreg, "+", text)
    notify("the review agent is open in :CodeReview chat; the prompt is copied, paste it there", vim.log.levels.WARN)
    return false, false
  end
  local run = runs[root]
  if run and run.status == "working" then
    local policy = M.busy_policy(run)
    if policy == "queue" then
      run.queued = { text = text, on_start = on_start, fork = opts.fork }
      notify("the agent is still working; it will check your comments again when it is done")
      return false, true
    elseif policy == "ignore" then
      notify("the agent is still working on your comments")
      return false, false
    end
    runs[root] = nil -- restart: the exit handler of the old run sees it was replaced
    run.handle.kill()
  end
  if not start(root, text, on_start, nil, opts.fork) then
    return false, false -- could not start (already reported)
  end
  return true, true
end

---Stop every background agent still working (Neovim is quitting: a run left
---behind would keep editing files and replying with nobody watching).
function M.stop_all()
  for root, run in pairs(runs) do
    if run.status == "working" and run.handle then
      runs[root] = nil
      run.handle.kill()
    end
  end
end

api.nvim_create_autocmd("VimLeavePre", {
  group = api.nvim_create_augroup("code-review-headless", { clear = true }),
  callback = function()
    M.stop_all()
  end,
})

---Stop the background agent of this review (the session is kept).
function M.stop(root)
  local run = runs[root]
  if run and run.status == "working" then
    runs[root] = nil
    run.handle.kill()
    return true
  end
  return false
end

-- Interactive chat -----------------------------------------------------------------------

---Open this review's conversation interactively in a terminal split.
function M.chat(root)
  local id = M.session_id(root)
  if not id then
    return notify("no background agent yet for this review; poke first", vim.log.levels.WARN)
  end
  if M.running(root) then
    return notify("the background agent is still working; wait until it is done (or :CodeReview stop)", vim.log.levels.WARN)
  end
  if chats[root] then
    return notify("this review's agent is already open in a chat", vim.log.levels.WARN)
  end
  if not M.available() then
    return notify(M.command() .. " not found; set config.headless.cmd", vim.log.levels.ERROR)
  end
  vim.cmd("botright vsplit")
  local win = api.nvim_get_current_win()
  local buf = api.nvim_create_buf(false, true)
  api.nvim_win_set_buf(win, buf)
  local opts = {
    cwd = root,
    on_exit = function()
      chats[root] = nil
    end,
  }
  local cmd = M.adapter().chat(M.command(), id)
  local ok, job
  if vim.fn.has("nvim-0.11") == 1 then
    opts.term = true
    ok, job = pcall(vim.fn.jobstart, cmd, opts)
  else
    ok, job = pcall(vim.fn.termopen, cmd, opts) -- Neovim 0.10: jobstart() has no `term` yet
  end
  if not ok or job <= 0 then
    pcall(api.nvim_win_close, win, true) -- no empty split left behind
    return notify("could not start " .. M.command() .. (ok and "" or (": " .. tostring(job))), vim.log.levels.ERROR)
  end
  chats[root] = job
  vim.cmd.startinsert()
end

---For tests: forget every run.
function M._reset()
  runs, chats = {}, {}
end

return M
