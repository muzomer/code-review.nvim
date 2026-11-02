-- Agent-facing CLI. Run via bin/code-review (`nvim --clean -l`).
local store = require("code-review.store")
local anchor = require("code-review.anchor")

local M = {}

local USAGE = [[
code-review - read and answer review comments left in Neovim

Usage:
  code-review list [--all | --status S] [--needs agent|user] [--file F] [--json]
  code-review show <id> [--json]
  code-review reply <id> <body | -> [--author NAME]
  code-review resolve <id> [body | -] [--author NAME]
  code-review add <file> <start> [end] <body | -> [--author NAME]
  code-review skill        print agent instructions
  code-review hook         Claude Code hook: report new threads (JSON on stdin)

`list` shows unresolved threads by default. A body of "-" is read from stdin.
--author defaults to "agent". Agents cannot edit, reopen or delete threads.
Options: --root DIR (default: $NVIM_CODE_REVIEW_ROOT or the git/jj root of cwd)]]

local BOOL = { json = true, all = true, help = true, ["no-reanchor"] = true }

local function parse(argv)
  local pos, flags = {}, {}
  local i = 1
  while i <= #argv do
    local a = argv[i]
    if a == "--" then
      for j = i + 1, #argv do
        pos[#pos + 1] = argv[j]
      end
      break
    elseif a == "-h" then
      flags.help = true
    elseif a:match("^%-%-.") then
      local k, v = a:match("^%-%-([%w%-]+)=(.*)$")
      if k then
        flags[k] = v
      else
        k = a:sub(3)
        if BOOL[k] then
          flags[k] = true
        else
          flags[k] = argv[i + 1]
          i = i + 1
        end
      end
    else
      pos[#pos + 1] = a
    end
    i = i + 1
  end
  return pos, flags
end

local function out(s)
  io.stdout:write(s, "\n")
end

local function body_from(parts)
  local body = table.concat(parts, " ")
  if body == "-" then
    body = io.read("a") or ""
  end
  body = vim.trim(body)
  return body ~= "" and body or nil
end

local function indent(text, prefix)
  return prefix .. text:gsub("\n", "\n" .. prefix)
end

local function format_thread(t)
  local r = t.range
  local loc = r.start == r["end"] and tostring(r.start) or (r.start .. "-" .. r["end"])
  local lines = {
    string.format("%s  [%s, needs %s]  %s:%s", t.id, t.status, t.needs, t.file, loc),
  }
  for i, l in ipairs((t.anchor or {}).text or {}) do
    lines[#lines + 1] = string.format("  %5d | %s", r.start + i - 1, l)
  end
  for _, m in ipairs(t.messages) do
    lines[#lines + 1] = string.format("  - %s (%s) %s:", m.id, m.author, m.ts)
    lines[#lines + 1] = indent(m.body, "      ")
  end
  return table.concat(lines, "\n")
end

local function emit(flags, value, text)
  if flags.json then
    out(store.encode(value))
  else
    out(text)
  end
end

local function to_rel(root, file)
  local abs = file:sub(1, 1) == "/" and file or (vim.uv.cwd() .. "/" .. file)
  abs = vim.fs.normalize(vim.fn.fnamemodify(abs, ":p"))
  local rel = store.relpath(root, abs)
  if not rel then
    error("file is outside the project root " .. root, 0)
  end
  return rel, abs
end

local function with_thread(root, id, fn)
  return store.update(root, function(data)
    local t = store.find(data, id)
    if not t then
      error("no thread " .. tostring(id), 0)
    end
    return fn(t, data)
  end)
end

local cmds = {}

function cmds.list(root, pos, flags)
  if not flags["no-reanchor"] then
    anchor.reanchor_root(root)
  end
  local data = store.read(root)
  local res = {}
  for _, t in ipairs(data.threads) do
    local ok = true
    if flags.status then
      ok = t.status == flags.status
    elseif not flags.all then
      ok = t.status ~= "resolved"
    end
    if flags.needs and t.needs ~= flags.needs then
      ok = false
    end
    if flags.file and t.file ~= to_rel(root, flags.file) then
      ok = false
    end
    if ok then
      res[#res + 1] = t
    end
  end
  local text = {}
  for _, t in ipairs(res) do
    text[#text + 1] = format_thread(t)
  end
  emit(flags, res, #res == 0 and "No matching threads." or table.concat(text, "\n\n"))
end

function cmds.show(root, pos, flags)
  if not flags["no-reanchor"] then
    anchor.reanchor_root(root)
  end
  local t = store.find(store.read(root), pos[1])
  if not t then
    error("no thread " .. tostring(pos[1]), 0)
  end
  emit(flags, t, format_thread(t))
end

function cmds.reply(root, pos, flags)
  local id = table.remove(pos, 1)
  local body = body_from(pos)
  if not id or not body then
    error("usage: code-review reply <id> <body | ->", 0)
  end
  local msg = with_thread(root, id, function(t)
    return store.add_message(t, flags.author or "agent", body)
  end)
  emit(flags, msg, "Replied " .. msg.id)
end

function cmds.resolve(root, pos, flags)
  local id = table.remove(pos, 1)
  if not id then
    error("usage: code-review resolve <id> [body | -]", 0)
  end
  local body = body_from(pos)
  with_thread(root, id, function(t)
    if body then
      store.add_message(t, flags.author or "agent", body)
    end
    t.status = "resolved"
  end)
  emit(flags, { id = id, status = "resolved" }, "Resolved " .. id)
end

function cmds.add(root, pos, flags)
  local file, s = pos[1], tonumber(pos[2] or "")
  if not file or not s then
    error("usage: code-review add <file> <start> [end] <body | ->", 0)
  end
  local rest = 3
  local e = tonumber(pos[3] or "")
  if e and pos[4] then
    rest = 4
  else
    e = s
  end
  local body = body_from({ unpack(pos, rest) })
  if not body then
    error("comment body is empty", 0)
  end
  local rel, abs = to_rel(root, file)
  if vim.fn.filereadable(abs) == 0 then
    error("cannot read " .. abs, 0)
  end
  local lines = vim.fn.readfile(abs)
  if s < 1 or e < s or e > #lines then
    error(string.format("line range %d-%d is outside %s (%d lines)", s, e, rel, #lines), 0)
  end
  local id = store.update(root, function(data)
    return store.add_thread(data, {
      file = rel,
      start = s,
      ["end"] = e,
      anchor = anchor.capture(lines, s, e),
      author = flags.author or "agent",
      body = body,
    })
  end)
  emit(flags, { id = id }, "Created " .. id)
end

function cmds.skill()
  local here = debug.getinfo(1, "S").source:sub(2)
  local path = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(here))) .. "/skills/nvim-code-review/SKILL.md"
  local f = assert(io.open(path, "r"))
  io.stdout:write(f:read("a"))
  f:close()
end

-- Claude Code UserPromptSubmit / SessionStart hook. Reads the hook JSON on
-- stdin and prints a short notice (added to the agent's context) about threads
-- waiting on the agent that it has not been told about in this session.
-- Prints nothing otherwise, and never fails the prompt.
--
-- $NVIM_CODE_REVIEW_HOOK picks the mode for the session it runs in:
--   mention (default)  tell the agent; it acts only if the user asks
--   act                the agent handles new threads right away (review session)
--   off                say nothing
local HOOK_STATE = "hook-seen.json"
local HOOK_STATE_TTL = 7 * 24 * 3600

local HOOK_INSTRUCTIONS = {
  mention = "If the user's message asks about review comments, handle them with the nvim-code-review skill."
    .. " Otherwise do what the user asked, then briefly mention that these threads are waiting; don't act on them unasked.",
  act = "This is a review session (NVIM_CODE_REVIEW_HOOK=act): handle these threads now with the nvim-code-review skill"
    .. " (read the code, make requested changes, reply in each thread, resolve only when the change is done),"
    .. " and also do whatever the user's message asks.",
}

local function hook(root)
  local mode = os.getenv("NVIM_CODE_REVIEW_HOOK") or ""
  if mode == "off" then
    return
  end
  if not HOOK_INSTRUCTIONS[mode] then
    mode = "mention"
  end
  local input = {}
  local raw = io.read("a") or ""
  if raw ~= "" then
    local ok, decoded = pcall(vim.json.decode, raw, { luanil = { object = true, array = true } })
    if ok and type(decoded) == "table" then
      input = decoded
    end
  end
  if input.cwd then
    root = store.find_root(input.cwd)
  end
  if not store.exists(root) then
    return
  end
  pcall(anchor.reanchor_root, root)

  local pending = {}
  for _, t in ipairs(store.read(root).threads) do
    if t.needs == "agent" then
      pending[#pending + 1] = t
    end
  end

  -- What this session has already been told: { [session] = { t = time, seen = { [tid] = msg count } } }
  local dir = store.paths(root)
  local state_path = dir .. "/" .. HOOK_STATE
  local state = {}
  if vim.fn.filereadable(state_path) == 1 then
    local ok, s = pcall(vim.json.decode, table.concat(vim.fn.readfile(state_path), "\n"))
    state = ok and type(s) == "table" and s or {}
  end
  local session = input.session_id or "default"
  local seen = (state[session] or {}).seen or {}

  local new, now_seen = {}, {}
  for _, t in ipairs(pending) do
    now_seen[t.id] = #t.messages
    if seen[t.id] ~= #t.messages then
      new[#new + 1] = t
    end
  end
  for k, v in pairs(state) do
    if type(v) ~= "table" or os.time() - (v.t or 0) > HOOK_STATE_TTL then
      state[k] = nil
    end
  end
  state[session] = { t = os.time(), seen = next(now_seen) and now_seen or vim.empty_dict() }
  local tmp = state_path .. ".tmp." .. vim.uv.os_getpid()
  vim.fn.writefile({ vim.json.encode(state) }, tmp)
  vim.uv.fs_rename(tmp, state_path)

  if #new == 0 then
    return
  end
  local lines = {
    string.format(
      "[code-review] %d review thread(s) the user left in their editor are waiting for your reply%s:",
      #new,
      #new < #pending and string.format(" (%d waiting in total)", #pending) or ""
    ),
  }
  for i, t in ipairs(new) do
    if i > 10 then
      lines[#lines + 1] = string.format("- ... and %d more", #new - 10)
      break
    end
    local last = t.messages[#t.messages]
    local text = last.body:gsub("%s+", " ")
    if #text > 100 then
      text = text:sub(1, 97) .. "..."
    end
    lines[#lines + 1] = string.format("- %s %s:%d: %s", t.id, t.file, t.range.start, text)
  end
  lines[#lines + 1] = HOOK_INSTRUCTIONS[mode]
  out(table.concat(lines, "\n"))
end

function cmds.hook(root)
  pcall(hook, root) -- a hook must never block the user's prompt
end

---@return integer exit code
function M.run(argv)
  local pos, flags = parse(argv)
  local cmd = table.remove(pos, 1)
  if not cmd or flags.help or cmd == "help" then
    out(USAGE)
    return cmd and 0 or 1
  end
  local fn = cmds[cmd]
  if not fn then
    io.stderr:write("code-review: unknown command '" .. cmd .. "'\n\n" .. USAGE .. "\n")
    return 1
  end
  if flags.author == "user" or flags.author == "" then
    io.stderr:write("code-review: --author cannot be '" .. flags.author .. "'; \"user\" is reserved for the human\n")
    return 1
  end
  local root = flags.root and vim.fs.normalize(vim.fn.fnamemodify(flags.root, ":p")):gsub("/$", "")
    or store.find_root()
  local ok, err = pcall(fn, root, pos, flags)
  if not ok then
    io.stderr:write("code-review: " .. tostring(err) .. "\n")
    return 1
  end
  return 0
end

return M
