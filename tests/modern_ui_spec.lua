-- Modern UI: fold text, spinner, relative times, fetch progress, icons,
-- pickers, character highlights, "agent is replying", unified view.
-- Own PR fixture (#31) and cleanup after every test.
local store = require("code-review.store")
local anchor = require("code-review.anchor")
local session = require("code-review.session")
local github = require("code-review.github")
local diff = require("code-review.diff")
local progress = require("code-review.progress")
local hunks = require("code-review.hunks")
local ac = require("code-review")

local api = vim.api
progress.use_timer = false

local function numbered(n, changes)
  local t = {}
  for i = 1, n do
    t[i] = string.format("value_%02d = %d", i, i)
  end
  for k, v in pairs(changes or {}) do
    t[k] = v
  end
  return t
end
local BASE = numbered(60)
local HEAD = numbered(60, { [5] = "value_05 = 500" })
table.remove(HEAD, 41)
table.remove(HEAD, 40)
table.insert(HEAD, 40, "inserted_a = 1")
table.insert(HEAD, 41, "inserted_b = 2")
table.insert(HEAD, 42, "inserted_c = 3")

local routes = {
  ["/pulls/31/files"] = {
    { filename = "lib/core.py", status = "modified", additions = 4, deletions = 3 },
    { filename = "lib/util.py", status = "added", additions = 2, deletions = 0 },
  },
  ["/pulls/31"] = {
    title = "Modern fixture", html_url = "u", state = "open",
    base = { sha = "BASE3131aaaa", ref = "main" }, head = { sha = "HEAD3131bbbb", ref = "feature" },
  },
  ["contents/lib/core.py?ref=BASE3131aaaa"] = table.concat(BASE, "\n") .. "\n",
  ["contents/lib/core.py?ref=HEAD3131bbbb"] = table.concat(HEAD, "\n") .. "\n",
  ["contents/lib/util.py?ref=HEAD3131bbbb"] = "def util():\n    return 1\n",
}

local saved_run = github.run
local function fake()
  vim.env.GH_TOKEN = "t"
  github.run = function(args)
    local url, best = args[#args], nil
    for k in pairs(routes) do
      if url:find(k, 1, true) and (not best or #k > #best) then
        best = k
      end
    end
    local b = best and routes[best]
    return { code = 0, stdout = best and ((type(b) == "string" and b or vim.json.encode(b)) .. "\n200") or "\n404", stderr = "" }
  end
end

local root
local function cleanup()
  ac.config.sidebar_position = "left"
  ac.config.diff_layout = "split"
  if ac.inline_enabled() then
    ac.toggle_inline()
  end
  progress.stop()
  diff.close()
  for _, w in ipairs(api.nvim_list_wins()) do
    if api.nvim_win_get_config(w).relative ~= "" then
      pcall(api.nvim_win_close, w, true)
    end
  end
  if root then
    for _, f in ipairs({ "lib/core.py", "lib/util.py" }) do
      session.set_viewed(root, f, false)
    end
    store.update(root, function(d) d.threads = {} end)
  end
  github.run = saved_run
end

local function case(name, fn)
  it(name, function()
    fake()
    local ok, err = pcall(fn)
    cleanup()
    if not ok then
      error(err, 0)
    end
  end)
end

local function wins_by_side()
  local res = {}
  for _, w in ipairs(api.nvim_tabpage_list_wins(0)) do
    local _, file, side = session.infer(api.nvim_buf_get_name(api.nvim_win_get_buf(w)))
    if file and api.nvim_win_get_config(w).relative == "" then
      res[side] = w
    end
  end
  return res
end

describe("modern UI", function()
  ac.setup({ notify = false })
  fake()
  root = diff.open("acme/modern#31")
  cleanup()

  describe("hunks", function()
    case("finds the changed blocks of the fixture and maps lines through them", function()
      local h = hunks.indices(BASE, HEAD)
      eq(#h, 2)
      eq(hunks.map_line(h, 30, true), 30) -- between the hunks: same line
      eq(hunks.map_line(h, 50, true), 51) -- after 2 lines became 3
      eq(hunks.map_line(h, 51, false), 50)
    end)
  end)

  describe("fold text", function()
    case("closed unchanged code says how many lines it hides", function()
      diff.show_file(root, "lib/core.py")
      local w = wins_by_side().new
      api.nvim_set_current_win(w)
      local start = vim.fn.foldclosed(25)
      assert(start > 0, "line 25 should be in a closed fold")
      -- read what is drawn (foldtextresult() would not refresh v:foldstart for a Lua expression)
      vim.cmd("redraw!")
      local pos = vim.fn.screenpos(w, start, 1)
      local text = ""
      for col = pos.col, pos.col + api.nvim_win_get_width(w) - 1 do
        text = text .. vim.fn.screenstring(pos.row, col)
      end
      local n = vim.fn.foldclosedend(25) - start + 1
      assert(text:find(string.format("⋯  %d unchanged lines", n), 1, true), text)
    end)

    case("is only set on the diff panes and goes away with them", function()
      diff.show_file(root, "lib/core.py")
      local w = wins_by_side().new
      assert(vim.wo[w].foldtext:find("code-review.diff", 1, true))
      api.nvim_set_current_win(w)
      vim.cmd.enew()
      eq(vim.wo[w].foldtext, vim.go.foldtext)
    end)
  end)

  describe("relative times", function()
    local function at(ts)
      return ac.parse_utc(ts)
    end

    case("says how long ago, in the user's terms", function()
      local now = ac.now
      ac.now = function() return at("2026-11-04T10:00:00Z") end
      eq(ac.reltime("2026-11-04T09:59:30Z"), "just now")
      eq(ac.reltime("2026-11-04T09:55:00Z"), "5 min ago")
      eq(ac.reltime("2026-11-04T07:00:00Z"), "3 h ago")
      eq(ac.reltime("2026-11-02T10:00:00Z"), "2 d ago")
      eq(ac.reltime("2026-10-01T10:00:00Z"), "2026-10-01")
      eq(ac.reltime("T1"), "T1") -- anything else is left alone
      ac.now = now
    end)

    case("reads stored times as UTC whatever the local time zone", function()
      eq(at("1970-01-01T00:00:00Z"), 0)
      eq(at("2026-11-04T10:00:00Z") - at("2026-11-04T09:00:00Z"), 3600)
    end)

    case("the thread window shows relative times and colors who said what", function()
      diff.show_file(root, "lib/core.py")
      local id = store.update(root, function(d)
        return store.add_thread(d, {
          file = "lib/core.py", start = 5, ["end"] = 5,
          anchor = anchor.capture(HEAD, 5, 5), author = "user", body = "why 500?",
        })
      end)
      store.update(root, function(d) store.add_message(store.find(d, id), "claude", "new default") end)
      ac.open_thread(root, id)
      local buf = api.nvim_get_current_buf()
      local text = table.concat(api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
      assert(text:find("**you** · just now", 1, true), text)
      assert(not text:find("%dT%d"), "no raw timestamps: " .. text)
      local groups = {}
      for _, m in ipairs(api.nvim_buf_get_extmarks(buf, -1, 0, -1, { details = true })) do
        groups[m[4].hl_group or ""] = true
      end
      assert(groups.CodeReviewAuthorYou and groups.CodeReviewAuthorAgent, vim.inspect(groups))
    end)

    case("agents still get absolute times from the CLI", function()
      local id = store.update(root, function(d)
        return store.add_thread(d, {
          file = "lib/core.py", start = 5, ["end"] = 5,
          anchor = anchor.capture(HEAD, 5, 5), author = "user", body = "q",
        })
      end)
      local r = vim.system({ PLUGIN_ROOT .. "/bin/code-review", "--pr", "acme/modern#31", "show", id }, { text = true }):wait()
      assert(r.stdout:find("%d%d%d%d%-%d%d%-%d%dT%d%d:%d%d:%d%dZ"), r.stdout)
    end)
  end)

  describe("spinner", function()
    case("animates the working state, frame by frame", function()
      local clock = progress.clock
      local t = 0
      progress.clock = function() return t end
      diff.show_file(root, "lib/core.py")
      progress.start(root, { pane_id = "w1:p1", title = "Reviewer" })
      -- pretend a poll said "working"
      local poke = require("code-review.poke")
      local run = poke.run
      poke.run = function() return { code = 0, stdout = vim.json.encode({ result = { agent = { agent_status = "working", state_change_seq = 2 } } }), stderr = "" } end
      progress.tick()
      local a = progress.statusline()
      t = t + progress.frame_ns
      local b = progress.statusline()
      assert(a:find("^" .. progress.FRAMES[1]), a)
      assert(b:find("^" .. progress.FRAMES[2]), b)
      assert(not a:find("⟳", 1, true), a)
      poke.run, progress.clock = run, clock
    end)

    case("only runs its timer while the agent works", function()
      progress.use_timer = true
      diff.show_file(root, "lib/core.py")
      progress.start(root, { pane_id = "w1:p1", title = "Reviewer" })
      local poke = require("code-review.poke")
      local run = poke.run
      local status = "working"
      poke.run = function() return { code = 0, stdout = vim.json.encode({ result = { agent = { agent_status = status, state_change_seq = 2, completion_seq = status == "idle" and 3 or nil } } }), stderr = "" } end
      progress.tick()
      eq(progress.animating(), true)
      status = "blocked"
      progress.tick()
      eq(progress.animating(), false)
      status = "working"
      progress.tick()
      eq(progress.animating(), true)
      progress.stop()
      eq(progress.animating(), false)
      poke.run = run
      progress.use_timer = false
    end)
  end)

  describe("fetch progress", function()
    case("counts the files up while a PR opens, then lets go of the hook", function()
      local calls, show = {}, diff.show_progress
      diff.show_progress = function(name, done, total)
        calls[#calls + 1] = { name, done, total }
      end
      local cache = session.cache_base() .. "/github.com/acme/modern/pr-31"
      vim.fn.delete(cache, "rf") -- make it fetch the files again
      diff.open("acme/modern#31")
      diff.show_progress = show
      eq(calls[1], { "acme/modern#31", nil, nil }) -- first the PR itself
      local last = calls[#calls]
      eq({ last[2], last[3] }, { 3, 3 }) -- 2 files: core.py both sides + util.py
      for i = 3, #calls do
        assert(calls[i][2] >= calls[i - 1][2], "progress never goes back")
      end
      eq(github.on_progress, nil)
    end)

    case("draws a bar on the command line", function()
      local text
      local echo = api.nvim_echo
      api.nvim_echo = function(chunks) text = chunks[1][1] end
      diff.show_progress("acme/modern#31", 6, 12)
      api.nvim_echo = echo
      assert(text:find("▰▰▰▰▰▱▱▱▱▱ 6/12 files", 1, true), text)
    end)
  end)

  describe("icons", function()
    local sidebar = require("code-review.sidebar")
    local function lines()
      local _, buf = sidebar.find_win()
      return api.nvim_buf_get_lines(buf, 0, -1, false)
    end
    local function row(name)
      for _, l in ipairs(lines()) do
        if l:find(name, 1, true) then
          return l
        end
      end
    end

    case("show a file-type icon before the name, colored, and keep columns aligned", function()
      local icon = sidebar.icon
      sidebar.icon = function(name) -- stand-in for nvim-web-devicons
        return name:match("%.py$") and "" or "", "DevIconPy"
      end
      diff.show_file(root, "lib/core.py")
      local a, b = row("core.py"), row("util.py")
      assert(a:find("  core.py", 1, true), a)
      local function col(l, ch)
        return vim.fn.strdisplaywidth(l:sub(1, l:find(ch, 1, true) - 1))
      end
      eq(col(a, "+"), col(b, "+"))
      local _, buf = sidebar.find_win()
      local found
      for _, m in ipairs(api.nvim_buf_get_extmarks(buf, -1, 0, -1, { details = true })) do
        found = found or m[4].hl_group == "DevIconPy"
      end
      assert(found, "the icon keeps its color")
      sidebar.icon = icon
    end)

    case("are left out without nvim-web-devicons or with icons = false", function()
      ac.config.icons = false
      diff.show_file(root, "lib/core.py")
      local a = row("core.py")
      assert(a:find(" M core.py", 1, true), a)
      ac.config.icons = "auto"
    end)
  end)

  describe("pickers", function()
    local picker = require("code-review.picker")
    local function waiting_thread()
      local id = store.update(root, function(d)
        return store.add_thread(d, {
          file = "lib/core.py", start = 5, ["end"] = 5,
          anchor = anchor.capture(HEAD, 5, 5), author = "user", body = "why 500?",
        })
      end)
      store.update(root, function(d) store.add_message(store.find(d, id), "agent", "new default") end)
      return id
    end

    case("list PR files and threads as previewable file:line entries", function()
      session.set_viewed(root, "lib/util.py", true)
      diff.refresh_cache(root)
      local files = picker.file_entries(root)
      eq(#files, 2)
      eq(files[1].text, "head/lib/core.py:1: M +4 -3")
      eq(files[2].text, "head/lib/util.py:1: A +2 -0  ✓ viewed")
      waiting_thread()
      local threads = picker.thread_entries(root)
      eq(#threads, 1)
      eq(threads[1].text, "head/lib/core.py:5: ● waiting for you  agent: new default")
    end)

    case("fall back to vim.ui.select and open the chosen thread in the diff", function()
      local fzf, select = picker.fzf, vim.ui.select
      picker.fzf = function() return nil end
      vim.ui.select = function(items, _, cb) cb(items[1]) end
      local id = waiting_thread()
      picker.threads(root)
      picker.fzf, vim.ui.select = fzf, select
      local float = api.nvim_get_current_win()
      eq(api.nvim_win_get_config(float).relative ~= "", true) -- the thread opened
      local w = wins_by_side().new
      eq(api.nvim_win_get_cursor(w)[1], 5)
      local _ = id
    end)

    case("use fzf-lua with its builtin preview when installed", function()
      local got
      local fzf = picker.fzf
      picker.fzf = function()
        return { fzf_exec = function(lines, opts) got = { lines = lines, opts = opts } end }
      end
      diff.show_file(root, "lib/util.py")
      picker.files(root)
      picker.fzf = fzf
      eq(got.opts.previewer, "builtin")
      eq(got.opts.cwd, session.load(root).cache) -- entries are relative to the snapshots
      eq(got.lines[1], "head/lib/core.py:1: M +4 -3")
      got.opts.actions.default({ got.lines[1] }) -- choosing it opens the file
      assert(api.nvim_buf_get_name(api.nvim_win_get_buf(wins_by_side().new)):find("/head/lib/core.py", 1, true))
    end)
  end)

  describe("agent is replying", function()
    local poke = require("code-review.poke")
    local function follow(status)
      local run = poke.run
      poke.run = function()
        return { code = 0, stdout = vim.json.encode({ result = { agent = { agent_status = status, state_change_seq = 2 } } }), stderr = "" }
      end
      progress.tick()
      poke.run = run
    end
    local function new_thread(line)
      return store.update(root, function(d)
        return store.add_thread(d, {
          file = "lib/core.py", start = line, ["end"] = line,
          anchor = anchor.capture(HEAD, line, line), author = "user", body = "q" .. line,
        })
      end)
    end

    case("shows in the threads the agent is working on, until each is answered", function()
      local a, b = new_thread(5), new_thread(20)
      local later = nil
      progress.start(root, { pane_id = "w1:p1", title = "Reviewer" })
      later = new_thread(30) -- written after the poke: not part of it
      follow("working")
      local function md(id)
        return table.concat(ac.thread_markdown(store.find(store.read(root), id)), "\n")
      end
      assert(md(a):find("Reviewer is replying…", 1, true), md(a))
      assert(md(b):find("Reviewer is replying…", 1, true))
      assert(not md(later):find("replying", 1, true))
      store.update(root, function(d) store.add_message(store.find(d, a), "agent", "done") end)
      assert(not md(a):find("replying", 1, true), md(a)) -- answered
      assert(md(b):find("replying", 1, true))
      follow("blocked")
      assert(not md(b):find("replying", 1, true)) -- waiting for the user, not replying
    end)

    case("shows on inline cards and goes away when following stops", function()
      local id = new_thread(5)
      progress.start(root, { pane_id = "w1:p1", title = "Reviewer" })
      follow("working")
      local t = store.find(store.read(root), id)
      local head = ac.inline_lines(t, 120)[1][1][1]
      assert(head:find("agent replying…", 1, true), head)
      progress.stop()
      head = ac.inline_lines(t, 120)[1][1][1]
      assert(not head:find("replying", 1, true), head)
    end)
  end)

  describe("unified view", function()
    local unified = require("code-review.unified")
    local ns = api.nvim_create_namespace("code-review")
    local function view()
      for _, w in ipairs(api.nvim_tabpage_list_wins(0)) do
        local b = api.nvim_win_get_buf(w)
        if vim.b[b].code_review_unified then
          return w, b
        end
      end
    end
    local function row_where(b, pred)
      for i = 1, api.nvim_buf_line_count(b) do
        local r = unified.at(b, i)
        if r and pred(r) then
          return i, r
        end
      end
    end
    local function feed(keys)
      api.nvim_feedkeys(api.nvim_replace_termcodes(keys, true, false, true), "x", false)
    end

    case("builds rows that hold every old and every new line exactly once", function()
      local rows = unified.rows(BASE, HEAD)
      local kinds, olds, news = {}, {}, {}
      for _, r in ipairs(rows) do
        kinds[r.kind] = (kinds[r.kind] or 0) + 1
        if r.old then olds[#olds + 1] = r.old end
        if r.new then news[#news + 1] = r.new end
      end
      eq({ kinds.del, kinds.add, kinds.ctx }, { 3, 4, 57 })
      eq(#olds, #BASE)
      eq(#news, #HEAD)
      for i = 2, #olds do assert(olds[i] == olds[i - 1] + 1, "old lines in order") end
      for i = 2, #news do assert(news[i] == news[i - 1] + 1, "new lines in order") end
      eq(#unified.rows({}, { "a", "b" }), 2) -- an added file
      eq(unified.rows({ "a" }, {})[1].kind, "del") -- a removed file
    end)

    case("shows one column with line numbers, +/- and the review colors", function()
      ac.config.diff_layout = "unified"
      diff.show_file(root, "lib/core.py")
      local w, b = view()
      assert(w, "unified window expected")
      local panes = vim.tbl_filter(function(x) return vim.wo[x].diff end, api.nvim_tabpage_list_wins(0))
      eq(#panes, 0)
      local del = row_where(b, function(r) return r.kind == "del" and r.old == 5 end)
      local add = row_where(b, function(r) return r.kind == "add" and r.new == 5 end)
      eq(add, del + 1) -- the new line right under the old one
      eq(api.nvim_buf_get_lines(b, del - 1, add, false), { "value_05 = 5", "value_05 = 500" })
      local col = api.nvim_eval_statusline(vim.wo[w].statuscolumn, { winid = w, use_statuscol_lnum = del }).str
      assert(col:find("5", 1, true) and col:find("-", 1, true), col)
      local hl = {}
      for _, m in ipairs(api.nvim_buf_get_extmarks(b, -1, { del - 1, 0 }, { add - 1, -1 }, { details = true })) do
        hl[m[4].line_hl_group or ""] = true
      end
      assert(hl.CodeReviewDiffRemoved and hl.CodeReviewDiffAdded, vim.inspect(hl))
      local bar = api.nvim_eval_statusline(vim.wo[w].winbar, { winid = w, use_winbar = true, maxwidth = 200 }).str
      assert(bar:find("UNIFIED main @BASE313 → feature @HEAD313", 1, true), bar)
      api.nvim_set_current_win(w)
      local r25 = select(1, row_where(b, function(r) return r.new == 25 end))
      assert(vim.fn.foldclosed(r25) > 0, "long unchanged code is folded")
      assert(vim.fn.foldclosed(del - 1) == -1, "context around a change stays open")
    end)

    case("comments on a removed row go to the old side, on an added row to the new side", function()
      ac.config.diff_layout = "unified"
      diff.show_file(root, "lib/core.py")
      local w, b = view()
      api.nvim_set_current_win(w)
      local del = row_where(b, function(r) return r.kind == "del" and r.old == 40 end)
      api.nvim_win_set_cursor(w, { del, 0 })
      ac.add(del, del)
      api.nvim_buf_set_lines(0, 0, -1, false, { "why remove?" })
      feed("<C-s>")
      local add = row_where(b, function(r) return r.kind == "add" and r.new == 41 end)
      ac.add(add, add)
      api.nvim_buf_set_lines(0, 0, -1, false, { "why add?" })
      feed("<C-s>")
      local threads = store.read(root).threads
      eq({ threads[1].side, threads[1].base, threads[1].range.start, threads[1].anchor.text }, { "old", "BASE3131aaaa", 40, { "value_40 = 40" } })
      eq({ threads[2].side, threads[2].range.start, threads[2].anchor.text }, { nil, 41, { "inserted_b = 2" } })
    end)

    case("draws existing threads of both sides at their rows", function()
      store.update(root, function(d)
        store.add_thread(d, { file = "lib/core.py", side = "old", base = "BASE3131aaaa", start = 5, ["end"] = 5,
          anchor = anchor.capture(BASE, 5, 5), author = "user", body = "old one" })
        store.add_thread(d, { file = "lib/core.py", start = 42, ["end"] = 42,
          anchor = anchor.capture(HEAD, 42, 42), author = "user", body = "new one" })
      end)
      ac.config.diff_layout = "unified"
      diff.show_file(root, "lib/core.py")
      local _, b = view()
      local rows = {}
      for _, m in ipairs(api.nvim_buf_get_extmarks(b, ns, 0, -1, { details = true })) do
        if m[4].virt_text then
          rows[#rows + 1] = m[2] + 1
        end
      end
      table.sort(rows)
      eq(rows, {
        (row_where(b, function(r) return r.kind == "del" and r.old == 5 end)),
        (row_where(b, function(r) return r.new == 42 end)),
      })
    end)

    case("]c steps between changes; ]f, viewed and switching back to split all work", function()
      ac.config.diff_layout = "unified"
      diff.show_file(root, "lib/core.py")
      local w, b = view()
      api.nvim_set_current_win(w)
      local first = api.nvim_win_get_cursor(w)[1]
      eq(unified.at(b, first).old, 5) -- opens on the first change
      feed("]c")
      local second = api.nvim_win_get_cursor(w)[1]
      eq(unified.at(b, second).old, 40)
      eq({ diff.where() }, { root, "lib/core.py" })
      diff.toggle_viewed(root) -- marks and moves on to util.py
      local _, b2 = view()
      eq(vim.b[b2].code_review_unified.file, "lib/util.py")
      diff.set_layout(root, "split")
      local panes = vim.tbl_filter(function(x) return vim.wo[x].diff end, api.nvim_tabpage_list_wins(0))
      eq(#panes, 0) -- util.py is an added file: one side only
      diff.show_file(root, "lib/core.py")
      panes = vim.tbl_filter(function(x) return vim.wo[x].diff end, api.nvim_tabpage_list_wins(0))
      eq(#panes, 2)
      for _, p in ipairs(panes) do
        eq(vim.wo[p].statuscolumn, "")
      end
    end)
  end)
end)
