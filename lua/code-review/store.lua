-- Persistent comment store: <root>/.code-review/comments.json
-- Shared by the Neovim UI and the headless CLI (`nvim -l`).
local uv = vim.uv or vim.loop

local M = {}

M.DIR = ".code-review"
M.FILE = "comments.json"
M.VERSION = 1
-- Returned from an `update` callback to skip writing.
M.UNCHANGED = setmetatable({}, { __tostring = function() return "UNCHANGED" end })

math.randomseed(tonumber(uv.hrtime() % 2147483647))

local islist = vim.islist or vim.tbl_islist

---Project root: $NVIM_CODE_REVIEW_ROOT, else nearest .git/.jj ancestor, else
---`fallback`, else `start`.
---@param start? string directory to search from (defaults to cwd)
---@param fallback? string
function M.find_root(start, fallback)
  local env = os.getenv("NVIM_CODE_REVIEW_ROOT")
  if env and env ~= "" then
    return (vim.fs.normalize(vim.fn.fnamemodify(env, ":p")):gsub("/$", ""))
  end
  start = vim.fs.normalize(start or uv.cwd())
  local found = vim.fs.find({ ".git", ".jj" }, { path = start, upward = true, limit = 1 })[1]
  if found then
    return vim.fs.dirname(found)
  end
  return fallback or start
end

function M.paths(root)
  local dir = root .. "/" .. M.DIR
  local file = dir .. "/" .. M.FILE
  return dir, file, file .. ".lock"
end

---Path of `abs` relative to `root`, or nil when it is outside the root.
function M.relpath(root, abs)
  abs = vim.fs.normalize(abs)
  local prefix = root .. "/"
  if abs:sub(1, #prefix) == prefix then
    return abs:sub(#prefix + 1)
  end
  return nil
end

function M.exists(root)
  local _, file = M.paths(root)
  return uv.fs_stat(file) ~= nil
end

function M.ensure_dir(root)
  local dir = M.paths(root)
  if vim.fn.isdirectory(dir) == 0 then
    vim.fn.mkdir(dir, "p")
    -- Ignored by default; delete this file to commit your comments.
    local f = io.open(dir .. "/.gitignore", "w")
    if f then
      f:write("*\n")
      f:close()
    end
  end
end

-- JSON ----------------------------------------------------------------------

local ORDER = {
  "version", "threads",
  "id", "file", "side", "base", "range", "start", "end", "status", "needs", "anchor",
  "text", "context_before", "context_after", "messages", "author", "ts", "edited", "body",
}
local RANK = {}
for i, k in ipairs(ORDER) do
  RANK[k] = i
end

local function scalar(v)
  return (vim.json.encode(v):gsub("\\/", "/"))
end

-- Pretty, key-ordered encoder so the file diffs well if you commit it.
-- Every empty table in the schema is a list, so `{}` encodes as `[]`.
local function encode(v, depth)
  if type(v) ~= "table" then
    return scalar(v)
  end
  if next(v) == nil then
    return "[]"
  end
  local pad = string.rep("  ", depth + 1)
  local parts = {}
  if islist(v) then
    for _, x in ipairs(v) do
      parts[#parts + 1] = pad .. encode(x, depth + 1)
    end
    return "[\n" .. table.concat(parts, ",\n") .. "\n" .. string.rep("  ", depth) .. "]"
  end
  local keys = vim.tbl_keys(v)
  table.sort(keys, function(a, b)
    local ra, rb = RANK[a] or math.huge, RANK[b] or math.huge
    if ra ~= rb then
      return ra < rb
    end
    return a < b
  end)
  for _, k in ipairs(keys) do
    parts[#parts + 1] = pad .. scalar(k) .. ": " .. encode(v[k], depth + 1)
  end
  return "{\n" .. table.concat(parts, ",\n") .. "\n" .. string.rep("  ", depth) .. "}"
end

function M.encode(data)
  return encode(data, 0)
end

-- Read / write ----------------------------------------------------------------

function M.read(root)
  local _, file = M.paths(root)
  local f = io.open(file, "r")
  if not f then
    return { version = M.VERSION, threads = {} }
  end
  local s = f:read("a")
  f:close()
  if s:match("^%s*$") then
    return { version = M.VERSION, threads = {} }
  end
  local ok, data = pcall(vim.json.decode, s, { luanil = { object = true, array = true } })
  if not ok or type(data) ~= "table" then
    error("code-review: cannot parse " .. file .. ": " .. tostring(data), 0)
  end
  data.version = data.version or M.VERSION
  data.threads = data.threads or {}
  return data
end

local function write(root, data)
  local _, file = M.paths(root)
  local tmp = file .. ".tmp." .. uv.os_getpid()
  local f = assert(io.open(tmp, "w"))
  f:write(M.encode(data), "\n")
  f:close()
  assert(uv.fs_rename(tmp, file))
end

local LOCK_TIMEOUT_MS = 5000
local LOCK_STALE_S = 10

local function acquire(lock)
  local deadline = uv.hrtime() + LOCK_TIMEOUT_MS * 1e6
  while true do
    local fd = uv.fs_open(lock, "wx", 420)
    if fd then
      uv.fs_write(fd, tostring(uv.os_getpid()))
      uv.fs_close(fd)
      return
    end
    local st = uv.fs_stat(lock)
    if st and os.time() - st.mtime.sec > LOCK_STALE_S then
      uv.fs_unlink(lock)
    elseif uv.hrtime() > deadline then
      error("code-review: timed out waiting for lock " .. lock, 0)
    else
      uv.sleep(15)
    end
  end
end

---Locked read-modify-write. `fn(data)` mutates data in place; return
---`M.UNCHANGED` to skip the write. Returns fn's result.
function M.update(root, fn)
  M.ensure_dir(root)
  local _, _, lock = M.paths(root)
  acquire(lock)
  local ok, res = pcall(function()
    local data = M.read(root)
    local r = fn(data)
    if r == M.UNCHANGED then
      return nil
    end
    for _, t in ipairs(data.threads) do
      M.refresh_needs(t)
    end
    write(root, data)
    return r
  end)
  uv.fs_unlink(lock)
  if not ok then
    error(res, 0)
  end
  return res
end

-- Model -------------------------------------------------------------------------

function M.now()
  return os.date("!%Y-%m-%dT%H:%M:%SZ")
end

---Who has to act next: "agent" after a user message, "user" after an agent one.
function M.refresh_needs(t)
  if t.status == "resolved" then
    t.needs = "none"
    return
  end
  local last = t.messages[#t.messages]
  t.needs = (last and last.author == "user") and "agent" or "user"
end

function M.is_agent_thread(t)
  return t.messages[1] and t.messages[1].author ~= "user"
end

local function new_id(data)
  local used = {}
  for _, t in ipairs(data.threads) do
    used[t.id] = true
  end
  local id
  repeat
    id = string.format("t_%04x", math.random(0, 0xffff))
  until not used[id]
  return id
end

---Find a thread by id; also accepts a message id like "t_a3f9.2".
function M.find(data, id)
  id = (id or ""):gsub("%.%d+$", "")
  for i, t in ipairs(data.threads) do
    if t.id == id then
      return t, i
    end
  end
end

function M.add_message(t, author, body)
  local msg = { id = t.id .. "." .. (#t.messages + 1), author = author, body = body, ts = M.now() }
  t.messages[#t.messages + 1] = msg
  return msg
end

---`side`/`base` are optional: a missing `side` means "new" (the file as it is
---on disk) and a missing `base` means the working tree. A thread on the old
---side of a diff carries `side = "old"` and the ref its text comes from.
---Replace the text of the thread's last message when it is the user's, i.e. the
---agent has not answered it yet. Marks it `edited` (agents see that).
---@return boolean ok
---@return string? err why not
function M.edit_last_user_message(t, body)
  local last = t.messages[#t.messages]
  if not last or last.author ~= "user" then
    return false, "the agent has already replied; reply instead"
  end
  if last.body == body then
    return true
  end
  last.body = body
  last.edited = M.now()
  return true
end

---@param o {file:string, side?:"old"|"new", base?:string, start:integer, ["end"]:integer, anchor:table, author:string, body:string}
function M.add_thread(data, o)
  local t = {
    id = new_id(data),
    file = o.file,
    side = o.side ~= "new" and o.side or nil,
    base = o.base,
    range = { start = o.start, ["end"] = o["end"] },
    anchor = o.anchor,
    status = "open",
    messages = {},
  }
  M.add_message(t, o.author, o.body)
  M.refresh_needs(t)
  data.threads[#data.threads + 1] = t
  return t.id
end

return M
