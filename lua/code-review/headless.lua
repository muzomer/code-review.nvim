-- A review agent that needs no open terminal: `claude -p` started in the
-- background, one conversation per review.
--
-- The first poke starts a new Claude Code session with an id chosen here
-- (`--session-id`) and remembers it in <root>/.code-review/headless.json; every
-- later poke resumes it (`--resume`), so the agent keeps what it learned about
-- the PR. The run always starts in <root>, because Claude Code files sessions
-- under the directory they were started in. `:CodeReview chat` opens the same
-- conversation interactively.
local store = require("code-review.store")

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

function M.command()
  return cfg().cmd or "claude"
end

---Can a background agent be started here?
function M.available()
  return vim.fn.executable(M.command()) == 1
end

-- Session id -------------------------------------------------------------------

local function session_file(root)
  return (store.paths(root)) .. "/headless.json"
end

---The id of this review's Claude Code session, if one was started.
---@return string?
function M.session_id(root)
  local f = io.open(session_file(root), "r")
  if not f then
    return nil
  end
  local s = f:read("a")
  f:close()
  local ok, data = pcall(vim.json.decode, s)
  return ok and type(data) == "table" and data.session_id or nil
end

local function save_session_id(root, id)
  store.ensure_dir(root)
  local f = assert(io.open(session_file(root), "w"))
  f:write(vim.json.encode({ session_id = id }), "\n")
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

M.DEFAULT_TOOLS = { "Bash(code-review:*)", "Read", "Grep", "Glob" }

---Command line of a run. `resume` = id of the session to continue, else `new_id`
---starts a new one; `fork` = id of a session to copy (the copy is thrown away).
function M.args(root, text, opts)
  local c = cfg()
  local args = { M.command(), "-p", text, "--output-format", "stream-json", "--verbose" }
  if opts.fork then
    vim.list_extend(args, { "--resume", opts.fork, "--fork-session" })
  elseif opts.resume then
    vim.list_extend(args, { "--resume", opts.resume })
  else
    vim.list_extend(args, { "--session-id", opts.new_id })
  end
  local tools = c.allowed_tools or M.DEFAULT_TOOLS
  if #tools > 0 then
    args[#args + 1] = "--allowedTools"
    vim.list_extend(args, tools)
  end
  if c.permission_mode then
    vim.list_extend(args, { "--permission-mode", c.permission_mode })
  end
  -- the snapshots of a PR review live in the cache, outside the session root
  local s = require("code-review.session").load(root)
  if s and s.kind == "pr" and s.cache then
    vim.list_extend(args, { "--add-dir", s.cache })
  end
  vim.list_extend(args, c.args or {})
  return args
end

-- Output ----------------------------------------------------------------------------

local function one_line(s, max)
  s = tostring(s or ""):gsub("%s+", " ")
  return #s > max and (s:sub(1, max - 1) .. "…") or s
end

---Readable lines for one stream-json event (may be none).
---@return string[] lines
---@return table? result the final "result" event
function M.describe(event)
  local out = {}
  if event.type == "assistant" and event.message then
    for _, c in ipairs(event.message.content or {}) do
      if c.type == "text" and (c.text or "") ~= "" then
        vim.list_extend(out, vim.split(vim.trim(c.text), "\n", { plain = true }))
      elseif c.type == "tool_use" then
        local i = c.input or {}
        local what = i.command or i.file_path or i.pattern or i.path or i.description or ""
        out[#out + 1] = string.format("→ %s %s", c.name or "tool", one_line(what, 120))
      end
    end
  elseif event.type == "result" then
    return out, event
  end
  return out
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
M.spawn = function(args, cwd, on_line, on_exit)
  local pending = ""
  local h = vim.system(args, {
    cwd = cwd,
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
      on_exit(res.code, res.stderr or "")
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
---@param fork? { id: string, cwd: string } run a throwaway copy of this session instead
start = function(root, text, on_start, retried, fork)
  local saved = not fork and M.session_id(root) or nil
  local new_id = not fork and not saved and M.uuid() or nil
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
  push(run, { fork and ("● fork of session " .. fork.id)
    or string.format("● %s %s", saved and "resuming session" or "new session", saved or new_id) })
  local args = M.args(root, text, { resume = saved, new_id = new_id, fork = fork and fork.id })
  -- a fork must start where its session was started: Claude Code files sessions by directory
  run.handle = M.spawn(args, fork and fork.cwd or root, function(line)
    local ok, event = pcall(vim.json.decode, line, { luanil = { object = true, array = true } })
    if not ok or type(event) ~= "table" then
      return push(run, { line })
    end
    local lines, result = M.describe(event)
    push(run, lines)
    if result then
      run.result = result
    end
  end, function(code, stderr)
    if runs[root] ~= run then
      return -- replaced (restarted) meanwhile
    end
    local r = run.result
    if code == 0 and not (r and r.is_error) then
      run.status = "done"
      push(run, { "✓ done" .. (r and r.total_cost_usd and string.format(" · $%.2f", r.total_cost_usd) or "") })
    else
      local err = vim.trim((r and r.result) or stderr or "")
      if err == "" then
        err = "exit code " .. tostring(code)
      end
      -- the saved session is gone (deleted, or never written): start a new one once
      if saved and not retried and err:lower():find("no conversation found", 1, true) then
        M.forget(root)
        return start(root, text, on_start, true)
      end
      run.status, run.error = "failed", one_line(err, 200)
      push(run, { "✗ " .. run.error })
    end
    local q = run.queued
    if q then
      start(root, q.text, q.on_start, nil, q.fork)
    end
  end)
  if on_start then
    on_start()
  end
  return run
end

---Send `text` to this review's background agent, starting or resuming it.
---@param on_start? fun() called when a run starts (now, or later for a queued poke)
---@param opts? { fork?: { id: string, cwd: string } } run a throwaway fork of that session
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
  start(root, text, on_start, nil, opts.fork)
  return true, true
end

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
  vim.cmd("botright vsplit")
  local buf = api.nvim_create_buf(false, true)
  api.nvim_win_set_buf(0, buf)
  local job = vim.fn.jobstart({ M.command(), "--resume", id }, {
    cwd = root,
    term = true,
    on_exit = function()
      chats[root] = nil
    end,
  })
  if job <= 0 then
    return notify("could not start " .. M.command(), vim.log.levels.ERROR)
  end
  chats[root] = job
  vim.cmd.startinsert()
end

---For tests: forget every run.
function M._reset()
  runs, chats = {}, {}
end

return M
