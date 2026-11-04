-- Where the text of a thread's file comes from.
--
-- A plain project reads files from disk. A PR session (opened without a
-- checkout) keeps snapshots of the files at the PR's base and head commits:
--
--   <root>/.code-review/session.json   { kind = "pr", owner, repo, number, base_sha, head_sha, cache }
--   <cache>/base/<path>                file at the base commit
--   <cache>/head/<path>                file at the head commit
local store = require("code-review.store")

local M = {}

M.FILE = "session.json"

---Base directories of PR sessions. $NVIM_CODE_REVIEW_STATE / _CACHE override the
---Neovim defaults (used by tests, handy for CI).
function M.state_base()
  local env = os.getenv("NVIM_CODE_REVIEW_STATE")
  return vim.fs.normalize(env and env ~= "" and env or (vim.fn.stdpath("state") .. "/code-review"))
end

function M.cache_base()
  local env = os.getenv("NVIM_CODE_REVIEW_CACHE")
  return vim.fs.normalize(env and env ~= "" and env or (vim.fn.stdpath("cache") .. "/code-review"))
end

---Session root and cache directory of a PR.
function M.dirs(ref)
  local rel = string.format("%s/%s/%s/pr-%d", ref.host, ref.owner, ref.repo, ref.number)
  return M.state_base() .. "/" .. rel, M.cache_base() .. "/" .. rel
end

---Recognise a snapshot path: <cache>/<host>/<owner>/<repo>/pr-<n>/{base,head}/<file>.
---@return string? root, string? file, "old"|"new"? side
function M.infer(path)
  path = vim.fs.normalize(path)
  local prefix = M.cache_base() .. "/"
  if path:sub(1, #prefix) ~= prefix then
    return nil
  end
  local host, owner, repo, n, dir, file = path:sub(#prefix + 1):match("^([^/]+)/([^/]+)/([^/]+)/pr%-(%d+)/(%a+)/(.+)$")
  if not host or (dir ~= "base" and dir ~= "head") then
    return nil
  end
  local root = string.format("%s/%s/%s/%s/pr-%s", M.state_base(), host, owner, repo, n)
  return root, file, dir == "base" and "old" or "new"
end

---Snapshot path inside a known cache directory.
function M.snapshot_path_in(cache, file, side)
  return string.format("%s/%s/%s", cache, side == "old" and "base" or "head", file)
end

---Absolute path to read a thread's file from (snapshot in PR sessions).
function M.thread_path(root, t)
  return M.snapshot_path(root, t.file, t.side) or (root .. "/" .. t.file)
end

local function session_path(root)
  local dir = store.paths(root)
  return dir .. "/" .. M.FILE
end

---@return table? session nil for a plain project
function M.load(root)
  local f = io.open(session_path(root), "r")
  if not f then
    return nil
  end
  local s = f:read("a")
  f:close()
  local ok, data = pcall(vim.json.decode, s, { luanil = { object = true, array = true } })
  if ok and type(data) == "table" then
    return data
  end
end

function M.save(root, session)
  store.ensure_dir(root)
  local f = assert(io.open(session_path(root), "w"))
  f:write(vim.json.encode(session), "\n")
  f:close()
end

---Absolute path of the snapshot of `file` on `side`, or nil outside PR sessions.
---@param side? "old"|"new"
function M.snapshot_path(root, file, side)
  local s = M.load(root)
  if not s or s.kind ~= "pr" then
    return nil
  end
  return M.snapshot_path_in(s.cache, file, side)
end

-- Viewed files ---------------------------------------------------------------
--
-- <root>/.code-review/viewed.json maps a path to a hash of the text you looked
-- at. A file only counts as viewed while its text still hashes the same, so new
-- commits that change it bring it back into the review (like GitHub's "Viewed").

local function viewed_path(root)
  return (store.paths(root)) .. "/viewed.json"
end

local function read_viewed(root)
  local f = io.open(viewed_path(root), "r")
  if not f then
    return {}
  end
  local s = f:read("a")
  f:close()
  local ok, data = pcall(vim.json.decode, s)
  return ok and type(data) == "table" and data or {}
end

---Hash of what the reviewer sees for a changed file (new text, or old for a removal).
---@param f table entry of session.files
local function content_hash(root, f)
  local lines = M.lines(root, f.path, { side = f.status == "removed" and "old" or "new" })
  return vim.fn.sha256(table.concat(lines or {}, "\n"))
end

---@return table<string, boolean> viewed by path, for the files of a PR session
function M.viewed_map(root)
  local s = M.load(root)
  local saved, res = read_viewed(root), {}
  for _, f in ipairs(s and s.files or {}) do
    res[f.path] = saved[f.path] ~= nil and saved[f.path] == content_hash(root, f)
  end
  return res
end

---Mark (or unmark) a changed file as viewed.
function M.set_viewed(root, path, viewed)
  local s = M.load(root)
  local entry
  for _, f in ipairs(s and s.files or {}) do
    if f.path == path then
      entry = f
    end
  end
  if not entry then
    return false
  end
  local saved = read_viewed(root)
  saved[path] = viewed and content_hash(root, entry) or nil
  store.ensure_dir(root)
  local tmp = viewed_path(root) .. ".tmp." .. vim.uv.os_getpid()
  local out = assert(io.open(tmp, "w"))
  out:write(vim.json.encode(saved), "\n")
  out:close()
  assert(vim.uv.fs_rename(tmp, viewed_path(root)))
  return true
end

local function read_file(path)
  if vim.fn.filereadable(path) == 1 then
    return vim.fn.readfile(path)
  end
end

---Lines of `file` as seen from `side` (default "new"), or nil when missing.
---@param opts? { side?: "old"|"new", base?: string }
---@return string[]?
function M.lines(root, file, opts)
  opts = opts or {}
  local snap = M.snapshot_path(root, file, opts.side)
  if snap then
    return read_file(snap)
  end
  if opts.side == "old" then
    if not opts.base then
      return nil
    end
    local res = vim.system({ "git", "-C", root, "show", opts.base .. ":" .. file }, { text = true }):wait()
    if res.code ~= 0 then
      return nil
    end
    local out = res.stdout:gsub("\n$", "")
    return vim.split(out, "\n", { plain = true })
  end
  return read_file(root .. "/" .. file)
end

return M
