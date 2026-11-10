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
    -- never written empty: a crash cut it short. Reading it as "no threads"
    -- would let the next write wipe them for good.
    error("cannot read " .. file .. ": the file is empty (delete it to start over)", 0)
  end
  local ok, data = pcall(vim.json.decode, s, { luanil = { object = true, array = true } })
  if not ok or type(data) ~= "table" then
    error("cannot parse " .. file .. ": " .. tostring(data), 0)
  end
  data.version = data.version or M.VERSION
  data.threads = data.threads or {}
  M.check(data, file)
  return data
end

---Fail with a clear message on a store that is not the shape the code expects
---(edited by hand, or by a newer version), instead of failing later on a nil.
function M.check(data, file)
  local function bad(why)
    error(string.format("cannot read %s: %s", file or "the comments file", why), 0)
  end
  if type(data.threads) ~= "table" or (next(data.threads) ~= nil and not vim.islist(data.threads)) then
    bad("`threads` is not a list")
  end
  for i, t in ipairs(data.threads) do
    local name = type(t) == "table" and type(t.id) == "string" and t.id or ("#" .. i)
    if type(t) ~= "table" then
      bad("thread " .. name .. " is not an object")
    elseif type(t.id) ~= "string" then
      bad("thread " .. name .. " has no id")
    elseif type(t.file) ~= "string" then
      bad("thread " .. name .. " has no file")
    elseif type(t.range) ~= "table" or type(t.range.start) ~= "number" or type(t.range["end"]) ~= "number" then
      bad("thread " .. name .. " has no range")
    elseif type(t.messages) ~= "table" then
      bad("thread " .. name .. " has no messages")
    end
  end
end

---Write to a temporary file, flush it to disk, then rename it over the store:
---a failure (disk full, quota) leaves the old file as it was.
local function write(root, data)
  local _, file = M.paths(root)
  local tmp = file .. ".tmp." .. uv.os_getpid()
  local text = M.encode(data) .. "\n"
  local fd, err = uv.fs_open(tmp, "w", 420)
  if not fd then
    error("cannot save " .. file .. ": " .. tostring(err), 0)
  end
  local n, werr = uv.fs_write(fd, text)
  local synced, serr = uv.fs_fsync(fd)
  uv.fs_close(fd)
  if n ~= #text or not synced then
    uv.fs_unlink(tmp)
    error("cannot save " .. file .. ": " .. tostring(werr or serr or "short write (disk full?)"), 0)
  end
  local ok, rerr = uv.fs_rename(tmp, file)
  if not ok then
    uv.fs_unlink(tmp)
    error("cannot save " .. file .. ": " .. tostring(rerr), 0)
  end
end

M.lock_timeout_ms = 5000 -- how long an update waits for the lock
local LOCK_STALE_S = 10 -- a lock with no pid in it
local LOCK_ABANDONED_S = 60 -- a lock whose process is still there

-- The PID namespace of this process (Linux): a pid from another one (an agent
-- in a sandbox or container) says nothing about which processes exist here.
local PID_NS = uv.fs_readlink("/proc/self/ns/pid") or ""

---The pid that holds the lock, and its PID namespace ("" when unknown).
local function lock_owner(lock)
  local f = io.open(lock, "r")
  if not f then
    return nil
  end
  local pid, ns = (f:read("a") or ""):match("^%s*(%d+)%s*(%S*)")
  f:close()
  return tonumber(pid), ns or ""
end

---Whether the lock was left behind: its process is gone, or it is far older
---than any update takes (the pid may have been reused, or is on another host).
local function stale(lock)
  local st = uv.fs_stat(lock)
  if not st then
    return false
  end
  local age = os.time() - st.mtime.sec
  local pid, ns = lock_owner(lock)
  -- give a new lock a moment to get its pid written; a pid of another namespace
  -- (or a lock without one, from an older version) only goes stale by age
  if pid and age >= 1 and (ns == "" or ns == PID_NS) then
    local alive, _, name = uv.kill(pid, 0)
    if not alive and name == "ESRCH" then
      return true
    end
  end
  return age > (pid and LOCK_ABANDONED_S or LOCK_STALE_S)
end

local function acquire(lock)
  local deadline = uv.hrtime() + M.lock_timeout_ms * 1e6
  while true do
    local fd, err, name = uv.fs_open(lock, "wx", 420)
    if fd then
      uv.fs_write(fd, uv.os_getpid() .. " " .. PID_NS)
      uv.fs_close(fd)
      return
    end
    if name ~= "EEXIST" then -- read-only directory, disk full: waiting will not help
      error("cannot lock " .. lock .. ": " .. tostring(err), 0)
    end
    if stale(lock) then
      uv.fs_unlink(lock)
    elseif uv.hrtime() > deadline then
      error(string.format("timed out waiting for lock %s (held by process %s); try again", lock, lock_owner(lock) or "?"), 0)
    else
      uv.sleep(15)
    end
  end
end

---Remove the lock if it is still ours (it may have been taken over).
local function release(lock)
  local pid, ns = lock_owner(lock)
  if pid == uv.os_getpid() and ns == PID_NS then
    uv.fs_unlink(lock)
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
  release(lock)
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
  if author ~= "user" then
    t.approved = nil -- an approval is for one answer: the agent replied, the next change needs a new one
  end
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

-- What a reviewer's approval says in the thread (the agent reads it like any message).
M.APPROVE = "Go ahead: apply the changes"
M.REVOKE = "Approval withdrawn: do not change the code for this; discuss it first."

---Approve (or withdraw approval for) changing the code for thread `t` in a local
---review: the flag lets the agent edit files, the message tells it so. It holds
---until the agent's next reply in the thread (see add_message).
function M.set_approved(t, on)
  t.approved = on or nil
  M.add_message(t, "user", on and M.APPROVE or M.REVOKE)
  if on and t.status == "resolved" then
    t.status = "open"
  end
  M.refresh_needs(t)
end

---The conversation about the review as a whole (questions not about a line):
---one per review, a thread with `general = true`, no file and no lines.
function M.is_general(t)
  return t.general == true
end

---@return table? thread
function M.general(data)
  for _, t in ipairs(data.threads) do
    if M.is_general(t) then
      return t
    end
  end
end

---Add `body` to the conversation about the whole review, starting it if needed.
---@return string id
function M.ask(data, author, body)
  local t = M.general(data)
  if not t then
    t = { id = new_id(data), general = true, file = "", range = { start = 0, ["end"] = 0 }, status = "open", messages = {} }
    data.threads[#data.threads + 1] = t
  end
  M.add_message(t, author, body)
  t.status = "open"
  M.refresh_needs(t)
  return t.id
end

---@param o {file:string, side?:"old"|"new", base?:string, start:integer, ["end"]:integer, start_col?:integer, end_col?:integer, anchor:table, author:string, body:string}
function M.add_thread(data, o)
  local t = {
    id = new_id(data),
    file = o.file,
    side = o.side ~= "new" and o.side or nil,
    base = o.base,
    commit = o.commit, -- commits review: the commit it was written on
    range = { start = o.start, ["end"] = o["end"], start_col = o.start_col, end_col = o.end_col },
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
