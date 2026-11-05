-- Poke the agent session that does the reviewing: type "check my comments"
-- into its terminal without leaving Neovim.
--
-- Backends:
--  * herdr (https://herdr.dev), which can submit a prompt to any agent pane from
--    outside (`herdr agent prompt <pane> <text>`);
--  * this review's background agent (`claude -p`, see headless.lua), when no
--    terminal agent is running or herdr is not there.
-- The agent to poke is chosen once per review in a picker and remembered in
-- <root>/.code-review/poke-target.json.
local store = require("code-review.store")

local M = {}

---Replaceable in tests: fun(args: string[]): { code: integer, stdout: string, stderr: string }
M.TIMEOUT_MS = 8000

---Why a herdr call failed, from its result: a timeout says so instead of "".
local function failure(res)
  if res.code == 124 or (res.signal == 15 and (res.stderr or "") == "") then
    return string.format("herdr did not answer within %ds", M.TIMEOUT_MS / 1000)
  end
  local err = vim.trim(res.stderr or "")
  return err ~= "" and err or vim.trim(res.stdout or "") ~= "" and vim.trim(res.stdout) or ("herdr exited with " .. tostring(res.code))
end

M.run = function(args)
  local ok, obj = pcall(vim.system, args, { text = true }) -- throws when herdr is not installed
  if not ok then
    return { code = -1, stdout = "", stderr = tostring(obj) }
  end
  return obj:wait(M.TIMEOUT_MS)
end

local default_run = M.run

---Like `M.run` without blocking Neovim: `cb(result)` runs on the main loop.
---(When `M.run` is replaced, as in tests, it runs synchronously through it.)
function M.run_async(args, cb)
  if M.run ~= default_run then
    return cb(M.run(args))
  end
  local ok, err = pcall(vim.system, args, { text = true, timeout = M.TIMEOUT_MS }, function(res)
    vim.schedule(function()
      cb(res)
    end)
  end)
  if not ok then -- herdr not installed: answer like a failed run, so callers clean up
    vim.schedule(function()
      cb({ code = -1, stdout = "", stderr = tostring(err) })
    end)
  end
end

local function notify(msg, level)
  vim.notify("code-review: " .. msg, level or vim.log.levels.INFO)
end

---Is there a herdr to talk to?
function M.available()
  return (vim.env.HERDR_SOCKET_PATH or "") ~= "" and vim.fn.executable("herdr") == 1
end

local function target_file(root)
  return (store.paths(root)) .. "/poke-target.json"
end

---@return { pane_id: string, title: string }? target
function M.saved_target(root)
  local f = io.open(target_file(root), "r")
  if not f then
    return nil
  end
  local s = f:read("a")
  f:close()
  local ok, t = pcall(vim.json.decode, s)
  return ok and type(t) == "table" and t.pane_id and t or nil
end

local function save_target(root, t)
  store.ensure_dir(root)
  local f = assert(io.open(target_file(root), "w"))
  f:write(vim.json.encode({ pane_id = t.pane_id, title = t.title }), "\n")
  f:close()
end

---Decode the JSON herdr prints. Errors come as {"error": {code, message}} and
---are reported even when the exit code is 0.
---@return table? result
---@return string? err
local function decode(res)
  if not res then
    return nil, "herdr did not answer"
  end
  local ok, data = pcall(vim.json.decode, res.stdout or "", { luanil = { object = true, array = true } })
  if ok and type(data) == "table" then
    if data.error then
      return nil, string.format("%s: %s", data.error.code or "error", data.error.message or "")
    end
    return data.result or data
  end
  if res.code ~= 0 then
    return nil, failure(res)
  end
  if vim.trim(res.stdout or "") ~= "" then -- not JSON: do not take it for a success
    return nil, "herdr printed something unexpected: " .. vim.split(vim.trim(res.stdout), "\n")[1]:sub(1, 120)
  end
  return {}
end

M.decode = decode

---Agents herdr knows about (this pane excluded).
---@return table[]? agents { pane_id, title, status, cwd }
---@return string? err
local function agent_list(res)
  local result, err = decode(res)
  if not result then
    return nil, err
  end
  local own = vim.env.HERDR_PANE_ID
  local list = {}
  for _, a in ipairs(result.agents or {}) do
    if a.pane_id ~= own then
      list[#list + 1] = {
        pane_id = a.pane_id,
        title = a.terminal_title_stripped or a.terminal_title or a.agent or a.pane_id,
        status = a.agent_status or "?",
        cwd = (a.cwd or ""):gsub("^" .. vim.pesc(vim.env.HOME or "\0"), "~"),
        agent = a.agent,
        session = a.agent_session and a.agent_session.value, -- herdr's guess of its session
        dir = a.cwd, -- where the pane is now (cwd above is for display)
      }
    end
  end
  return list
end

function M.agents()
  return agent_list(M.run({ "herdr", "agent", "list" }))
end

M.HEADLESS = "headless" -- pane_id of the background agent (claude -p) in a saved target

local function headless_target(root)
  local s = require("code-review.session").load(root)
  local what = s and s.kind == "pr" and string.format(" · PR #%s", s.number) or ""
  local headless = require("code-review.headless")
  return { pane_id = M.HEADLESS, title = vim.fs.basename(headless.command()) .. " (background)" .. what }
end

---Let the user choose the agent to poke. Besides the agents running in herdr,
---the list offers this review's background agent. The choice is remembered
---once `on_pick` reports the poke went through, so a broken agent is not
---tried again on every poke.
---@param on_pick fun(target: table): boolean? ok
---@param listed? table[] the herdr agents, when the caller has just listed them
function M.pick(root, on_pick, listed)
  local headless = require("code-review.headless")
  local agents, err = {}, nil
  if listed then
    agents = vim.list_extend({}, listed)
  elseif M.available() then
    agents, err = M.agents()
    if not agents then
      notify("cannot list agents: " .. tostring(err), vim.log.levels.WARN)
      agents = {}
    end
  end
  if headless.available() and require("code-review").config.agent ~= "herdr" then
    local h = headless_target(root)
    if #agents == 0 and not err then -- nothing to choose from
      if on_pick(h) then
        save_target(root, h)
      end
      return
    end
    h.status = headless.session_id(root) and "resume" or "new"
    h.cwd = "runs without a terminal"
    agents[#agents + 1] = h
  end
  if #agents == 0 then
    return notify("no other agent is running in herdr", vim.log.levels.WARN)
  end
  local resume = require("code-review").suspend_thread() -- the picker would overlap it
  vim.ui.select(agents, {
    prompt = "Poke which agent?",
    format_item = function(a)
      return string.format("%-40s %-8s %s", a.title, a.status, a.cwd)
    end,
  }, function(choice)
    resume()
    if choice and on_pick(choice) then
      save_target(root, choice)
    end
  end)
end

local asked = {} -- root → true: choose_if_unset already asked in this Neovim

---Ask which agent reviews this project when none is chosen yet, without poking
---it: called after your first comment, so a later send goes straight there.
---Asks only when herdr runs agents to choose from (else the background agent
---needs no choice), and once per review in a Neovim, so a dismissed picker
---does not come back on every comment.
function M.choose_if_unset(root)
  local config = require("code-review").config
  if (config.agent or "auto") == "headless" or asked[root] or not M.available() or M.saved_target(root) then
    return
  end
  asked[root] = true
  M.run_async({ "herdr", "agent", "list" }, function(res)
    local agents = agent_list(res)
    if agents and #agents > 0 and not M.saved_target(root) then
      M.pick(root, function()
        return true -- remember it; nothing is sent yet
      end, agents)
    end
  end)
end

---Where the agent's counters stand, to tell later which events came after the
---poke: `state` goes up on every status change, `completion` when a turn ends.
---@return { state: integer?, completion: integer? }? snapshot nil when unreadable
function M.snapshot(pane_id)
  local result = decode(M.run({ "herdr", "agent", "get", pane_id }))
  local a = result and result.agent
  if not a then
    return nil
  end
  return { state = a.state_change_seq, completion = a.completion_seq }
end

---Submit `text` to the agent pane.
---@return boolean ok
---@return string? err
function M.submit(pane_id, text)
  local result, err = decode(M.run({ "herdr", "agent", "prompt", pane_id, text }))
  if not result then
    return false, err
  end
  return true
end

-- Sessions of herdr panes ------------------------------------------------------
--
-- To fork the session of a pane, we need its session id and the directory it
-- was started in. herdr reports the id; for Claude Code it is only used when its
-- transcript is found, and the directory is read from that transcript.

local function claude_dir()
  local env = vim.env.CLAUDE_CONFIG_DIR
  return vim.fs.normalize(env and env ~= "" and env or "~/.claude")
end

---How Claude Code names the directory of a project: every non-alphanumeric
---character becomes "-".
function M.project_dir_name(cwd)
  return (cwd:gsub("[^%w]", "-"))
end

---The directory a session was started in, read from its transcript (the first
---recorded cwd that matches the transcript's project directory).
---@return string? cwd
function M.session_cwd(transcript)
  local f = io.open(transcript, "r")
  if not f then
    return nil
  end
  local dir = vim.fs.basename(vim.fs.dirname(transcript))
  local found
  for _ = 1, 200 do
    local line = f:read("l")
    if not line then
      break
    end
    local cwd = line:match('"cwd":"(.-)"')
    if cwd and M.project_dir_name(cwd) == dir then
      found = cwd
      break
    end
  end
  f:close()
  return found
end

---The session to fork for a herdr agent, as herdr reports it: for Claude Code
---only when its transcript is found (started from the directory recorded there),
---for other agents from the pane's directory.
---@return { id: string, cwd: string, agent: string }?
function M.session_of(target)
  local agent = target.agent or "claude"
  if agent ~= "claude" then
    return target.session and target.dir and { id = target.session, cwd = target.dir, agent = agent } or nil
  end
  if not target.session then
    return nil
  end
  local transcript = vim.fn.glob(claude_dir() .. "/projects/*/" .. target.session .. ".jsonl", false, true)[1]
  local cwd = transcript and M.session_cwd(transcript)
  if cwd then
    return { id = target.session, cwd = cwd, agent = "claude" }
  end
end

-- Sending ------------------------------------------------------------------------

local function nothing_waits()
  notify("no comment is waiting for the agent")
end

---Poke the agent of this review: the remembered one, else one picked now.
---Without herdr (or with no agent in it) this review's background agent
---(`claude -p`) is used; without both the prompt is copied.
---
---A herdr agent is not typed into by default (config.isolate = "fork"): when
---its agent can fork sessions (Claude Code, OpenCode), a throwaway fork of its
---session answers in the background, so your session gets none of the work in
---its context. Otherwise the prompt is typed in; agents with subagents (Claude
---Code) are asked to use one ("subagent"), others get the plain prompt.
---@param opts? { pick?: boolean } pick = choose the agent again
function M.send(root, opts)
  opts = opts or {}
  local prompt = require("code-review.prompt")
  local headless = require("code-review.headless")
  local config = require("code-review").config
  local mode = config.agent or "auto"
  local isolate = config.isolate
  if isolate == nil then
    isolate = "fork"
  end
  if not prompt.build(root) then
    return nothing_waits()
  end
  local function follow(target, before)
    if config.progress ~= false then
      require("code-review.progress").start(root, target, before)
    end
  end
  local function background(text, sent, target, fork)
    local started, accepted = headless.send(root, text, function()
      follow(target)
    end, { fork = fork })
    if accepted then
      prompt.mark_sent(root, sent)
    end
    if started then
      notify("poked " .. target.title)
    end
    return accepted
  end
  local function go(target)
    if target.pane_id == M.HEADLESS then
      local text, sent = prompt.build(root, { style = "background", cwd = root, author = (require("code-review").config.headless or {}).agent or "claude" })
      return background(text, sent, target)
    end
    local adapter = require("code-review.agents").get(target.agent or "claude")
    if isolate == "fork" and adapter and adapter.fork and headless.available(target.agent or "claude") then
      local fork = M.session_of(target)
      if fork then
        local text, sent = prompt.build(root, { style = "fork", cwd = fork.cwd, author = target.agent or "claude" })
        return background(text, sent, { pane_id = M.HEADLESS, title = target.title .. " (fork)" }, fork)
      end
      notify(string.format("could not find the session of %s to fork; typing the prompt into its pane instead", target.title),
        vim.log.levels.WARN)
    end
    local style = isolate and adapter and adapter.subagents and "subagent" or "plain"
    local text, sent = prompt.build(root, { style = style, cwd = target.dir })
    local before = M.snapshot(target.pane_id) -- taken before submitting, so nothing is missed
    local ok, err = M.submit(target.pane_id, text)
    if ok then
      prompt.mark_sent(root, sent)
      notify("poked " .. target.title)
      follow(target, before)
      return true
    end
    notify(string.format("could not poke %s: %s · :CodeReview poke pick to choose another agent", target.title, tostring(err)),
      vim.log.levels.ERROR)
    return false
  end
  if mode == "headless" or (mode == "auto" and not M.available() and headless.available()) then
    if not headless.available() then
      return notify(headless.command() .. " not found; set config.headless.cmd", vim.log.levels.ERROR)
    end
    return go(headless_target(root))
  end
  if not M.available() then
    local text = prompt.build(root, { style = "plain", all = true })
    vim.fn.setreg('"', text)
    pcall(vim.fn.setreg, "+", text)
    return notify("poke needs herdr or claude (neither found here); the prompt is copied, paste it into your agent", vim.log.levels.WARN)
  end
  local saved = not opts.pick and M.saved_target(root)
  if saved then
    if saved.pane_id == M.HEADLESS and headless.available() then
      return go(headless_target(root))
    end
    local agents, err = M.agents()
    if not agents then -- herdr hiccup: the agent may well be there; ask again next time
      return notify("cannot list agents: " .. tostring(err), vim.log.levels.ERROR)
    end
    for _, a in ipairs(agents) do
      if a.pane_id == saved.pane_id then
        return go(a) -- the live record: its session may have changed
      end
    end
    notify("the agent you used before is gone; choose another", vim.log.levels.WARN)
  end
  M.pick(root, go)
end

return M
