local store = require("code-review.store")
local session = require("code-review.session")
local github = require("code-review.github")
local diff = require("code-review.diff")
local ac = require("code-review")

local api = vim.api
local bin = PLUGIN_ROOT .. "/bin/code-review"

local routes = {
  ["/pulls/5/files"] = {
    { filename = "src/a.py", status = "modified", additions = 1, deletions = 1 },
    { filename = "src/new.py", status = "added", additions = 1, deletions = 0 },
  },
  ["/pulls/5"] = {
    title = "Tweak", html_url = "https://github.com/acme/api/pull/5", state = "open", draft = false,
    body = "Fixes the y value.\r\n\r\n- [ ] checked on staging",
    user = { login = "alice" }, labels = { { name = "bug" }, { name = "backend" } },
    base = { sha = "BASE1234", ref = "main" }, head = { sha = "HEAD1234", ref = "tweak" },
  },
  ["contents/src/a.py?ref=BASE1234"] = "x = 1\ny = 2\nz = 3\n",
  ["contents/src/a.py?ref=HEAD1234"] = "x = 1\ny = 20\nz = 3\n",
  ["contents/src/new.py?ref=HEAD1234"] = "print('new')\n",
  ["contents/lib/util.py?ref=HEAD1234"] = "def util(): pass\n",
  ["contents/lib?ref=HEAD1234"] = { { name = "util.py", type = "file" }, { name = "sub", type = "dir" } },
}

local function fake()
  github.run = function(args)
    local url = args[#args]
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
end

local function cli(args)
  local cmd = { bin }
  vim.list_extend(cmd, args)
  local r = vim.system(cmd, { text = true, env = { GH_TOKEN = "t", NVIM_CODE_REVIEW_ROOT = "" } }):wait()
  return r.code, r.stdout, r.stderr
end

local function feed(keys)
  api.nvim_feedkeys(api.nvim_replace_termcodes(keys, true, false, true), "x", false)
end

local function submit(text)
  api.nvim_buf_set_lines(0, 0, -1, false, { text })
  api.nvim_feedkeys(api.nvim_replace_termcodes("<C-s>", true, false, true), "x", false)
end

describe("PR review", function()
  ac.setup({ notify = false })
  vim.env.GH_TOKEN = "t"
  fake()
  local root = diff.open("acme/api#5")

  it("opens the first file as a side-by-side diff", function()
    assert(root)
    eq(#vim.tbl_filter(function(w) return vim.wo[w].diff end, api.nvim_tabpage_list_wins(0)), 2)
    local left = api.nvim_win_get_buf(vim.fn.win_getid(vim.fn.winnr("h")))
    eq(vim.fs.basename(api.nvim_buf_get_name(left)), "a.py")
    assert(api.nvim_buf_get_name(left):find("/base/src/a.py", 1, true))
    eq(vim.bo[left].modifiable, false)
  end)

  it("colors the old side red and the new side green, only in the diff windows", function()
    local global_before = api.nvim_get_hl(0, { name = "DiffAdd", link = false })
    diff.show_file(root, "src/a.py")
    local wins = vim.tbl_filter(function(w) return vim.wo[w].diff end, api.nvim_tabpage_list_wins(0))
    table.sort(wins, function(a, b) return api.nvim_win_get_position(a)[2] < api.nvim_win_get_position(b)[2] end)
    assert(vim.wo[wins[1]].winhighlight:find("DiffAdd:CodeReviewDiffRemoved", 1, true))
    assert(vim.wo[wins[2]].winhighlight:find("DiffAdd:CodeReviewDiffAdded", 1, true))
    local red = api.nvim_get_hl(0, { name = "CodeReviewDiffRemoved", link = false })
    local green = api.nvim_get_hl(0, { name = "CodeReviewDiffAdded", link = false })
    assert(red.bg and green.bg and red.bg ~= green.bg)
    assert(math.floor(red.bg / 65536) > math.floor(red.bg % 256), "old side should lean red")
    assert(math.floor(green.bg / 256) % 256 > math.floor(green.bg % 256), "new side should lean green")
    eq(api.nvim_get_hl(0, { name = "DiffAdd", link = false }), global_before) -- the global group is untouched
  end)

  it("stores the description and shows it in a read-only markdown float", function()
    local st = session.load(root)
    eq({ st.author, st.labels, st.body }, { "alice", { "bug", "backend" }, "Fixes the y value.\n\n- [ ] checked on staging" })
    diff.description(root)
    local win = api.nvim_get_current_win()
    eq(api.nvim_win_get_config(win).relative, "editor")
    local buf = api.nvim_win_get_buf(win)
    local text = table.concat(api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
    assert(text:find("# Tweak", 1, true), text)
    assert(text:find("by @alice", 1, true), text)
    assert(text:find("labels: bug, backend", 1, true), text)
    assert(text:find("- [ ] checked on staging", 1, true), text)
    eq({ vim.bo[buf].filetype, vim.bo[buf].modifiable }, { "markdown", false })
    feed("q")
    eq(api.nvim_win_is_valid(win), false)
  end)

  it("says so when a PR has no description", function()
    local lines = diff.description_lines({ title = "T", owner = "o", repo = "r", number = 1, body = "  \n", base_ref = "main", head_ref = "x" })
    eq(lines[#lines], "_No description provided._")
  end)

  it("uses GitHub Dark Default accents with readable contrast on request", function()
    local normal = api.nvim_get_hl(0, { name = "Normal", link = false })
    api.nvim_set_hl(0, "Normal", { fg = 0xe6edf3, bg = 0x0d1117 })
    vim.o.background = "dark"
    ac.config.diff_colors = "github-dark"
    for _, n in ipairs({ "CodeReviewDiffAdded", "CodeReviewDiffAddedText", "CodeReviewDiffRemoved", "CodeReviewDiffRemovedText" }) do
      api.nvim_set_hl(0, n, {})
    end
    diff.highlights()
    local function bg(n) return api.nvim_get_hl(0, { name = n, link = false }).bg end
    local function ch(c) return math.floor(c / 65536) % 256, math.floor(c / 256) % 256, c % 256 end
    local ar, ag = ch(bg("CodeReviewDiffAdded"))
    local rr, rg = ch(bg("CodeReviewDiffRemoved"))
    assert(ag > ar and rr > rg, "added should lean green, removed red")
    -- the changed words are stronger than the line, but text must stay readable on both
    assert(bg("CodeReviewDiffAddedText") ~= bg("CodeReviewDiffAdded"))
    local function lum(c)
      local function f(x) x = x / 255 return x <= 0.03928 and x / 12.92 or ((x + 0.055) / 1.055) ^ 2.4 end
      local r, g, b = ch(c)
      return 0.2126 * f(r) + 0.7152 * f(g) + 0.0722 * f(b)
    end
    for _, n in ipairs({ "CodeReviewDiffAdded", "CodeReviewDiffAddedText", "CodeReviewDiffRemoved", "CodeReviewDiffRemovedText" }) do
      local ratio = (lum(0xe6edf3) + 0.05) / (lum(bg(n)) + 0.05)
      assert(ratio >= 4.5, n .. " contrast " .. ratio)
    end
    ac.config.diff_colors = true
    api.nvim_set_hl(0, "Normal", normal)
  end)

  it("comments on the new side", function()
    vim.cmd("wincmd l") -- head
    api.nvim_win_set_cursor(0, { 2, 0 })
    ac.add(2, 2)
    submit("why 20?")
    local t = store.read(root).threads[1]
    eq({ t.file, t.side, t.base, t.anchor.text }, { "src/a.py", nil, nil, { "y = 20" } })
  end)

  it("comments on the old side and records the base commit", function()
    vim.cmd("wincmd h") -- base
    api.nvim_win_set_cursor(0, { 2, 0 })
    ac.add(2, 2)
    submit("was 2 fine?")
    local t = store.read(root).threads[2]
    eq({ t.file, t.side, t.base, t.anchor.text }, { "src/a.py", "old", "BASE1234", { "y = 2" } })
  end)

  it("shows each side only its own threads", function()
    local function marks(buf)
      return #vim.tbl_filter(function(m)
        return m[4].virt_text ~= nil
      end, api.nvim_buf_get_extmarks(buf, api.nvim_create_namespace("code-review"), 0, -1, { details = true }))
    end
    ac.render(api.nvim_get_current_buf())
    eq(marks(api.nvim_get_current_buf()), 1)
    vim.cmd("wincmd l")
    ac.render(api.nvim_get_current_buf())
    eq(marks(api.nvim_get_current_buf()), 1)
  end)

  it("keeps both threads open on re-anchor", function()
    require("code-review.anchor").reanchor_root(root)
    eq({ store.read(root).threads[1].status, store.read(root).threads[2].status }, { "open", "open" })
  end)

  it("steps to the next file with ]f", function()
    diff.step(1)
    assert(api.nvim_buf_get_name(0):find("/head/src/new.py", 1, true))
    eq(#vim.tbl_filter(function(w) return vim.wo[w].diff end, api.nvim_tabpage_list_wins(0)), 0)
    diff.step(1) -- already on the last file: stays, no wrap-around
    assert(api.nvim_buf_get_name(0):find("/head/src/new.py", 1, true), api.nvim_buf_get_name(0))
    eq(diff.step(1), false)
    eq(diff.step(-1), true)
    assert(api.nvim_buf_get_name(0):find("/src/a.py", 1, true))
    eq(diff.step(-1), false) -- first file: stays
    assert(api.nvim_buf_get_name(0):find("/src/a.py", 1, true))
  end)

  local function diff_wins()
    return #vim.tbl_filter(function(w) return vim.wo[w].diff end, api.nvim_tabpage_list_wins(0))
  end

  it("keeps <CR> working in the thread list, opening PR items as diffs", function()
    ac.list(false)
    assert(vim.bo.buftype == "quickfix")
    api.nvim_win_set_cursor(0, { 1, 0 })
    feed("<CR>")
    assert(api.nvim_buf_get_name(0):find("src/a.py", 1, true), api.nvim_buf_get_name(0))
    eq(diff_wins(), 2)
    vim.cmd("cclose")
  end)

  it("steps through threads across files in the diff view", function()
    local t = store.read(root).threads[2] -- old side, line 2
    ac.step_project(api.nvim_get_current_win(), root, t.id, 0, 1)
    -- the thread float has focus; look at the diff windows behind it
    local names = {}
    for _, w in ipairs(api.nvim_tabpage_list_wins(0)) do
      if vim.wo[w].diff then
        names[#names + 1] = api.nvim_buf_get_name(api.nvim_win_get_buf(w))
      end
    end
    eq(#names, 2)
    assert(names[1]:find("src/a.py", 1, true) and names[2]:find("src/a.py", 1, true), vim.inspect(names))
    for _, w in ipairs(api.nvim_tabpage_list_wins(0)) do
      if api.nvim_win_get_config(w).relative ~= "" then
        pcall(api.nvim_win_close, w, true)
      end
    end
  end)

  it("maps ]f and [f only on snapshot buffers", function()
    diff.show_file(root, "src/a.py")
    local function has(lhs)
      return vim.fn.maparg(lhs, "n", false, true).buffer == 1
    end
    eq({ has("]f"), has("[f") }, { true, true })
    vim.cmd.enew()
    eq(has("]f"), false)
  end)

  describe("cli", function()
    it("prints the PR structure as JSON", function()
      local code, out = cli({ "--pr", "acme/api#5", "diff", "--json" })
      eq(code, 0)
      local d = vim.json.decode(out)
      eq({ d.pr, d.base.sha, d.head.sha, #d.files }, { "acme/api#5", "BASE1234", "HEAD1234", 2 })
      eq(d.files[2].old, nil)
      assert(d.files[1].old:find("/base/src/a.py", 1, true))
    end)

    it("includes the description in the diff output", function()
      local _, out = cli({ "--pr", "acme/api#5", "diff", "--json" })
      local d = vim.json.decode(out)
      eq({ d.description, d.author, d.labels }, { "Fixes the y value.\n\n- [ ] checked on staging", "alice", { "bug", "backend" } })
      local _, text = cli({ "--pr", "acme/api#5", "diff" })
      assert(text:find("Description (by @alice):", 1, true), text)
      assert(text:find("Fixes the y value.", 1, true), text)
    end)

    it("lists threads with their side", function()
      local code, out = cli({ "--pr", "acme/api#5", "list" })
      eq(code, 0)
      assert(out:find("src/a.py (OLD side @BASE123)", 1, true), out)
    end)

    it("serves cached files and fetches missing ones on demand", function()
      local code, out = cli({ "--pr", "acme/api#5", "file", "src/a.py", "--side", "old" })
      eq(code, 0)
      eq(vim.fn.readfile(vim.trim(out))[2], "y = 2")
    end)

    it("reports a PR that was never fetched", function()
      local code, _, err = cli({ "--pr", "acme/api#999", "diff" })
      eq(code, 1)
      assert(err:find("not fetched yet", 1, true), err)
    end)

    it("rejects --side for non-PR garbage and commands outside a PR", function()
      local code, _, err = cli({ "--pr", "nonsense", "diff" })
      eq(code, 1)
      assert(err:find("expected a PR URL", 1, true), err)
    end)

    it("lets an agent add an old-side comment from a snapshot path", function()
      local _, out = cli({ "--pr", "acme/api#5", "diff", "--json" })
      local old = vim.json.decode(out).files[1].old
      local code, o, err = cli({ "--pr", "acme/api#5", "add", old, "3", "z unchanged?", "--side", "old", "--json" })
      eq(code, 0)
      assert(o:find("t_", 1, true), err)
      local t = store.read(root).threads[3]
      eq({ t.file, t.side, t.base, t.anchor.text }, { "src/a.py", "old", "BASE1234", { "z = 3" } })
    end)
  end)

  describe("viewed files", function()
    local sidebar = require("code-review.sidebar")
    local function row(name) -- the sidebar line of a file
      local _, buf = sidebar.find_win()
      for _, l in ipairs(api.nvim_buf_get_lines(buf, 0, -1, false)) do
        if l:find(" " .. name, 1, true) then
          return l
        end
      end
      error("no sidebar row for " .. name)
    end
    local function header()
      local _, buf = sidebar.find_win()
      return api.nvim_buf_get_lines(buf, 0, 1, false)[1]
    end
    local function focus_row(name)
      local win, buf = sidebar.find_win()
      api.nvim_set_current_win(win)
      for i, l in ipairs(api.nvim_buf_get_lines(buf, 0, -1, false)) do
        if l:find(" " .. name, 1, true) then
          return api.nvim_win_set_cursor(win, { i, 0 })
        end
      end
    end
    local function current()
      return api.nvim_buf_get_name(0)
    end

    it("marking a file viewed shows a check mark, counts it and moves to the next file", function()
      diff.show_file(root, "src/a.py")
      diff.toggle_viewed(root)
      assert(row("a.py"):find("✓", 1, true), row("a.py"))
      assert(not row("new.py"):find("✓", 1, true), row("new.py"))
      assert(header():find("1/2 viewed", 1, true), header())
      assert(current():find("/head/src/new.py", 1, true), current())
    end)

    it("]f skips viewed files and says so when nothing is left", function()
      -- src/a.py is viewed, we are on src/new.py: there is nothing else to review
      eq(diff.step(1), false)
      assert(current():find("/head/src/new.py", 1, true), current())
      eq(diff.step(-1), false) -- going back would only reach the viewed a.py
      assert(current():find("/head/src/new.py", 1, true), current())
      diff.step(-1, true) -- explicitly including viewed files walks everything
      assert(current():find("/src/a.py", 1, true), current())
    end)

    it("unmarking brings the file back into the walk", function()
      diff.toggle_viewed(root, "src/a.py")
      assert(not row("a.py"):find("✓", 1, true), row("a.py"))
      diff.show_file(root, "src/new.py")
      diff.step(-1)
      assert(current():find("/src/a.py", 1, true), current())
    end)

    it("a viewed file comes back when its content changes", function()
      session.set_viewed(root, "src/a.py", true)
      eq(session.viewed_map(root)["src/a.py"], true)
      local head = session.snapshot_path(root, "src/a.py", "new")
      local before = vim.fn.readfile(head)
      vim.fn.writefile({ "x = 1", "y = 99", "z = 3" }, head) -- as if a new commit changed it
      eq(session.viewed_map(root)["src/a.py"], false)
      vim.fn.writefile(before, head)
      eq(session.viewed_map(root)["src/a.py"], true) -- same text again: viewed again
      session.set_viewed(root, "src/a.py", false)
    end)

    it("]f and [f work in the sidebar and in a thread list, never the built-in gf (E447)", function()
      diff.show_file(root, "src/a.py")
      focus_row("a.py")
      local ok, err = pcall(feed, "]f")
      assert(ok, tostring(err))
      assert(current():find("/src/new.py", 1, true), current())
      focus_row("new.py")
      ok, err = pcall(feed, "[f")
      assert(ok, tostring(err))
      assert(current():find("/src/a.py", 1, true), current())
      ac.list(false) -- the thread list is still a quickfix list
      api.nvim_win_set_cursor(0, { 1, 0 })
      ok, err = pcall(feed, "]f")
      assert(ok, tostring(err))
      vim.cmd("cclose")
    end)

    it("v in the sidebar marks the row under the cursor", function()
      diff.show_file(root, "src/a.py")
      focus_row("new.py")
      feed("v")
      assert(row("new.py"):find("✓", 1, true), row("new.py"))
      diff.toggle_viewed(root, "src/new.py")
      assert(not row("new.py"):find("✓", 1, true), row("new.py"))
    end)

    it("shows the agent which files the user has viewed", function()
      session.set_viewed(root, "src/new.py", true)
      local _, out = cli({ "--pr", "acme/api#5", "diff", "--json" })
      local d = vim.json.decode(out)
      eq({ d.files[1].viewed, d.files[2].viewed }, { false, true })
      local _, text = cli({ "--pr", "acme/api#5", "diff" })
      assert(text:find("src/new.py   [viewed by the user]", 1, true), text)
      session.set_viewed(root, "src/new.py", false)
    end)
  end)
end)

describe("PR cache", function()
  local old_routes = routes

  it("drops stale snapshots when the PR gets new commits", function()
    local function pr(head, text)
      routes = {
        ["/pulls/6/files"] = { { filename = "m.py", status = "modified", additions = 1, deletions = 0 } },
        ["/pulls/6"] = { title = "T", html_url = "u", base = { sha = "B", ref = "main" }, head = { sha = head, ref = "x" } },
        ["contents/m.py?ref=B"] = "base",
        ["contents/m.py?ref=" .. head] = text,
      }
      github.run = function(args)
        local url, best = args[#args], nil
        for suffix in pairs(routes) do
          if url:find(suffix, 1, true) and (not best or #suffix > #best) then
            best = suffix
          end
        end
        local b = best and routes[best]
        return { code = 0, stdout = best and ((type(b) == "string" and b or vim.json.encode(b)) .. "\n200") or "\n404", stderr = "" }
      end
    end
    local ref = { host = "github.com", owner = "acme", repo = "api", number = 6 }
    pr("H1", "v1")
    local r = assert(github.open_pr(ref))
    eq(session.lines(r, "m.py"), { "v1" })
    pr("H2", "v2")
    assert(github.open_pr(ref))
    eq(session.lines(r, "m.py"), { "v2" })
    eq(session.load(r).head_sha, "H2")
  end)

  it("asks `gh auth token` only once", function()
    local calls, old = 0, github.run
    local saved = { vim.env.GH_TOKEN, vim.env.GITHUB_TOKEN }
    vim.env.GH_TOKEN, vim.env.GITHUB_TOKEN = nil, nil
    github.reset_token()
    github.run = function() calls = calls + 1 return { code = 0, stdout = "tok\n", stderr = "" } end
    eq(github.token(), "tok")
    eq(github.token(), "tok")
    eq(calls, 1)
    github.run, vim.env.GH_TOKEN, vim.env.GITHUB_TOKEN = old, saved[1], saved[2]
    github.reset_token()
    routes = old_routes
  end)
end)
