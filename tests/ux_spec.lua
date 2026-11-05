-- UX round: flash, grouped notifications, filters, resolved/outdated, suggestions,
-- statusline, code context, mouse, recent reviews, async open, changes since
-- last review, conversation panel. Own PR fixture (#41); cleanup after each test.
local store = require("code-review.store")
local anchor = require("code-review.anchor")
local session = require("code-review.session")
local github = require("code-review.github")
local diff = require("code-review.diff")
local progress = require("code-review.progress")
local sidebar = require("code-review.sidebar")
local ac = require("code-review")

local api = vim.api
require("code-review.diff").pane_width = function() return 200 end -- full winbars (narrow panes are tested apart)
progress.use_timer = false

local LUA_BASE = { "local M = {}", "", "function M.add(a, b)", "  return a + b", "end", "", "function M.sub(a, b)", "  return a - b", "end", "", "return M" }
local LUA_HEAD = { "local M = {}", "", "function M.add(a, b)", "  return a + b + 0", "end", "", "function M.sub(a, b)", "  return a - b", "end", "", "return M" }

local routes = {
  ["/pulls/41/files"] = {
    { filename = "src/calc.lua", status = "modified", additions = 1, deletions = 1 },
    { filename = "src/new.lua", status = "added", additions = 1, deletions = 0 },
    { filename = "docs/notes.md", status = "modified", additions = 1, deletions = 1 },
  },
  ["/pulls/41"] = {
    title = "UX fixture", html_url = "u", state = "open",
    base = { sha = "BASE4141aaaa", ref = "main" }, head = { sha = "HEAD4141bbbb", ref = "feature" },
  },
  ["contents/src/calc.lua?ref=BASE4141aaaa"] = table.concat(LUA_BASE, "\n") .. "\n",
  ["contents/src/calc.lua?ref=HEAD4141bbbb"] = table.concat(LUA_HEAD, "\n") .. "\n",
  ["contents/src/new.lua?ref=HEAD4141bbbb"] = "return 1\n",
  ["contents/docs/notes.md?ref=BASE4141aaaa"] = "old notes\n",
  ["contents/docs/notes.md?ref=HEAD4141bbbb"] = "new notes\n",
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
  ac.config.conversation = "float"
  require("code-review.panel").close()
  ac.flush_notifications()
  ac.config.notify = false
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
    for _, f in ipairs({ "src/calc.lua", "src/new.lua", "docs/notes.md" }) do
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

local function thread(file, line, body, author_reply, side)
  local lines = side == "old" and LUA_BASE or LUA_HEAD
  if file ~= "src/calc.lua" then
    lines = session.lines(root, file, { side = side }) or { "x" }
  end
  local id = store.update(root, function(d)
    return store.add_thread(d, {
      file = file, side = side, base = side == "old" and "BASE4141aaaa" or nil, start = line, ["end"] = line,
      anchor = anchor.capture(lines, line, line), author = "user", body = body,
    })
  end)
  if author_reply then
    store.update(root, function(d) store.add_message(store.find(d, id), "agent", author_reply) end)
  end
  return id
end

describe("UX", function()
  ac.setup({ notify = false })
  fake()
  root = diff.open("acme/ux#41")
  cleanup()

  describe("flash", function()
    local ns_flash = api.nvim_create_namespace("code-review-flash")
    case("highlights where a jump lands, then fades", function()
      thread("src/calc.lua", 4, "why + 0?", "habit")
      diff.show_file(root, "src/calc.lua", "new", 1)
      ac.jump_yours(1)
      local w = wins_by_side().new
      local marks = api.nvim_buf_get_extmarks(api.nvim_win_get_buf(w), ns_flash, 0, -1, { details = true })
      eq(#marks, 1)
      eq(marks[1][2], 3) -- line 4
      eq(marks[1][4].line_hl_group, "CodeReviewFlash")
      vim.wait(ac.config.flash_ms + 300, function()
        return #api.nvim_buf_get_extmarks(api.nvim_win_get_buf(w), ns_flash, 0, -1, {}) == 0
      end)
      eq(#api.nvim_buf_get_extmarks(api.nvim_win_get_buf(w), ns_flash, 0, -1, {}), 0)
    end)
  end)

  describe("grouped notifications", function()
    case("several replies in a row become one notification", function()
      ac.config.notify = true
      local a = thread("src/calc.lua", 4, "q1")
      local b = thread("src/calc.lua", 8, "q2")
      diff.show_file(root, "src/calc.lua") -- the store is watched from here on
      local notes, notify = {}, vim.notify
      vim.notify = function(m) notes[#notes + 1] = m end
      for _, id in ipairs({ a, b }) do
        vim.system({ PLUGIN_ROOT .. "/bin/code-review", "--pr", "acme/ux#41", "reply", id, "done" }, { text = true }):wait()
      end
      vim.wait(800, function() return false end) -- let the file watcher see both writes
      eq(#notes, 0) -- nothing yet: still collecting
      ac.flush_notifications()
      vim.notify = notify
      eq(#notes, 1)
      assert(notes[1]:find("agent replied to 2 threads: calc.lua:4, calc.lua:8", 1, true), notes[1])
    end)

    case("a single reply reads as before", function()
      ac.config.notify = true
      local a = thread("src/calc.lua", 4, "q1")
      diff.show_file(root, "src/calc.lua")
      local notes, notify = {}, vim.notify
      vim.notify = function(m) notes[#notes + 1] = m end
      vim.system({ PLUGIN_ROOT .. "/bin/code-review", "--pr", "acme/ux#41", "reply", a, "only one" }, { text = true }):wait()
      vim.wait(800, function() return false end)
      ac.flush_notifications()
      vim.notify = notify
      eq(notes, { "code-review: agent on src/calc.lua:4: only one" })
    end)

    case("a long reply is cut to one line, so Neovim does not stop at Press ENTER", function()
      local msg = ac.one_line("code-review: agent on a.lua:1: " .. string.rep("long words ", 40))
      assert(vim.fn.strdisplaywidth(msg) <= vim.o.columns - 15, msg)
      eq(vim.fn.strcharpart(msg, vim.fn.strchars(msg) - 1), "…")
      eq(ac.one_line("short"), "short")
    end)
  end)

  describe("file list filters", function()
    local function lines()
      local _, buf = sidebar.find_win()
      return table.concat(api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
    end

    case("f cycles all, unviewed, with threads, waiting for you", function()
      diff.show_file(root, "src/calc.lua")
      session.set_viewed(root, "docs/notes.md", true)
      diff.refresh_cache(root)
      thread("src/calc.lua", 4, "q", "answer") -- waits for you
      thread("src/new.lua", 1, "q2") -- waits for the agent
      local win = sidebar.find_win()
      api.nvim_set_current_win(win)
      local function press()
        api.nvim_feedkeys("f", "x", false)
        return lines()
      end
      local t = press() -- unviewed
      assert(t:find("unviewed: 2", 1, true) and not t:find("notes.md", 1, true) and not t:find("docs/", 1, true), t)
      t = press() -- with threads
      assert(t:find("with threads: 2", 1, true) and t:find("calc.lua", 1, true) and t:find("new.lua", 1, true), t)
      t = press() -- waiting for you
      assert(t:find("waiting for you: 1", 1, true) and t:find("calc.lua", 1, true) and not t:find("new.lua", 1, true), t)
      t = press() -- back to all
      assert(not t:find("waiting for you", 1, true) and t:find("notes.md", 1, true), t)
      sidebar.set_filter(root, "all")
    end)

    case("says so when nothing matches", function()
      diff.show_file(root, "src/calc.lua")
      sidebar.set_filter(root, "yours")
      assert(lines():find("no files match", 1, true), lines())
      sidebar.set_filter(root, "all")
    end)
  end)

  describe("resolved and outdated threads", function()
    local ns = api.nvim_create_namespace("code-review")
    local function label_chunks(buf)
      local res = {}
      for _, m in ipairs(api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })) do
        if m[4].virt_text then
          res[#res + 1] = m[4].virt_text
        end
      end
      return res
    end
    local function text(chunks)
      return table.concat(vim.tbl_map(function(c) return c[1] end, chunks))
    end

    case("a resolved thread shows as a small chip when resolved threads are shown", function()
      ac.config.show_resolved = true
      local id = thread("src/calc.lua", 4, "fine?", "yes")
      store.update(root, function(d) store.find(d, id).status = "resolved" end)
      diff.show_file(root, "src/calc.lua")
      local chunks = label_chunks(api.nvim_win_get_buf(wins_by_side().new))
      eq(#chunks, 1)
      local t = text(chunks[1])
      assert(t:find("resolved · 2 messages", 1, true) and not t:find("yes", 1, true), t)
      ac.config.show_resolved = false
    end)

    case("an outdated thread shows the code it was about, struck through", function()
      store.update(root, function(d)
        store.add_thread(d, {
          file = "src/calc.lua", start = 4, ["end"] = 4,
          anchor = anchor.capture({ "", "", "", "  error(\"no such thing anywhere\")" }, 4, 4), author = "user", body = "really?",
        })
      end)
      diff.show_file(root, "src/calc.lua")
      local buf = api.nvim_win_get_buf(wins_by_side().new)
      ac.render(buf, true) -- re-anchor: that code is gone
      local chunks = label_chunks(buf)[1]
      assert(text(chunks):find('outdated · error("no such thing anywhere")', 1, true), text(chunks))
      local struck
      for _, c in ipairs(chunks) do
        struck = struck or (c[2] == "CodeReviewOutdated" and c[1] == 'error("no such thing anywhere")')
      end
      assert(struck, vim.inspect(chunks))
      eq(api.nvim_get_hl(0, { name = "CodeReviewOutdated" }).strikethrough, true)
    end)
  end)

  describe("suggestions", function()
    case("a suggestion block shows as a diff against the commented code", function()
      local id = thread("src/calc.lua", 4, "why + 0?", "Drop it:\n```suggestion\n  return a + b\n```\nThat is all.")
      local md = table.concat(ac.thread_markdown(store.find(store.read(root), id)), "\n")
      assert(md:find("```diff\n-   return a + b + 0\n+   return a + b\n```\nThat is all.", 1, true), md)
    end)

    case("other code blocks and an unclosed suggestion stay as written", function()
      eq(ac.expand_suggestions("```lua\nlocal x = 1\n```", { "y" }), "```lua\nlocal x = 1\n```")
      eq(ac.expand_suggestions("```suggestion\nnew", { "old" }), "```suggestion\nnew")
      eq(ac.expand_suggestions("````suggestion\na\n```\nb\n````", { "o" }), "````diff\n- o\n+ a\n+ ```\n+ b\n````")
    end)
  end)

  describe("statusline component", function()
    case("shows the PR, how far you are and what waits for you; empty elsewhere", function()
      diff.show_file(root, "src/calc.lua")
      api.nvim_set_current_win(wins_by_side().new)
      eq(ac.lualine(), "acme/ux#41 · 0/3 viewed")
      thread("src/calc.lua", 4, "q", "a")
      session.set_viewed(root, "docs/notes.md", true)
      diff.refresh_cache(root)
      eq(ac.lualine(), "acme/ux#41 · 1/3 viewed · 1 waiting for you")
      vim.cmd.enew()
      eq(ac.lualine(), "")
    end)

    case("does not read the store again while nothing changed", function()
      diff.show_file(root, "src/calc.lua")
      api.nvim_set_current_win(wins_by_side().new)
      ac.lualine()
      local reads, read = 0, store.read
      store.read = function(...) reads = reads + 1 return read(...) end
      for _ = 1, 20 do
        ac.lualine()
      end
      store.read = read
      eq(reads, 0)
    end)
  end)

  describe("code location", function()
    local function bar(w)
      return api.nvim_eval_statusline(vim.wo[w].winbar, { winid = w, use_winbar = true, maxwidth = 300 }).str
    end

    case("the winbar names the function around the cursor", function()
      diff.show_file(root, "src/calc.lua", "new", 4)
      local w = wins_by_side().new
      eq(diff.context(w), "M.add")
      assert(bar(w):find("M.add", 1, true), bar(w))
      api.nvim_win_set_cursor(w, { 8, 0 })
      eq(diff.context(w), "M.sub")
      api.nvim_win_set_cursor(w, { 11, 0 })
      eq(diff.context(w), "") -- outside any function
    end)

    case("shows nothing for a file type without a parser", function()
      diff.show_file(root, "docs/notes.md")
      local w = wins_by_side().new
      local ok = pcall(diff.context, w)
      eq(ok, true)
    end)

    case("works in the unified view too", function()
      ac.config.diff_layout = "unified"
      diff.show_file(root, "src/calc.lua", "new", 4)
      local w = api.nvim_get_current_win()
      eq(diff.context(w), "M.add")
    end)
  end)

  describe("comments on selected text", function()
    case("in the unified view: stored on the new side, highlighted on its row", function()
      ac.config.diff_layout = "unified"
      diff.show_file(root, "src/calc.lua", "new", 4)
      local buf = api.nvim_get_current_buf()
      local row = require("code-review.unified").row_of(buf, "new", 4) -- "  return a + b + 0", an added row
      ac.add(row, row, { 16, 18 }) -- "+ 0"
      api.nvim_buf_set_lines(0, 0, -1, false, { "why + 0?" })
      api.nvim_feedkeys(api.nvim_replace_termcodes("<C-s>", true, false, true), "x", false)
      local t = store.read(root).threads[1]
      eq({ t.side, t.range, t.anchor.span }, { nil, { start = 4, ["end"] = 4, start_col = 16, end_col = 18 }, "+ 0" })
      ac.render(buf)
      local spans = vim.tbl_filter(function(m) return m[4].hl_group == "CodeReviewSpan" end,
        api.nvim_buf_get_extmarks(buf, api.nvim_create_namespace("code-review"), 0, -1, { details = true }))
      eq(#spans, 1)
      eq({ spans[1][2], spans[1][3], spans[1][4].end_col }, { row - 1, 15, 18 })
    end)
  end)

  describe("mouse", function()
    case("a click in the gutter of a commented line hits its thread; text clicks do not", function()
      local id = thread("src/calc.lua", 4, "why + 0?")
      diff.show_file(root, "src/calc.lua")
      local w = wins_by_side().new
      vim.cmd("redraw")
      local textoff = vim.fn.getwininfo(w)[1].textoff
      assert(textoff > 0, "a gutter is needed for signs")
      local r, tid = ac.mouse_thread({ winid = w, wincol = 1, line = 4 })
      eq({ r, tid }, { root, id })
      eq(select(2, ac.mouse_thread({ winid = w, wincol = textoff + 3, line = 4 })), nil) -- in the text
      eq(select(2, ac.mouse_thread({ winid = w, wincol = 1, line = 2 })), nil) -- no thread there
      eq(vim.fn.maparg("<LeftMouse>", "n", false, true).buffer, 1) -- installed on the buffer only
    end)

    case("the file list opens the clicked row", function()
      diff.show_file(root, "src/calc.lua")
      local _, buf = sidebar.find_win()
      local m = api.nvim_buf_call(buf, function() return vim.fn.maparg("<LeftRelease>", "n", false, true) end)
      eq(m.buffer, 1)
    end)
  end)

  describe("recent reviews", function()
    case("lists the reviews on this machine with their progress", function()
      thread("src/calc.lua", 4, "q", "a")
      session.set_viewed(root, "docs/notes.md", true)
      local list = session.reviews()
      local mine
      for _, r in ipairs(list) do
        if r.root == root then
          mine = r
        end
      end
      assert(mine, "this review should be listed")
      local line = diff.review_line(mine)
      assert(line:find("acme/ux#41 · UX fixture · 1/3 viewed · 1 waiting for you", 1, true), line)
      eq(list[1].root, root) -- just touched: first
    end)

    case("resumes from the snapshots, offline, at the first file not viewed", function()
      session.set_viewed(root, "docs/notes.md", true) -- the first file in review order
      github.run = function() error("no network expected") end
      local select = vim.ui.select
      vim.ui.select = function(items, _, cb)
        for _, r in ipairs(items) do
          if r.root == root then
            return cb(r)
          end
        end
      end
      diff.recent()
      vim.ui.select = select
      local w = wins_by_side().new
      assert(w and api.nvim_buf_get_name(api.nvim_win_get_buf(w)):find("/head/src/calc.lua", 1, true))
    end)
  end)

  describe("opening without blocking", function()
    case("the review opens as soon as the file list arrives, files fill in after", function()
      -- PR #42: the same files, never opened before
      for k, v in pairs(vim.deepcopy(routes)) do
        if k:find("/pulls/41", 1, true) or k:find("4141", 1, true) then
          local k2 = k:gsub("/pulls/41", "/pulls/42"):gsub("4141", "4242")
          routes[k2] = type(v) == "table" and vim.deepcopy(v) or v
        end
      end
      routes["/pulls/42"].base.sha, routes["/pulls/42"].head.sha = "BASE4242aaaa", "HEAD4242bbbb"
      local queue, run_async = {}, github.run_async
      github.run_async = function(args, cb)
        queue[#queue + 1] = function() cb(github.run(args)) end
      end
      local function step()
        table.remove(queue, 1)()
      end
      local r = diff.open("acme/ux#42")
      eq(#queue, 1) -- asked for the PR, nothing shown yet, Neovim not blocked
      step() -- the PR
      step() -- its file list: the review opens now
      local win, buf = sidebar.find_win()
      assert(win, "the file list is open before any file arrived")
      local text = table.concat(api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
      assert(text:find("…", 1, true), text) -- files still coming
      local shown = table.concat(api.nvim_buf_get_lines(api.nvim_get_current_buf(), 0, -1, false), "\n")
      assert(shown:find("loading docs/notes.md", 1, true), shown)
      while #queue > 0 do
        step()
      end
      github.run_async = run_async
      local panes = vim.tbl_filter(function(w) return vim.wo[w].diff end, api.nvim_tabpage_list_wins(0))
      eq(#panes, 2) -- the placeholder became the real diff
      text = table.concat(api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
      assert(not text:find("…", 1, true), text)
      eq(diff.complete(r), true)
    end)

    case("a file that arrives while you are in another tab waits for you to come back", function()
      for k, v in pairs(vim.deepcopy(routes)) do
        if k:find("/pulls/41", 1, true) or k:find("4141", 1, true) then
          local k2 = k:gsub("/pulls/41", "/pulls/43"):gsub("4141", "4343")
          routes[k2] = type(v) == "table" and vim.deepcopy(v) or v
        end
      end
      routes["/pulls/43"].base.sha, routes["/pulls/43"].head.sha = "BASE4343aaaa", "HEAD4343bbbb"
      local queue, run_async = {}, github.run_async
      github.run_async = function(args, cb)
        queue[#queue + 1] = function() cb(github.run(args)) end
      end
      diff.open("acme/ux#43")
      table.remove(queue, 1)() -- the PR
      table.remove(queue, 1)() -- its file list: the review opens with a placeholder
      local review = api.nvim_get_current_tabpage()
      vim.cmd.tabnew()
      local mine = api.nvim_get_current_tabpage()
      while #queue > 0 do
        table.remove(queue, 1)()
      end
      github.run_async = run_async
      eq(api.nvim_get_current_tabpage(), mine) -- not pulled back to the review
      api.nvim_set_current_tabpage(review)
      vim.api.nvim_exec_autocmds("TabEnter", {})
      vim.wait(200, function() return #vim.tbl_filter(function(w) return vim.wo[w].diff end, api.nvim_tabpage_list_wins(0)) == 2 end)
      local panes = vim.tbl_filter(function(w) return vim.wo[w].diff end, api.nvim_tabpage_list_wins(0))
      eq(#panes, 2) -- the placeholder became the real diff once you came back
      vim.cmd("tabclose " .. api.nvim_tabpage_get_number(mine))
    end)

    case("a PR reviewed before opens from its snapshots straight away", function()
      local calls, run = 0, github.run
      github.run = function(args)
        calls = calls + 1
        return run(args)
      end
      diff.open("acme/ux#41")
      github.run = run
      assert(wins_by_side().new, "shown at once")
      eq(calls, 1) -- only the background check for new commits
    end)
  end)

  describe("changes since your last review", function()
    local NEWER = vim.deepcopy(LUA_HEAD)
    NEWER[8] = "  return a - b - 0"

    case("a new commit shows a banner; reloading keeps your last version to compare", function()
      diff.show_file(root, "src/calc.lua")
      routes["/pulls/41"].head.sha = "HEAD4141cccc"
      routes["contents/src/calc.lua?ref=HEAD4141cccc"] = table.concat(NEWER, "\n") .. "\n"
      routes["contents/src/new.lua?ref=HEAD4141cccc"] = "return 1\n"
      routes["contents/docs/notes.md?ref=HEAD4141cccc"] = "new notes\n"
      diff.check_updates(root, true)
      local _, buf = sidebar.find_win()
      local text = table.concat(api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
      assert(text:find("PR updated · U to reload", 1, true), text)
      diff.reload(root)
      text = table.concat(api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
      assert(not text:find("PR updated", 1, true), text)
      assert(text:find("1 file changed since your last review", 1, true), text)
      eq(diff.since(root), { ["src/calc.lua"] = true })
      eq(session.lines(root, "src/calc.lua")[8], "  return a - b - 0") -- now at the new commit
      sidebar.set_filter(root, "since")
      text = table.concat(api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
      assert(text:find("calc.lua", 1, true) and not text:find("new.lua", 1, true), text)
      sidebar.set_filter(root, "all")
    end)

    case("the since view diffs your last version against now; comments go on current code only", function()
      diff.show_file(root, "src/calc.lua")
      diff.toggle_since(root)
      local w = api.nvim_get_current_win()
      local b = api.nvim_win_get_buf(w)
      local u = require("code-review.unified")
      eq(u.is_since(b), true)
      local bar = api.nvim_eval_statusline(vim.wo[w].winbar, { winid = w, use_winbar = true, maxwidth = 300 }).str
      assert(bar:find("SINCE YOUR LAST REVIEW @HEAD414 → feature @HEAD414", 1, true), bar)
      local del, add
      for i = 1, api.nvim_buf_line_count(b) do
        local r = u.at(b, i)
        if r.kind == "del" then del = del or i end
        if r.kind == "add" then add = add or i end
      end
      eq(api.nvim_buf_get_lines(b, del - 1, add, false), { "  return a - b", "  return a - b - 0" })
      local notes, notify = {}, vim.notify
      vim.notify = function(m) notes[#notes + 1] = m end
      ac.add(del, del)
      vim.notify = notify
      assert(table.concat(notes):find("only existed in your last review", 1, true), vim.inspect(notes))
      ac.add(add, add)
      api.nvim_buf_set_lines(0, 0, -1, false, { "why - 0?" })
      api.nvim_feedkeys(api.nvim_replace_termcodes("<C-s>", true, false, true), "x", false)
      local t = store.read(root).threads[1]
      eq({ t.side, t.range.start, t.anchor.text }, { nil, 8, { "  return a - b - 0" } })
      diff.toggle_since(root) -- back to the PR diff
      eq(u.is_since(api.nvim_get_current_buf()), false)
    end)
  end)

  describe("conversation panel", function()
    local panel = require("code-review.panel")
    local function panel_wins()
      local res = {}
      for _, w in ipairs(api.nvim_tabpage_list_wins(0)) do
        local b = api.nvim_win_get_buf(w)
        if vim.b[b].code_review_panel then
          res[api.nvim_buf_get_name(b):match("[^/]+$")] = w
        end
      end
      return res
    end
    local function feed(keys)
      api.nvim_feedkeys(api.nvim_replace_termcodes(keys, true, false, true), "x", false)
    end
    local function conv_text()
      return table.concat(api.nvim_buf_get_lines(api.nvim_win_get_buf(panel_wins().conversation), 0, -1, false), "\n")
    end

    case("threads open in a docked panel instead of a float when chosen", function()
      ac.config.conversation = "panel"
      local id = thread("src/calc.lua", 4, "why + 0?", "habit")
      diff.show_file(root, "src/calc.lua")
      local before = api.nvim_get_current_win()
      ac.open_thread(root, id)
      local w = panel_wins()
      assert(w.conversation and w.reply, vim.inspect(w))
      eq(api.nvim_get_current_win(), before) -- the focus stays in the code
      for _, x in ipairs(api.nvim_list_wins()) do
        eq(api.nvim_win_get_config(x).relative, "") -- no float
      end
      assert(conv_text():find("why + 0?", 1, true) and conv_text():find("habit", 1, true), conv_text())
    end)

    case("<CR> in the input makes a new line; <C-s> sends the reply", function()
      ac.config.conversation = "panel"
      local id = thread("src/calc.lua", 4, "why + 0?", "habit")
      ac.open_thread(root, id)
      api.nvim_set_current_win(panel_wins().reply)
      feed("ifirst line<CR>second line<C-s>")
      vim.cmd("stopinsert")
      local t = store.find(store.read(root), id)
      eq(t.messages[3].body, "first line\nsecond line")
      eq(api.nvim_buf_get_lines(api.nvim_win_get_buf(panel_wins().reply), 0, -1, false), { "" })
      assert(conv_text():find("second line", 1, true), conv_text())
    end)

    case("<M-s> sends and pokes the agent", function()
      ac.config.conversation = "panel"
      local id = thread("src/calc.lua", 4, "q", "a")
      ac.open_thread(root, id)
      local poked, poke = 0, ac.poke
      ac.poke = function() poked = poked + 1 end
      api.nvim_set_current_win(panel_wins().reply)
      feed("iplease check<M-s>")
      vim.cmd("stopinsert")
      ac.poke = poke
      eq(poked, 1)
      eq(store.find(store.read(root), id).messages[3].body, "please check")
    end)

    case("e edits your last message until the agent answers", function()
      ac.config.conversation = "panel"
      local id = thread("src/calc.lua", 4, "tpyo")
      ac.open_thread(root, id)
      api.nvim_set_current_win(panel_wins().conversation)
      feed("e")
      eq(api.nvim_buf_get_lines(api.nvim_win_get_buf(panel_wins().reply), 0, -1, false), { "tpyo" })
      api.nvim_buf_set_lines(api.nvim_win_get_buf(panel_wins().reply), 0, -1, false, { "typo" })
      feed("<C-s>")
      vim.cmd("stopinsert")
      local t = store.find(store.read(root), id)
      eq({ #t.messages, t.messages[1].body }, { 1, "typo" })
      assert(t.messages[1].edited)
    end)

    case("stays open while you move between files, and can be switched from the float", function()
      local id = thread("src/calc.lua", 4, "q")
      diff.show_file(root, "src/calc.lua")
      ac.open_thread(root, id) -- a float first
      ac.toggle_conversation() -- → panel, with that thread
      local w = panel_wins()
      assert(w.conversation, "panel expected")
      diff.show_file(root, "src/new.lua")
      eq(api.nvim_win_is_valid(w.conversation) and api.nvim_win_is_valid(w.reply), true)
      eq(api.nvim_win_get_width(w.conversation), panel.width())
    end)
  end)
end)
