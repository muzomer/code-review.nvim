-- Review local commits one at a time.
--
-- `:CodeReview commits [range]` lists the commits of a range (default: from the
-- default branch to HEAD), oldest first, and shows one commit at a time in the
-- PR review UI: its files before (parent) and after, from snapshots written
-- with git. Works in git repos and jj repos colocated with git.
--
-- One review per repo (see session.local_dirs): the agent picked, its session
-- and the threads carry over from commit to commit. A thread records the commit
-- it was written on, so it shows only there.
local session = require("code-review.session")
local store = require("code-review.store")

local api = vim.api
local M = {}

local function notify(msg, level)
  vim.notify("code-review: " .. msg, level or vim.log.levels.INFO)
end

---Run git in `repo`. Replaceable in tests.
---@return { code: integer, stdout: string, stderr: string }
M.git = function(repo, args)
  local cmd = { "git", "-C", repo }
  vim.list_extend(cmd, args)
  local ok, proc = pcall(vim.system, cmd, { text = false })
  if not ok then
    return { code = -1, stdout = "", stderr = tostring(proc) }
  end
  return proc:wait()
end

local function git_ok(repo, args)
  local res = M.git(repo, args)
  if res.code ~= 0 then
    local err = vim.trim(res.stderr or "")
    return nil, err ~= "" and err or ("git " .. args[1] .. " failed")
  end
  return res.stdout or ""
end

---Top of the git repo containing `dir`.
function M.repo_root(dir)
  local out = git_ok(dir, { "rev-parse", "--show-toplevel" })
  return out and vim.fs.normalize(vim.trim(out)) or nil
end

---The branch commits are reviewed against: origin/HEAD, else main / master.
function M.default_base(repo)
  for _, ref in ipairs({ "origin/HEAD", "main", "master", "origin/main", "origin/master" }) do
    if M.git(repo, { "rev-parse", "--verify", "--quiet", ref .. "^{commit}" }).code == 0 then
      return ref
    end
  end
end

---Commits of `range`, oldest first (first parents only: a merge is one step).
---@return table[]? commits { sha, parent, subject, body, author, date }
---@return string? err
function M.list(repo, range)
  local out, err = git_ok(repo, { "log", "--first-parent", "--reverse", "--format=%H%x00%P%x00%an%x00%aI%x00%s%x00%b%x1e", range, "--" })
  if not out then
    return nil, err
  end
  local res = {}
  for rec in out:gmatch("([^\30]+)") do
    rec = rec:gsub("^\n+", "")
    if rec ~= "" then
      local f = vim.split(rec, "\0", { plain = true })
      res[#res + 1] = {
        sha = f[1],
        parent = (f[2] or ""):match("^(%x+)"), -- nil for a root commit
        author = f[3],
        date = f[4],
        subject = f[5] or "",
        body = vim.trim(f[6] or ""),
      }
    end
  end
  return res
end

local STATUS = { A = "added", D = "removed", M = "modified", R = "renamed", C = "added", T = "modified" }

---Changed files of a commit against its first parent (everything is added in a
---root commit), with their blobs and line counts.
---@return table[]? files { path, old_path?, status, additions, deletions, old_blob?, new_blob?, binary? }
---@return string? err
function M.changed(repo, c)
  local range = c.parent and { c.parent, c.sha } or { "--root", c.sha }
  local raw, err = git_ok(repo, vim.list_extend({ "diff-tree", "-r", "-M", "--no-commit-id", "-z", "--raw" }, range))
  if not raw then
    return nil, err
  end
  local num = git_ok(repo, vim.list_extend({ "diff-tree", "-r", "-M", "--no-commit-id", "-z", "--numstat" }, range)) or ""
  local files, by_path = {}, {}
  local parts = vim.split(raw, "\0", { plain = true })
  local i = 1
  while i <= #parts do
    local meta = parts[i]
    local _, _, old_blob, new_blob, st = meta:match("^:(%d+) (%d+) (%x+) (%x+) (%a)")
    if st then
      local f = { status = STATUS[st] or "modified" }
      if st == "R" or st == "C" then
        f.old_path, f.path = parts[i + 1], parts[i + 2]
        i = i + 3
      else
        f.path = parts[i + 1]
        i = i + 2
      end
      if st == "C" then
        f.old_path = nil -- a copy shows as a new file
      end
      if f.status ~= "added" then
        f.old_blob = old_blob
      end
      if f.status ~= "removed" then
        f.new_blob = new_blob
      end
      files[#files + 1] = f
      by_path[f.path] = f
    else
      i = i + 1
    end
  end
  -- numstat -z: "add\tdel\tpath\0", or "add\tdel\t\0old\0new\0" for a rename
  local n = vim.split(num, "\0", { plain = true })
  i = 1
  while i <= #n do
    local add, del, path = n[i]:match("^([%d-]+)\t([%d-]+)\t(.*)$")
    if add then
      if path == "" then
        path = n[i + 2]
        i = i + 3
      else
        i = i + 1
      end
      local f = by_path[path or ""]
      if f then
        f.binary = add == "-" or nil
        f.additions = tonumber(add) or 0
        f.deletions = tonumber(del) or 0
      end
    else
      i = i + 1
    end
  end
  return files
end

---Write the before/after text of every changed (text) file of commit `c`.
local function write_snapshots(repo, cache, files)
  for _, f in ipairs(files) do
    for side, blob in pairs({ base = f.old_blob, head = f.new_blob }) do
      local dest = string.format("%s/%s/%s", cache, side, f.path)
      if blob and not f.binary and not vim.uv.fs_stat(dest) then
        local text = git_ok(repo, { "cat-file", "blob", blob })
        if text then
          vim.fn.mkdir(vim.fs.dirname(dest), "p")
          local out = assert(io.open(dest, "wb"))
          out:write(text)
          out:close()
        end
      end
    end
  end
end

---Index of commit `sha` in the review.
local function index_of(s, sha)
  for i, c in ipairs(s.commits or {}) do
    if c.sha == sha then
      return i
    end
  end
end

M.index_of = index_of

---Make commit `sha` the one on screen: read its files (once; a commit never
---changes) and copy them to the top of the session, where the diff UI looks.
---@return table? session
function M.select(root, sha)
  local s = session.load(root)
  local i = s and index_of(s, sha)
  if not i then
    return nil
  end
  local c = s.commits[i]
  local cache = session.commit_cache(s, c.sha)
  if not c.files or not vim.uv.fs_stat(cache) then
    local files, err = M.changed(s.repo, c)
    if not files then
      notify("cannot read commit " .. c.sha:sub(1, 7) .. ": " .. tostring(err), vim.log.levels.ERROR)
      return nil
    end
    vim.fn.mkdir(cache, "p")
    write_snapshots(s.repo, cache, files)
    c.files = vim.tbl_map(function(f)
      return { path = f.path, old_path = f.old_path, status = f.status, additions = f.additions, deletions = f.deletions }
    end, files)
  end
  s.current = c.sha
  s.base_sha = c.parent or ""
  s.head_sha = c.sha
  s.base_ref = c.parent and "parent" or "(root commit)"
  s.head_ref = string.format("%d/%d %s", i, #s.commits, c.subject)
  s.title = c.subject
  s.cache = cache
  s.files = c.files
  session.save(root, s)
  return s
end

---Threads and viewed marks of commits that were rewritten (amended, a fixup
---squashed in, rebased) move to the commit that replaced them: the one in the
---new list with the same subject, when exactly one has it.
---@param old table[] the commits listed before
---@param new table[] the commits listed now
local function carry_over(root, old, new)
  local now, by_subject = {}, {}
  for _, c in ipairs(new) do
    now[c.sha] = true
    local k = c.subject or ""
    by_subject[k] = by_subject[k] == nil and c.sha or false -- false: more than one
  end
  local moved = {}
  for _, c in ipairs(old) do
    local to = by_subject[c.subject or ""]
    if not now[c.sha] and to then
      moved[c.sha] = to
    end
  end
  if not next(moved) then
    return
  end
  if store.exists(root) then
    store.update(root, function(data)
      local changed = false
      for _, t in ipairs(data.threads) do
        if t.commit and moved[t.commit] then
          t.commit = moved[t.commit]
          changed = true
        end
      end
      if not changed then
        return store.UNCHANGED
      end
    end)
  end
  session.move_viewed(root, moved)
end

---Open the commits review of the repo around the current file (or cwd).
---@param range? string a git revision range; default <default branch>..HEAD, and when that is empty, asked for
---@param dir? string a directory in the repo (default: the current file's, else cwd)
---@return string? root
function M.open(range, dir)
  require("code-review").setup_once()
  local name = api.nvim_buf_get_name(0)
  if not dir then
    dir = (name ~= "" and vim.bo.buftype == "" and vim.fn.isdirectory(vim.fs.dirname(name)) == 1) and vim.fs.dirname(name) or vim.fn.getcwd()
    -- a snapshot or the file list of a commits review is not inside the repo: use the repo of that review
    local sroot = session.infer(name) or vim.b.code_review_sidebar
    local prev = sroot and session.load(sroot)
    if prev and prev.kind == "commits" then
      dir = prev.repo
    end
  end
  local repo = M.repo_root(dir)
  if not repo then
    return notify("not in a git repository (jj repos need to be colocated with git)", vim.log.levels.WARN)
  end
  local asked = range and range ~= ""
  if not asked then
    local base = M.default_base(repo)
    range = base and base .. "..HEAD"
  end
  local list, err
  if range then
    list, err = M.list(repo, range)
  end
  if not asked and not (list and #list > 0) then
    -- on the default branch itself (or without one): ask which commits
    vim.ui.input({ prompt = "Commits to review (no branch commits; a range): ", default = "HEAD~5..HEAD" }, function(r)
      if r and vim.trim(r) ~= "" then
        M.open(vim.trim(r), repo)
      end
    end)
    return nil
  end
  if not list then
    return notify("cannot list commits of " .. range .. ": " .. vim.split(tostring(err), "\n")[1], vim.log.levels.ERROR)
  end
  if #list == 0 then
    return notify("no commits in " .. range .. " to review", vim.log.levels.WARN)
  end
  local root, cache_base = session.local_dirs(repo)
  vim.fn.mkdir(root, "p")
  local s = session.load(root) or {}
  -- files read before stay valid: a sha always has the same content
  local known = {}
  for _, c in ipairs(s.commits or {}) do
    known[c.sha] = c.files
  end
  for _, c in ipairs(list) do
    c.files = known[c.sha]
  end
  carry_over(root, s.commits or {}, list)
  local keep = s.current and vim.iter(list):any(function(c) return c.sha == s.current end) and s.current
  s = {
    kind = "commits",
    repo = repo,
    range = range,
    cache_base = cache_base,
    commits = list,
  }
  session.save(root, s)
  store.ensure_dir(root)
  -- where you were, if that commit is still in the range; else the first one not reviewed yet
  local target = keep or M.first_unreviewed(root) or list[1].sha
  if not M.show(root, target) then
    return nil
  end
  local km = require("code-review").config.keymaps or {}
  local keys = require("code-review.keys")
  local nxt = keys.label(km.next_commit)
  notify(string.format("%s: %d commit%s%s", range, #list, #list == 1 and "" or "s", nxt and (" · " .. nxt .. " next commit") or ""))
  return root
end

---Is every file of commit `c` marked as viewed?
function M.reviewed(root, c)
  if not c.files then
    return false
  end
  local viewed = session.viewed_map(root, c.sha)
  for _, f in ipairs(c.files) do
    if not viewed[f.path] then
      return false
    end
  end
  return true
end

---The first commit not fully viewed yet, or nil.
function M.first_unreviewed(root)
  local s = session.load(root)
  for _, c in ipairs(s and s.commits or {}) do
    if not M.reviewed(root, c) then
      return c.sha
    end
  end
end

---Show commit `sha` of the review: its first file not viewed yet.
---@return boolean shown
function M.show(root, sha)
  local s = M.select(root, sha)
  if not s then
    return false
  end
  local diff = require("code-review.diff")
  diff.refresh_cache(root)
  if #(s.files or {}) == 0 then
    -- nothing to diff (an empty commit): still show it in the list
    diff.files(root)
    notify(string.format("commit %s changes no files", sha:sub(1, 7)))
    return true
  end
  diff.resume(root)
  return true
end

---Go to the next (dir = 1) or previous (-1) commit.
---@return boolean moved
function M.step(root, dir)
  local s = session.load(root)
  if not (s and s.kind == "commits") then
    notify("not in a commits review: open one with :CodeReview commits", vim.log.levels.WARN)
    return false
  end
  local i = index_of(s, s.current) or 0
  local j = i + dir
  if j < 1 or j > #s.commits then
    notify(dir > 0 and "last commit of " .. s.range or "first commit of " .. s.range)
    return false
  end
  return M.show(root, s.commits[j].sha)
end

---One line about commit `c` for the picker.
function M.line(root, c, i, n)
  local ok, data = pcall(store.read, root)
  local open = 0
  for _, t in ipairs(ok and data.threads or {}) do
    if t.commit == c.sha and t.status ~= "resolved" then
      open = open + 1
    end
  end
  return string.format("%d/%d %s %s%s%s", i, n, c.sha:sub(1, 7), c.subject, M.reviewed(root, c) and "  ✓" or "",
    open > 0 and ("  ✎" .. open) or "")
end

---Pick a commit of the review and show it.
function M.pick(root)
  local s = session.load(root)
  if not (s and s.kind == "commits") then
    return notify("not in a commits review: open one with :CodeReview commits", vim.log.levels.WARN)
  end
  local items = {}
  for i, c in ipairs(s.commits) do
    items[#items + 1] = { c = c, i = i }
  end
  vim.ui.select(items, {
    prompt = "Commit to review",
    format_item = function(it)
      return M.line(root, it.c, it.i, #items)
    end,
  }, function(it)
    if it then
      M.show(root, it.c.sha)
    end
  end)
end

---Make sure the commit a thread was written on is the one on screen.
---@return boolean switched
function M.ensure_current(root, t)
  local s = session.load(root)
  if not (s and s.kind == "commits" and t.commit and t.commit ~= s.current) then
    return false
  end
  if not index_of(s, t.commit) then
    notify(string.format("the commit of this thread (%s) is no longer in %s", t.commit:sub(1, 7), s.range), vim.log.levels.WARN)
    return false
  end
  M.select(root, t.commit)
  require("code-review.diff").refresh_cache(root)
  return true
end

return M
