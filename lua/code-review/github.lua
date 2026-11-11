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

-- vim.system throws (instead of failing) when the command is missing: turn
-- that into a failed result so every caller gets an answer.
local function spawn(args, on_exit)
  local ok, proc = pcall(vim.system, args, { text = true }, on_exit)
  if ok then
    return proc
  end
  return nil, { code = -1, stdout = "", stderr = tostring(proc) }
end

---Replaceable in tests: fun(args: string[]): { code: integer, stdout: string, stderr: string }
M.run = function(args)
  local proc, failed = spawn(args)
  return proc and proc:wait() or failed
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
-- A failure is remembered only briefly: `gh auth login` must work without a
-- restart, but each call must not block Neovim on `gh` again.
local gh_failed_at
local GH_RETRY_S = 30

---Token from $GH_TOKEN, $GITHUB_TOKEN, or `gh auth token`.
---@return string? token
function M.token()
  for _, name in ipairs({ "GH_TOKEN", "GITHUB_TOKEN" }) do
    local v = os.getenv(name)
    if v and v ~= "" then
      return v
    end
  end
  local recently_failed = gh_failed_at and os.time() - gh_failed_at < GH_RETRY_S
  if gh_token == nil and not recently_failed and vim.fn.executable("gh") == 1 then
    local res = M.run({ "gh", "auth", "token" })
    local t = res.code == 0 and vim.trim(res.stdout or "") or ""
    gh_token = t ~= "" and t or nil
    gh_failed_at = not gh_token and os.time() or nil
  end
  return gh_token
end

---Forget the memoized `gh` token, and a recent failure to get one (tests).
function M.reset_token()
  gh_token, gh_failed_at = nil, nil
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
    -- a stalled connection must fail instead of leaving the review "loading"
    -- forever; file contents can be large, so they get more time
    "--connect-timeout", "10",
    "--max-time", opts.raw and "300" or "60",
    api_base(host) .. path, -- last: tests read the URL from here
  }
end

local function graphql_url(host)
  return host == "github.com" and "https://api.github.com/graphql" or ("https://" .. host .. "/api/graphql")
end

-- A GraphQL query: POSTed as JSON; the URL stays last like in request_args.
local function graphql_args(token, host, query, variables)
  return {
    "curl", "-sS", "-L", "-X", "POST",
    "-H", "Authorization: Bearer " .. token,
    "-H", "Content-Type: application/json",
    "-w", "\n%{http_code}",
    "--connect-timeout", "10",
    "--max-time", "60",
    "--data-binary", vim.json.encode({ query = query, variables = variables }),
    graphql_url(host),
  }
end

local function http_status(res)
  return tonumber(((res and res.stdout or ""):match("\n(%d+)$")))
end

-- curl exits that a second try can fix: cannot resolve / connect, timed out,
-- TLS handshake failed, empty reply, connection reset. A missing curl (-1) or a
-- bad request is not among them.
local CURL_RETRY = { [6] = true, [7] = true, [28] = true, [35] = true, [52] = true, [56] = true }

local function transient(res)
  if res == nil then
    return false
  end
  if res.code ~= 0 then
    return CURL_RETRY[res.code] == true
  end
  local status = http_status(res)
  return status == 502 or status == 503 or status == 504
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
  end
  if not status or status >= 400 then
    -- GitHub explains errors in a JSON `message`
    local ok, data = pcall(vim.json.decode, body or "")
    local msg = ok and type(data) == "table" and type(data.message) == "string" and data.message or nil
    if status == 429 or (status == 403 and msg and msg:lower():find("rate limit", 1, true)) then
      return nil, "GitHub rate limit reached: try again later (or set GH_TOKEN / run `gh auth login`)"
    elseif status == 401 or status == 403 then
      return nil, string.format("GitHub denied access (%d%s); check the token's scope for this repo", status, msg and (": " .. msg) or "")
    end
    return nil, string.format("GitHub returned %s for %s%s", tostring(status), path, msg and (": " .. msg) or "")
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

---GET `path` from the API of `host`. Transient failures (502/503/504, network
---errors, timeouts) are retried.
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

---GraphQL errors come with HTTP 200: turn them into an error too.
local function graphql_result(data, err)
  if not data then
    return nil, err
  end
  if type(data.errors) == "table" and data.errors[1] then
    return nil, "GitHub GraphQL: " .. tostring(data.errors[1].message or "error")
  end
  return data.data
end

---Run a GraphQL query (blocking); transient failures are retried like M.get.
---@return table? data the `data` of the response
---@return string? err
function M.graphql(host, query, variables)
  local token = M.token()
  if not token then
    return nil, NO_TOKEN
  end
  local args = graphql_args(token, host, query, variables)
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
  return graphql_result(interpret(res, "/graphql", {}))
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
      local proc, failed = spawn(list[i], function(res)
        results[i] = res
        active = active - 1
        done = done + 1
      end)
      if not proc then
        results[i] = failed
        active = active - 1
        done = done + 1
      end
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
---Keep the snapshots of the previous head when the PR moved: head/ becomes
---prev-head/ (for "changed since your last review"); base/ is dropped.
---@return table? previous { head_sha, base_sha, commits } of the earlier generation
local function new_generation(root, cache, base_sha, head_sha)
  local prev = session.load(root)
  if not (prev and prev.head_sha and (prev.base_sha ~= base_sha or prev.head_sha ~= head_sha)) then
    return prev and prev.previous or nil
  end
  local prev_dir = cache .. "/prev-head"
  vim.fn.delete(prev_dir, "rf")
  if vim.uv.fs_stat(cache .. "/head") then
    vim.uv.fs_rename(cache .. "/head", prev_dir)
  end
  vim.fn.delete(cache .. "/base", "rf")
  return { head_sha = prev.head_sha, base_sha = prev.base_sha, commits = prev.commits }
end

---The changed-file entries and the snapshot downloads still missing.
local function plan(ref, files, cache, base_sha, head_sha)
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
  return changed, jobs
end

local function record(ref, pr, changed, cache, previous)
  return {
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
    base_sha = pr.base.sha,
    head_sha = pr.head.sha,
    commits = pr.commits,
    previous = previous,
    cache = cache,
    files = changed,
  }
end

---Fetch a PR into its session directory and return the session root (blocking;
---used by the CLI). The review UI uses M.open_pr_async.
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
  vim.fn.mkdir(root, "p")
  local previous = new_generation(root, cache, pr.base.sha, pr.head.sha)
  vim.fn.mkdir(cache, "p")
  local changed, jobs = plan(ref, files, cache, pr.base.sha, pr.head.sha)
  if #jobs > 0 then
    local results = M.get_many(ref.host, jobs)
    local failed
    for i, job in ipairs(jobs) do
      local r = results[i]
      if r.body then
        local saved, werr = pcall(write_snapshot, cache, job.side, job.dest, r.body)
        if not saved then
          failed = failed or ("cannot save: " .. tostring(werr))
        end
      elseif r.err and not r.err:find("^not found") then
        failed = failed or r.err -- a 404 just means "no text here"; anything else is worth reporting
      end
    end
    if failed then
      return nil, "could not fetch every file: " .. failed
    end
  end
  session.save(root, record(ref, pr, changed, cache, previous))
  store.ensure_dir(root)
  return root
end

-- Non-blocking --------------------------------------------------------------------

---Run a command without blocking; `cb(result)` on the main loop. When `M.run` is
---replaced (tests) it runs through it right away.
function M.run_async(args, cb)
  if M.run ~= default_run then
    local ok, res = pcall(M.run, args)
    return cb(ok and res or { code = -1, stdout = "", stderr = tostring(res) })
  end
  local proc, failed = spawn(args, function(res)
    vim.schedule(function()
      cb(res)
    end)
  end)
  if not proc then
    cb(failed) -- e.g. curl is not installed
  end
end

---GET without blocking, with the same retries as M.get. cb(body, err)
function M.get_async(host, path, opts, cb)
  opts = opts or {}
  local token = M.token()
  if not token then
    return cb(nil, NO_TOKEN)
  end
  local args = request_args(token, host, path, opts)
  local attempt = 0
  local function try()
    attempt = attempt + 1
    M.run_async(args, function(res)
      if transient(res) and attempt <= M.retries then
        return vim.defer_fn(try, M.retry_delay_ms * attempt)
      end
      cb(interpret(res, path, opts))
    end)
  end
  try()
end

---GraphQL without blocking. cb(data?, err?)
function M.graphql_async(host, query, variables, cb)
  local token = M.token()
  if not token then
    return cb(nil, NO_TOKEN)
  end
  local args = graphql_args(token, host, query, variables)
  local attempt = 0
  local function try()
    attempt = attempt + 1
    M.run_async(args, function(res)
      if transient(res) and attempt <= M.retries then
        return vim.defer_fn(try, M.retry_delay_ms * attempt)
      end
      cb(graphql_result(interpret(res, "/graphql", {})))
    end)
  end
  try()
end

local function files_async(ref, cb)
  local all, page = {}, 1
  local function next_page()
    M.get_async(ref.host, string.format("/repos/%s/%s/pulls/%d/files?per_page=100&page=%d", ref.owner, ref.repo, ref.number, page), nil, function(data, err)
      if not data then
        return cb(nil, err)
      end
      vim.list_extend(all, data)
      if #data < 100 or page >= 30 then
        return cb(all)
      end
      page = page + 1
      next_page()
    end)
  end
  next_page()
end

---Fetch a PR without blocking Neovim.
---  hooks.on_meta(root)            the file list is known (session saved): the UI can open
---  hooks.on_file(path, side)      a snapshot arrived
---  hooks.on_progress(done, total)
---  hooks.on_done(root?, err?, failed)  failed = { [path] = err } for files that could not be read
function M.open_pr_async(ref, hooks)
  hooks = hooks or {}
  local function call(name, ...)
    if hooks[name] then
      local ok, e = pcall(hooks[name], ...)
      if not ok then
        vim.notify("code-review: " .. tostring(e), vim.log.levels.ERROR)
      end
    end
  end
  M.get_async(ref.host, string.format("/repos/%s/%s/pulls/%d", ref.owner, ref.repo, ref.number), nil, function(pr, err)
    if not pr then
      return call("on_done", nil, err, {})
    end
    files_async(ref, function(files, ferr)
      if not files then
        return call("on_done", nil, ferr, {})
      end
      local root, cache = session.dirs(ref)
      -- a disk error (full, read-only) must still end in on_done, never in a review stuck "loading"
      local ok, changed, jobs = pcall(function()
        vim.fn.mkdir(root, "p")
        local previous = new_generation(root, cache, pr.base.sha, pr.head.sha)
        vim.fn.mkdir(cache, "p")
        local c, j = plan(ref, files, cache, pr.base.sha, pr.head.sha)
        session.save(root, record(ref, pr, c, cache, previous)) -- early: the review can open now
        store.ensure_dir(root)
        return c, j
      end)
      if not ok then
        return call("on_done", nil, "cannot save the review: " .. tostring(changed), {})
      end
      call("on_meta", root)
      local failed, done, next_i, active = {}, 0, 1, 0
      if #jobs == 0 then
        return call("on_done", root, nil, failed)
      end
      local function launch()
        while active < M.concurrency and next_i <= #jobs do
          local job = jobs[next_i]
          next_i = next_i + 1
          active = active + 1
          M.get_async(ref.host, job.path, { raw = true }, function(body, jerr)
            active = active - 1
            done = done + 1
            if body then
              local saved, werr = pcall(write_snapshot, cache, job.side, job.dest, body)
              if saved then
                call("on_file", job.dest, job.side == "base" and "old" or "new")
              else
                failed[job.dest] = "cannot save: " .. tostring(werr)
              end
            elseif jerr and not jerr:find("^not found") then
              failed[job.dest] = jerr
            end
            call("on_progress", done, #jobs)
            if done == #jobs then
              return call("on_done", root, nil, failed)
            end
            launch()
          end)
        end
      end
      launch()
    end)
  end)
end

---Ask GitHub (without blocking) whether the PR moved. cb({ head_sha, base_sha, commits }?, err?)
function M.check_update(s, cb)
  M.get_async(s.host or "github.com", string.format("/repos/%s/%s/pulls/%d", s.owner, s.repo, s.number), nil, function(pr, err)
    if not pr then
      return cb(nil, err)
    end
    cb({ head_sha = pr.head.sha, base_sha = pr.base.sha, commits = pr.commits })
  end)
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
