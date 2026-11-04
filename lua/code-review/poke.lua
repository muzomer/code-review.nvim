-- Poke the agent session that does the reviewing: type "check my comments"
-- into its terminal without leaving Neovim.
--
-- Backend: herdr (https://herdr.dev), which can submit a prompt to any agent
-- pane from outside (`herdr agent prompt <pane> <text>`). The agent to poke is
-- chosen once per review in a picker and remembered in
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

---Let the user choose the agent to poke and remember the choice.
---@param on_pick fun(target: table)
function M.pick(root, on_pick)
  local agents, err = M.agents()
  if not agents then
    return notify("cannot list agents: " .. tostring(err), vim.log.levels.ERROR)
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

---Poke the agent of this review with `text`. Picks the agent first when none is
---remembered (or the remembered one is gone). Without herdr the prompt is
---copied to the clipboard instead.
---@param opts? { pick?: boolean } pick = choose the agent again
function M.send(root, text, opts)
  opts = opts or {}
  if not M.available() then
    vim.fn.setreg('"', text)
    pcall(vim.fn.setreg, "+", text)
    return notify("poke needs herdr (not found here); the prompt is copied, paste it into your agent", vim.log.levels.WARN)
  end
  local function go(target)
    local before = M.snapshot(target.pane_id) -- taken before submitting, so nothing is missed
    local ok, err = M.submit(target.pane_id, text)
    if ok then
      notify("poked " .. target.title)
      if require("code-review").config.progress ~= false then
        require("code-review.progress").start(root, target, before)
      end
      return
    end
    notify(string.format("could not poke %s: %s", target.title, tostring(err)), vim.log.levels.ERROR)
  end
  local saved = not opts.pick and M.saved_target(root)
  if saved then
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
