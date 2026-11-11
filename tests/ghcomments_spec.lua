local store = require("code-review.store")
local github = require("code-review.github")
local gh = require("code-review.ghcomments")
local diff = require("code-review.diff")
local ac = require("code-review")

local api = vim.api
local bin = PLUGIN_ROOT .. "/bin/code-review"

local function comment(author, body, hunk)
  return {
    author = { login = author }, body = body, createdAt = "2026-11-01T10:00:00Z",
    url = "https://github.com/acme/api/pull/9#discussion_r" .. author, diffHunk = hunk,
  }
end

local function thread(o)
  return {
    isResolved = o.resolved or false, isOutdated = o.outdated or false, path = o.path or "src/a.py",
    line = o.line, startLine = o.start, originalLine = o.original or o.line, diffSide = o.side or "RIGHT",
    subjectType = o.subject or "LINE",
    comments = { totalCount = o.total or #o.comments, nodes = o.comments },
  }
end

local THREADS = {
  -- 1: open, on the new side, still on its line
  thread({ line = 2, comments = {
    comment("bob", "Why 20?", "@@ -1,3 +1,3 @@\n x = 1\n-y = 2\n+y = 20"),
    comment("carol", "Agreed, looks odd.\r\nSecond line.", nil),
  } }),
  -- 2: resolved
  thread({ line = 1, resolved = true, comments = { comment("bob", "nit", "@@ -1 +1 @@\n x = 1") } }),
  -- 3: outdated (GitHub has no current line)
  thread({ outdated = true, original = 7, comments = { comment("dave", "gone now", "@@ -5,3 +5,3 @@\n+old = 1") } }),
  -- 4: GitHub's line no longer holds that code here: listed, never drawn on the wrong line
  thread({ line = 3, comments = { comment("erin", "z?", "@@ -2,2 +2,2 @@\n+z = 30") } }),
  -- 5: on the old side
  thread({ line = 2, side = "LEFT", comments = { comment("frank", "the old value was right", "@@ -1,3 +1,3 @@\n x = 1\n-y = 2") } }),
  -- 6: about the whole file, with more comments than fetched
  thread({ subject = "FILE", total = 3, comments = { comment("gina", "split this file?", nil) } }),
  -- 7: resolved and outdated: settled, so resolved
  thread({ resolved = true, outdated = true, original = 9, comments = { comment("hal", "fixed already", "@@ -9 +9 @@\n+w = 1") } }),
  -- 8: another file, without threads of yours (sidebar columns)
  thread({ path = "src/b.py", line = 1, comments = { comment("bob", "b?", "@@ -0,0 +1 @@\n+b = 1") } }),
}

local graphql = { data = { repository = { pullRequest = { reviewThreads = { totalCount = #THREADS, nodes = THREADS } } } } }

local routes = {
  ["/pulls/9/files"] = {
    { filename = "src/a.py", status = "modified", additions = 1, deletions = 1 },
    { filename = "src/b.py", status = "added", additions = 12, deletions = 0 },
  },
  ["/pulls/9"] = {
    title = "Tweak", html_url = "https://github.com/acme/api/pull/9", state = "open", body = "",
    user = { login = "alice" }, labels = {},
    base = { sha = "BASE9", ref = "main" }, head = { sha = "HEAD9", ref = "tweak" },
  },
  ["contents/src/a.py?ref=BASE9"] = "x = 1\ny = 2\nz = 3\n",
  ["contents/src/a.py?ref=HEAD9"] = "x = 1\ny = 20\nz = 3\n",
  ["contents/src/b.py?ref=HEAD9"] = "b = 1\n",
  ["/graphql"] = graphql,
}

local posted, posts = nil, 0
github.run = function(args)
  local url = args[#args]
  if url:find("/graphql$") then
    posted, posts = args, posts + 1
  end
  local best
  for suffix in pairs(routes) do
    if url:find(suffix, 1, true) and (not best or #suffix > #best) then
      best = suffix
    end
  end
  if not best then
    return { code = 0, stdout = "\n404", stderr = "" }
  end
  local b = routes[best]
  return { code = 0, stdout = (type(b) == "string" and b or vim.json.encode(b)) .. "\n200", stderr = "" }
end

local function cli(args)
  local cmd = { bin }
  vim.list_extend(cmd, args)
  local r = vim.system(cmd, { text = true, env = { GH_TOKEN = "t", NVIM_CODE_REVIEW_ROOT = "" } }):wait()
  return r.code, r.stdout, r.stderr
end

local function labels(buf)
  local res = {}
  for _, m in ipairs(api.nvim_buf_get_extmarks(buf, api.nvim_create_namespace("code-review-github"), 0, -1, { details = true })) do
    res[#res + 1] = { m[2] + 1, m[4].virt_text[1][1] }
  end
  return res
end

describe("GitHub review comments", function()
  it("parses review threads: sides, outdated, whole-file, commented code", function()
    local p = gh.parse(graphql.data)
    eq(p.total, 8)
    local t = p.threads
    eq({ t[1].id, t[1].file, t[1].side, t[1].start, t[1]["end"], t[1].status, t[1].code },
      { "gh1", "src/a.py", "new", 2, 2, "open", "y = 20" })
    eq(t[1].messages[2], { author = "carol", body = "Agreed, looks odd.\nSecond line.", ts = "2026-11-01T10:00:00Z" })
    eq({ t[2].status, t[3].status, t[3]["end"], t[3].original }, { "resolved", "outdated", nil, 7 })
    eq({ t[5].side, t[5].code }, { "old", "y = 2" })
    eq({ t[7].status, t[7].outdated }, { "resolved", true })
    eq({ t[6].file_level, t[6]["end"], t[6].more }, { true, nil, 2 })
  end)

  ac.setup({ notify = false })
  vim.env.GH_TOKEN = "t"
  local root = diff.open("acme/api#9")

  it("are fetched with the PR, by a GraphQL POST to the API", function()
    assert(posted, "no GraphQL request")
    eq(vim.tbl_contains(posted, "POST"), true)
    local body = vim.json.decode(posted[vim.fn.index(posted, "--data-binary") + 2])
    eq(body.variables, { owner = "acme", repo = "api", number = 9 })
    eq(#gh.load(root).threads, 8)
  end)

  it("are drawn on the lines they are about, each side its own, not the stale or resolved ones", function()
    local new = api.nvim_get_current_buf()
    assert(api.nvim_buf_get_name(new):find("/head/src/a.py", 1, true), api.nvim_buf_get_name(new))
    eq(labels(new), { { 2, "  ◎ @carol: Agreed, looks odd.  (2)" } })
    vim.cmd("wincmd h")
    eq(labels(api.nvim_get_current_buf()), { { 2, "  ◎ @frank: the old value was right" } })
    vim.cmd("wincmd l")
  end)

  it("are not threads of yours: nothing to answer, nothing for the agent", function()
    eq(store.read(root).threads, {})
    api.nvim_win_set_cursor(0, { 2, 0 })
    eq({ ac.thread_at_cursor() }, {})
    local code, out = cli({ "--pr", "acme/api#9", "list", "--needs", "agent" })
    eq(code, 0)
    assert(not out:find("Why 20", 1, true), out)
  end)

  it("open read-only from the open key: the conversation, the code, no reply keys", function()
    api.nvim_win_set_cursor(0, { 2, 0 })
    local from = api.nvim_get_current_win()
    ac.command({ fargs = { "open" } })
    local win = api.nvim_get_current_win()
    assert(win ~= from)
    local buf = api.nvim_win_get_buf(win)
    local text = table.concat(api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
    assert(text:find("`src/a.py:2` · on GitHub · open", 1, true), text)
    assert(text:find("y = 20", 1, true) and text:find("**@bob**", 1, true) and text:find("Second line.", 1, true), text)
    eq(vim.bo[buf].modifiable, false)
    eq(vim.fn.maparg("r", "n", false, true).buffer, nil) -- no reply here
    vim.api.nvim_feedkeys("q", "x", false)
    eq(api.nvim_win_is_valid(win), false)
  end)

  it("are listed for the agent by the CLI, and counted in `diff`", function()
    local code, out = cli({ "--pr", "acme/api#9", "github", "--cached" })
    eq(code, 0)
    assert(out:find("Review comments on GitHub: 4 open, 2 outdated, 2 resolved (resolved ones: --all)", 1, true), out)
    assert(out:find("src/a.py:2 · open", 1, true) and out:find("@carol", 1, true), out)
    assert(out:find("src/a.py:2 (OLD side", 1, true), out)
    assert(out:find("src/a.py (outdated: was line 7", 1, true) and out:find("on: old = 1", 1, true), out)
    assert(out:find("src/a.py (outdated: was line 3; the code changed since) · outdated", 1, true) and out:find("on: z = 30", 1, true), out)
    assert(out:find("src/a.py (the whole file)", 1, true) and out:find("(2 more on GitHub)", 1, true), out)
    assert(not out:find("nit", 1, true), out) -- resolved: only with --all
    local _, all = cli({ "--pr", "acme/api#9", "github", "--cached", "--all" })
    assert(all:find("nit", 1, true), all)
    assert(not out:find("fixed already", 1, true), out)
    assert(all:find("src/a.py (outdated: was line 9; the code changed since) · resolved", 1, true), all)
    local _, d = cli({ "--pr", "acme/api#9", "diff" })
    assert(d:find("Review comments on GitHub: 4 open, 2 outdated, 2 resolved", 1, true), d)
  end)

  it("--json gives no line for a thread whose code is gone", function()
    local code, out = cli({ "--pr", "acme/api#9", "github", "--cached", "--json" })
    eq(code, 0)
    local by = {}
    for _, t in ipairs(vim.json.decode(out)) do
      by[t.id] = t
    end
    eq({ by.gh1.status, by.gh1["end"] }, { "open", 2 })
    eq({ by.gh4.status, by.gh4["end"], by.gh4.original }, { "outdated", nil, 3 })
  end)

  it("are fetched again when a review you had opens, and redrawn only when they changed", function()
    local before, mtime = posts, vim.uv.fs_stat(store.paths(root) .. "/github.json").mtime
    diff.open("acme/api#9") -- already on disk: resumes, checks GitHub in the background
    eq(posts, before + 1)
    eq(vim.uv.fs_stat(store.paths(root) .. "/github.json").mtime, mtime) -- same threads: not written
    THREADS[1].comments.nodes[3] = comment("ivan", "Now 21?", nil)
    diff.check_updates(root, true)
    eq(posts, before + 2)
    eq(#gh.find(root, "gh1").messages, 3)
    local buf = api.nvim_get_current_buf()
    assert(api.nvim_buf_get_name(buf):find("/head/src/a.py", 1, true), api.nvim_buf_get_name(buf))
    eq(labels(buf), { { 2, "  ◎ @ivan: Now 21?  (3)" } })
    THREADS[1].comments.nodes[3] = nil
  end)

  it("a GraphQL error is an error, and keeps the copy you have", function()
    routes["/graphql"] = { errors = { { message = "Field 'reviewThreads' doesn't exist" } } }
    local data, err = gh.fetch(root)
    eq(data, nil)
    eq(err, "GitHub GraphQL: Field 'reviewThreads' doesn't exist")
    eq(#gh.load(root).threads, 8)
    routes["/graphql"] = graphql
  end)

  it("are counted per file in the sidebar, in a column of their own", function()
    local sb = require("code-review.sidebar")
    -- a.py: a thread of yours waiting for you (✎1!) and two from GitHub; b.py: one from GitHub only
    store.update(root, function(d)
      d.threads[1] = {
        id = "t_side", file = "src/a.py", range = { start = 1, ["end"] = 1 }, status = "open", needs = "user",
        anchor = { text = { "x = 1" } },
        messages = { { author = "user", body = "?", ts = "2026-11-01T10:00:00Z" }, { author = "agent", body = "!", ts = "2026-11-01T10:01:00Z" } },
      }
    end)
    sb.render(root)
    local text
    for _, w in ipairs(api.nvim_tabpage_list_wins(0)) do
      local b = api.nvim_win_get_buf(w)
      if vim.b[b].code_review_sidebar == root then
        text = api.nvim_buf_get_lines(b, 0, -1, false)
      end
    end
    assert(text, "no sidebar")
    assert(text[1]:find("· ◎3 on GitHub", 1, true), text[1]) -- the open ones drawn: a.py one per side, b.py one
    local a = vim.tbl_filter(function(l) return l:find("a.py", 1, true) end, text)[1]
    local b = vim.tbl_filter(function(l) return l:find("b.py", 1, true) end, text)[1]
    assert(a:find("✎1!  ◎2$") and b:find("  ◎1$"), a .. "\n" .. b)
    local function col(l, what) return vim.fn.strdisplaywidth(l:sub(1, l:find(what, 1, true) - 1)) end
    eq(col(a, "◎"), col(b, "◎")) -- lined up, with and without threads of yours
    eq(col(a, "+"), col(b, "+"))
    eq(vim.fn.strdisplaywidth(a), vim.fn.strdisplaywidth(b))
    store.update(root, function(d) d.threads = {} end)
  end)

  it("can be turned off", function()
    ac.config.github_comments = false
    ac.render(api.nvim_get_current_buf())
    eq(labels(api.nvim_get_current_buf()), {})
    ac.config.github_comments = true
    ac.render(api.nvim_get_current_buf())
    eq(#labels(api.nvim_get_current_buf()), 1)
  end)
end)
