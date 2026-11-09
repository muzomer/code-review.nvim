-- Where the text of a thread's file comes from.
--
-- A plain project reads files from disk. A PR session (opened without a
-- checkout) keeps snapshots of the files at the PR's base and head commits:
--
--   <root>/.code-review/session.json   { kind = "pr", owner, repo, number, base_sha, head_sha, cache }
--   <cache>/base/<path>                file at the base commit
--   <cache>/head/<path>                file at the head commit
--
-- A commits review (local commits, one at a time) lives outside the repo too:
--
--   <state>/local/<name>/<hash>/.code-review/session.json
--       { kind = "commits", repo, range, cache_base, commits = { { sha, parent, subject, body, author, date, files? } },
--         current, and the current commit's base_sha, head_sha, cache, files, base_ref, head_ref }
--   <cache>/local/<name>/<hash>/<sha>/{base,head}/<path>   a commit's files, before and after
--
-- The current commit's fields sit at the top level, so the diff UI shows it like
-- a PR. Threads carry the sha of the commit they were written on (`commit`).
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

---Session root and cache base of the commits review of the repo at `repo`.
function M.local_dirs(repo)
  repo = vim.fs.normalize(repo)
  local name = (vim.fs.basename(repo):gsub("[^%w._-]", "_"))
  local rel = string.format("local/%s/%s", name ~= "" and name or "repo", vim.fn.sha256(repo):sub(1, 10))
  return M.state_base() .. "/" .. rel, M.cache_base() .. "/" .. rel
end

---Is `s` a review shown from snapshots (a PR, or local commits)?
function M.is_snapshots(s)
  return s ~= nil and (s.kind == "pr" or s.kind == "commits")
end

---Snapshot directory of commit `sha` in a commits review.
function M.commit_cache(s, sha)
  return s.cache_base .. "/" .. sha
end

---Directory an agent works in for this review: the repo of a commits review,
---else the root itself.
function M.workdir(root)
  local s = M.load(root)
  return s and s.kind == "commits" and s.repo or root
end

---Recognise a snapshot path: <cache>/<host>/<owner>/<repo>/pr-<n>/{base,head}/<file>,
---or <cache>/local/<name>/<hash>/<sha>/{base,head}/<file> (local commits).
---@return string? root, string? file, "old"|"new"? side, string? commit sha of a commits review
function M.infer(path)
  path = vim.fs.normalize(path)
  local prefix = M.cache_base() .. "/"
  if path:sub(1, #prefix) ~= prefix then
    return nil
  end
  local name, hash, sha, ldir, lfile = path:sub(#prefix + 1):match("^local/([^/]+)/([^/]+)/(%x+)/(%a+)/(.+)$")
  if name and (ldir == "base" or ldir == "head") then
    return string.format("%s/local/%s/%s", M.state_base(), name, hash), lfile, ldir == "base" and "old" or "new", sha
  end
  local host, owner, repo, n, dir, file = path:sub(#prefix + 1):match("^([^/]+)/([^/]+)/([^/]+)/pr%-(%d+)/(%a+)/(.+)$")
  if not host or (dir ~= "base" and dir ~= "head") then
    return nil
  end
  local root = string.format("%s/%s/%s/%s/pr-%s", M.state_base(), host, owner, repo, n)
  return root, file, dir == "base" and "old" or "new"
end

---Snapshot path inside a known cache directory. side "prev" = the head of the
---previous generation (kept when the PR got new commits).
function M.snapshot_path_in(cache, file, side)
  local dir = side == "old" and "base" or side == "prev" and "prev-head" or "head"
  return string.format("%s/%s/%s", cache, dir, file)
end

---Every PR review on this machine: { root, session, last (seconds: last activity) },
---most recent first.
function M.reviews()
  local res = {}
  local base = M.state_base()
  for _, path in ipairs(vim.fn.glob(base .. "/*/*/*/pr-*/" .. store.DIR .. "/" .. M.FILE, false, true)) do
    local root = vim.fs.dirname(vim.fs.dirname(path))
    local s = M.load(root)
    if s and s.kind == "pr" then
      local last = 0
      for _, f in ipairs({ path, (select(2, store.paths(root))), store.paths(root) .. "/viewed.json" }) do
        local st = vim.uv.fs_stat(f)
        if st and st.mtime.sec > last then
          last = st.mtime.sec
        end
      end
      res[#res + 1] = { root = root, session = s, last = last }
    end
  end
  table.sort(res, function(a, b)
    return a.last > b.last
  end)
  return res
end

---Absolute path to read a thread's file from (snapshot in PR and commits reviews).
function M.thread_path(root, t)
  return M.snapshot_path(root, t.file, t.side, t.commit) or (root .. "/" .. t.file)
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

---Absolute path of the snapshot of `file` on `side`, or nil outside PR and
---commits reviews. `commit`: that commit of a commits review (default: the current one).
---@param side? "old"|"new"
---@param commit? string
function M.snapshot_path(root, file, side, commit)
  local s = M.load(root)
  if not M.is_snapshots(s) then
    return nil
  end
  local cache = s.cache
  if s.kind == "commits" and commit then
    cache = M.commit_cache(s, commit)
  end
  return M.snapshot_path_in(cache, file, side)
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
local function content_hash(root, f, commit)
  local lines = M.lines(root, f.path, { side = f.status == "removed" and "old" or "new", commit = commit })
  return vim.fn.sha256(table.concat(lines or {}, "\n"))
end

---Key of a file in viewed.json: its path, prefixed by the commit in a commits
---review (the same file is reviewed again in every commit that changes it).
local function viewed_key(s, path, commit)
  if s and s.kind == "commits" then
    return (commit or s.head_sha) .. ":" .. path
  end
  return path
end

---@param commit? string a commit of a commits review (default: the current one)
---@return table<string, boolean> viewed by path, for the files of a PR session (or of that commit)
function M.viewed_map(root, commit)
  local s = M.load(root)
  local saved, res = read_viewed(root), {}
  local files = s and s.files or {}
  if s and s.kind == "commits" and commit and commit ~= s.head_sha then
    files = {}
    for _, c in ipairs(s.commits or {}) do
      if c.sha == commit then
        files = c.files or {}
      end
    end
  end
  for _, f in ipairs(files) do
    local key = viewed_key(s, f.path, commit)
    res[f.path] = saved[key] ~= nil and saved[key] == content_hash(root, f, commit)
  end
  return res
end

---Viewed marks of commits that were replaced: `moved` maps an old sha to the new one.
function M.move_viewed(root, moved)
  local saved = read_viewed(root)
  local changed = false
  for key, hash in pairs(vim.deepcopy(saved)) do
    local sha, path = key:match("^(%x+):(.+)$")
    if sha and moved[sha] then
      saved[key] = nil
      saved[moved[sha] .. ":" .. path] = hash -- still compared with the text: a changed file counts as not viewed
      changed = true
    end
  end
  if changed then
    store.ensure_dir(root)
    local out = assert(io.open(viewed_path(root), "w"))
    out:write(vim.json.encode(saved), "\n")
    out:close()
  end
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
  saved[viewed_key(s, path)] = viewed and content_hash(root, entry) or nil
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
---@param opts? { side?: "old"|"new", base?: string, commit?: string }
---@return string[]?
function M.lines(root, file, opts)
  opts = opts or {}
  local snap = M.snapshot_path(root, file, opts.side, opts.commit)
  if snap then
    return read_file(snap)
  end
  if opts.side == "old" then
    if not opts.base then
      return nil
    end
    -- vim.system throws when git is not installed: that is just "no old text"
    local ok, proc = pcall(vim.system, { "git", "-C", root, "show", opts.base .. ":" .. file }, { text = true })
    if not ok then
      return nil
    end
    local res = proc:wait()
    if res.code ~= 0 then
      return nil
    end
    local out = res.stdout:gsub("\n$", "")
    return vim.split(out, "\n", { plain = true })
  end
  return read_file(root .. "/" .. file)
end

return M
