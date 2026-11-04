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
M.run = function(args)
  return vim.system(args, { text = true }):wait(8000)
end

local default_run = M.run

---Like `M.run` without blocking Neovim: `cb(result)` runs on the main loop.
---(When `M.run` is replaced, as in tests, it runs synchronously through it.)
function M.run_async(args, cb)
  if M.run ~= default_run then
    return cb(M.run(args))
  end
  vim.system(args, { text = true }, function(res)
    vim.schedule(function()
      cb(res)
    end)
  end)
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
    return nil, vim.trim((res.stderr or "") ~= "" and res.stderr or (res.stdout or "herdr failed"))
  end
  return {}
end

M.decode = decode

---Agents herdr knows about (this pane excluded).
---@return table[]? agents { pane_id, title, status, cwd }
---@return string? err
function M.agents()
  local result, err = decode(M.run({ "herdr", "agent", "list" }))
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
      }
    end
  end
  return list
end

M.HEADLESS = "headless" -- pane_id of the background agent (claude -p) in a saved target

local function headless_target(root)
  local s = require("code-review.session").load(root)
  local what = s and s.kind == "pr" and string.format(" · PR #%s", s.number) or ""
  return { pane_id = M.HEADLESS, title = "claude (background)" .. what }
end

---Let the user choose the agent to poke and remember the choice. Besides the
---agents running in herdr, the list offers this review's background agent.
---@param on_pick fun(target: table)
function M.pick(root, on_pick)
  local headless = require("code-review.headless")
  local agents, err = {}, nil
  if M.available() then
    agents, err = M.agents()
    if not agents then
      notify("cannot list agents: " .. tostring(err), vim.log.levels.WARN)
      agents = {}
    end
  end
  if headless.available() and require("code-review").config.agent ~= "herdr" then
    local h = headless_target(root)
    if #agents == 0 then -- nothing to choose from
      save_target(root, h)
      return on_pick(h)
    end
    h.status = headless.session_id(root) and "resume" or "new"
    h.cwd = "runs without a terminal"
    agents[#agents + 1] = h
  end
  if #agents == 0 then
    return notify("no other agent is running in herdr", vim.log.levels.WARN)
  end
  vim.ui.select(agents, {
    prompt = "Poke which agent?",
    format_item = function(a)
      return string.format("%-40s %-8s %s", a.title, a.status, a.cwd)
    end,
  }, function(choice)
    if not choice then
      return
    end
    save_target(root, choice)
    on_pick(choice)
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

---Poke the agent of this review with `text`: the remembered one, else one
---picked now. Without herdr (or with no agent in it) this review's background
---agent (`claude -p`) is used; without both the prompt is copied.
---@param opts? { pick?: boolean } pick = choose the agent again
function M.send(root, text, opts)
  opts = opts or {}
  local headless = require("code-review.headless")
  local mode = require("code-review").config.agent or "auto"
  local function follow(target, before)
    if require("code-review").config.progress ~= false then
      require("code-review.progress").start(root, target, before)
    end
  end
  local function go(target)
    if target.pane_id == M.HEADLESS then
      local started = headless.send(root, text, function()
        follow(target)
      end)
      if started then
        notify("poked " .. target.title)
      end
      return
    end
    local before = M.snapshot(target.pane_id) -- taken before submitting, so nothing is missed
    local ok, err = M.submit(target.pane_id, text)
    if ok then
      notify("poked " .. target.title)
      return follow(target, before)
    end
    notify(string.format("could not poke %s: %s", target.title, tostring(err)), vim.log.levels.ERROR)
  end
  if mode == "headless" or (mode == "auto" and not M.available() and headless.available()) then
    if not headless.available() then
      return notify(headless.command() .. " not found; set config.headless.cmd", vim.log.levels.ERROR)
    end
    return go(headless_target(root))
  end
  if not M.available() then
    vim.fn.setreg('"', text)
    pcall(vim.fn.setreg, "+", text)
    return notify("poke needs herdr or claude (neither found here); the prompt is copied, paste it into your agent", vim.log.levels.WARN)
  end
  local saved = not opts.pick and M.saved_target(root)
  if saved then
    if saved.pane_id == M.HEADLESS and headless.available() then
      return go(headless_target(root))
    end
    local agents = M.agents() or {}
    for _, a in ipairs(agents) do
      if a.pane_id == saved.pane_id then
        return go(saved)
      end
    end
    notify("the agent you used before is gone; choose another", vim.log.levels.WARN)
  end
  M.pick(root, go)
end

return M
