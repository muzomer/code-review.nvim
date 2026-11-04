-- Review a GitHub PR without a checkout: fetch its metadata and changed files
-- into a session directory that the rest of the plugin treats like a project.
--
--   state: <state>/code-review/<host>/<owner>/<repo>/pr-<n>/   (root: comments, session.json)
--   cache: <cache>/code-review/<host>/<owner>/<repo>/pr-<n>/   (base/ and head/ snapshots)
-- (see session.dirs)
local store = require("code-review.store")
local session = require("code-review.session")

local M = {}

---Called as on_progress(done, total) while files are fetched in parallel (the
---review UI sets it; the CLI never does, so nothing extra reaches stdout).
M.on_progress = nil

M.retries = 3
M.concurrency = 8
M.retry_delay_ms = 400

---Replaceable in tests: fun(args: string[]): { code: integer, stdout: string, stderr: string }
M.run = function(args)
  return vim.system(args, { text = true }):wait()
end

-- Parsing -------------------------------------------------------------------

---Parse a PR reference into its parts.
---@param s string a PR URL or a short reference
---@return { host: string, owner: string, repo: string, number: integer }? ref
---@return string? err
function M.parse_ref(s)
  s = vim.trim(s or "")
  local host, owner, repo, num, rest = s:match("^https?://([^/]+)/([^/]+)/([^/]+)/pull/(%d+)(.*)$")
  if host then
    -- accept /files, /commits, ?query, #fragment after the number; not "/pull/12abc"
    if rest ~= "" and not rest:match("^[/?#]") then
      return nil, "not a pull request URL: " .. s
    end
    return { host = host, owner = owner, repo = repo, number = tonumber(num) }
  end
  owner, repo, num = s:match("^([%w%-_.]+)/([%w%-_.]+)#(%d+)$")
  if owner then
    return { host = "github.com", owner = owner, repo = repo, number = tonumber(num) }
  end
  return nil, "expected a PR URL (https://github.com/<owner>/<repo>/pull/<n>) or <owner>/<repo>#<n>, got: " .. s
end

-- Auth + HTTP -----------------------------------------------------------------

local gh_token -- `gh auth token` spawns a process: ask once per Neovim/CLI run

---Token from $GH_TOKEN, $GITHUB_TOKEN, or `gh auth token`.
---@return string? token
function M.token()
  for _, name in ipairs({ "GH_TOKEN", "GITHUB_TOKEN" }) do
    local v = os.getenv(name)
    if v and v ~= "" then
      return v
    end
  end
  if gh_token == nil and vim.fn.executable("gh") == 1 then
    local res = M.run({ "gh", "auth", "token" })
    local t = res.code == 0 and vim.trim(res.stdout or "") or ""
    gh_token = t ~= "" and t or false
  end
  return gh_token or nil
end

---Forget the memoized `gh` token (tests).
function M.reset_token()
  gh_token = nil
end

local function api_base(host)
  return host == "github.com" and "https://api.github.com" or ("https://" .. host .. "/api/v3")
end

local NO_TOKEN = "no GitHub token: set GH_TOKEN or GITHUB_TOKEN, or run `gh auth login`"

local function request_args(token, host, path, opts)
  return {
    "curl", "-sS", "-L",
    "-H", "Authorization: Bearer " .. token,
    "-H", "Accept: " .. (opts.raw and "application/vnd.github.raw+json" or "application/vnd.github+json"),
    "-H", "X-GitHub-Api-Version: 2022-11-28",
    "-w", "\n%{http_code}",
    api_base(host) .. path,
  }
end

local function http_status(res)
  return tonumber(((res and res.stdout or ""):match("\n(%d+)$")))
end

local function transient(res)
  local status = http_status(res)
  return res ~= nil and res.code == 0 and (status == 502 or status == 503 or status == 504)
end

---Turn a finished curl run into the body, or nil + error.
local function interpret(res, path, opts)
  if not res then
    return nil, "request was interrupted: " .. path
  end
  if res.code ~= 0 then
    return nil, "curl failed: " .. vim.trim(res.stderr or "")
  end
  local body, status = (res.stdout or ""):match("^(.*)\n(%d+)$")
  status = tonumber(status)
  if status == 404 then
    return nil, "not found: " .. path
  elseif status == 401 or status == 403 then
    return nil, string.format("GitHub denied access (%d); check the token's scope for this repo", status)
  elseif not status or status >= 400 then
    return nil, string.format("GitHub returned %s for %s", tostring(status), path)
  end
  if opts.raw then
    return body
  end
  local ok, data = pcall(vim.json.decode, body, { luanil = { object = true, array = true } })
  if not ok then
    return nil, "cannot parse GitHub response for " .. path
  end
  return data
end

---GET `path` from the API of `host`. Transient 502/503/504 are retried.
---@param opts? { raw?: boolean } raw = file contents instead of JSON
---@return any? body decoded JSON (or the raw string), nil when not found
---@return string? err
function M.get(host, path, opts)
  opts = opts or {}
  local token = M.token()
  if not token then
    return nil, NO_TOKEN
  end
  local args = request_args(token, host, path, opts)
  local res
  for attempt = 1, M.retries + 1 do
    res = M.run(args)
    if not transient(res) then
      break
    end
    if attempt <= M.retries then
      vim.uv.sleep(M.retry_delay_ms * attempt)
    end
  end
  return interpret(res, path, opts)
end

local default_run = M.run

---Run several commands at once (at most M.concurrency in flight).
---When `M.run` is replaced (tests) they run one after the other through it.
---@param list string[][]
---@return table[] results same order as `list`
function M.run_many(list)
  local results = {}
  local reported = -1
  local function report(done) -- on the main loop only
    if M.on_progress and done ~= reported then
      reported = done
      pcall(M.on_progress, done, #list)
    end
  end
  if M.run ~= default_run then
    for i, args in ipairs(list) do
      results[i] = M.run(args)
      report(i)
    end
    return results
  end
  local next_i, active, done = 1, 0, 0
  local function launch()
    while active < M.concurrency and next_i <= #list do
      local i = next_i
      next_i = next_i + 1
      active = active + 1
      vim.system(list[i], { text = true }, function(res)
        results[i] = res
        active = active - 1
        done = done + 1
      end)
    end
  end
  launch()
  -- vim.wait can return early (Ctrl-C, a hit-enter prompt): keep waiting until
  -- every request finished or the deadline passes.
  local deadline = vim.uv.hrtime() + 10 * 60 * 1e9
  while done < #list and vim.uv.hrtime() < deadline do
    vim.wait(1000, function()
      launch()
      report(done) -- the callbacks above only count; the UI is updated from here
      return done >= #list
    end, 10)
  end
  report(done)
  return results
end

---GET many paths in parallel. Failed entries come back as `{ err = ... }`.
---@param reqs { path: string, raw?: boolean }[]
---@return { body: any?, err: string? }[]
function M.get_many(host, reqs)
  local token = M.token()
  local out = {}
  if not token then
    for i = 1, #reqs do
      out[i] = { err = NO_TOKEN }
    end
    return out
  end
  local todo = {}
  for i = 1, #reqs do
    todo[i] = i
  end
  for round = 1, M.retries + 1 do
    local list = {}
    for k, i in ipairs(todo) do
      list[k] = request_args(token, host, reqs[i].path, reqs[i])
    end
    local res = M.run_many(list)
    local again = {}
    for k, i in ipairs(todo) do
      if transient(res[k]) and round <= M.retries then
        again[#again + 1] = i
      else
        local body, err = interpret(res[k], reqs[i].path, reqs[i])
        out[i] = { body = body, err = err }
      end
    end
    todo = again
    if #todo == 0 then
      break
    end
    vim.uv.sleep(M.retry_delay_ms * round)
  end
  return out
end

-- PR data ---------------------------------------------------------------------

---Changed files of a PR (all pages).
---@return table[]? files { filename, status, previous_filename?, additions, deletions, patch? }
---@return string? err
function M.pr_files(ref)
  local files = {}
  for page = 1, 30 do -- GitHub caps a PR at 3000 files = 30 pages of 100
    local data, err = M.get(
      ref.host,
      string.format("/repos/%s/%s/pulls/%d/files?per_page=100&page=%d", ref.owner, ref.repo, ref.number, page)
    )
    if not data then
      return nil, err
    end
    vim.list_extend(files, data)
    if #data < 100 then
      break
    end
  end
  return files
end

local function contents_path(ref, path, sha)
  local escaped = path:gsub("[^%w%-%._~/]", function(c)
    return string.format("%%%02X", c:byte())
  end)
  return string.format("/repos/%s/%s/contents/%s?ref=%s", ref.owner, ref.repo, escaped, sha)
end

---File contents at a commit; nil when the file does not exist there.
function M.file_at(ref, path, sha)
  return M.get(ref.host, contents_path(ref, path, sha), { raw = true })
end

---Entries of a directory at a commit.
---@return table[]? entries { name, type = "file"|"dir"|... }
---@return string? err
function M.list_dir(ref, path, sha)
  path = path:gsub("^/+", ""):gsub("/+$", "")
  local data, err = M.get(ref.host, string.format("/repos/%s/%s/contents/%s?ref=%s", ref.owner, ref.repo, path, sha))
  if not data then
    return nil, err
  end
  if data.type then -- a single file, not a directory
    return nil, path .. " is a file"
  end
  return data
end

-- Session directories ----------------------------------------------------------

local function write_snapshot(cache, side, path, content)
  local dest = string.format("%s/%s/%s", cache, side, path)
  vim.fn.mkdir(vim.fs.dirname(dest), "p")
  local f = assert(io.open(dest, "wb"))
  f:write(content)
  f:close()
end

---Fetch a PR into its session directory and return the session root.
---Changed files are snapshotted at both commits; other files are fetched on
---demand with `M.ensure_file`.
---@return string? root
---@return string? err
function M.open_pr(ref)
  local pr, err = M.get(ref.host, string.format("/repos/%s/%s/pulls/%d", ref.owner, ref.repo, ref.number))
  if not pr then
    return nil, err
  end
  local files, ferr = M.pr_files(ref)
  if not files then
    return nil, ferr
  end

  local root, cache = session.dirs(ref)
  local base_sha, head_sha = pr.base.sha, pr.head.sha
  vim.fn.mkdir(root, "p")
  -- Snapshots are keyed by path, not commit: drop them when the PR moved.
  local prev = session.load(root)
  if prev and (prev.base_sha ~= base_sha or prev.head_sha ~= head_sha) then
    vim.fn.delete(cache, "rf")
  end
  vim.fn.mkdir(cache, "p")

  local changed, jobs = {}, {}
  for _, f in ipairs(files) do
    changed[#changed + 1] = {
      path = f.filename,
      old_path = f.previous_filename,
      status = f.status,
      additions = f.additions,
      deletions = f.deletions,
    }
    -- renamed files are stored under their new name, so one path names both sides
    if f.status ~= "added" and not vim.uv.fs_stat(session.snapshot_path_in(cache, f.filename, "old")) then
      jobs[#jobs + 1] = { side = "base", dest = f.filename, path = contents_path(ref, f.previous_filename or f.filename, base_sha), raw = true }
    end
    if f.status ~= "removed" and not vim.uv.fs_stat(session.snapshot_path_in(cache, f.filename, "new")) then
      jobs[#jobs + 1] = { side = "head", dest = f.filename, path = contents_path(ref, f.filename, head_sha), raw = true }
    end
  end
  if #jobs > 0 then
    local results = M.get_many(ref.host, jobs)
    local failed
    for i, job in ipairs(jobs) do
      local r = results[i]
      if r.body then
        write_snapshot(cache, job.side, job.dest, r.body)
      elseif r.err and not r.err:find("^not found") then
        failed = failed or r.err -- a 404 just means "no text here"; anything else is worth reporting
      end
    end
    if failed then
      return nil, "could not fetch every file: " .. failed
    end
  end

  session.save(root, {
    kind = "pr",
    host = ref.host,
    owner = ref.owner,
    repo = ref.repo,
    number = ref.number,
    title = pr.title,
    body = (pr.body or ""):gsub("\r\n", "\n"),
    author = pr.user and pr.user.login or nil,
    state = pr.merged and "merged" or pr.state,
    draft = pr.draft or nil,
    labels = vim.tbl_map(function(l) return l.name end, pr.labels or {}),
    url = pr.html_url,
    base_ref = pr.base.ref,
    head_ref = pr.head.ref,
    base_sha = base_sha,
    head_sha = head_sha,
    cache = cache,
    files = changed,
  })
  store.ensure_dir(root)
  return root
end

---Make sure `path` exists in the head (or base) snapshot, fetching it from
---GitHub when it is not cached yet.
---@param side? "old"|"new"
---@return string? abs_path
---@return string? err
function M.ensure_file(root, path, side)
  local s = session.load(root)
  if not s or s.kind ~= "pr" then
    return nil, "not a PR session"
  end
  local dest = session.snapshot_path(root, path, side)
  if vim.uv.fs_stat(dest) then
    return dest
  end
  local sha = side == "old" and s.base_sha or s.head_sha
  local text, err = M.file_at(s, path, sha)
  if not text then
    return nil, err
  end
  write_snapshot(s.cache, side == "old" and "base" or "head", path, text)
  return dest
end

return M
