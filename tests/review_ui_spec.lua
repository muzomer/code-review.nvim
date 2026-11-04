-- The review UI: winbar, sidebar, inline threads, help, summary.
-- Own PR fixture (#21) and cleanup after every test, so order does not matter.
local store = require("code-review.store")
local anchor = require("code-review.anchor")
local session = require("code-review.session")
local github = require("code-review.github")
local diff = require("code-review.diff")
local progress = require("code-review.progress")
local ac = require("code-review")

local api = vim.api
require("code-review.diff").pane_width = function() return 200 end -- full winbars (narrow panes are tested apart)
progress.use_timer = false

local routes = {
  ["/pulls/21/files"] = {
    { filename = "src/app/a.py", status = "modified", additions = 1, deletions = 1 },
    { filename = "src/app/b.py", status = "added", additions = 2, deletions = 0 },
    { filename = "docs/readme.md", status = "removed", additions = 0, deletions = 1 },
  },
  ["/pulls/21"] = {
    title = "UI fixture", html_url = "u", state = "open",
    base = { sha = "BASE2121aaaa", ref = "main" }, head = { sha = "HEAD2121bbbb", ref = "feature" },
  },
  ["contents/src/app/a.py?ref=BASE2121aaaa"] = "one\ntwo\nthree\n",
  ["contents/src/app/a.py?ref=HEAD2121bbbb"] = "one\nTWO\nthree\n",
  ["contents/src/app/b.py?ref=HEAD2121bbbb"] = "new\nfile\n",
  ["contents/docs/readme.md?ref=BASE2121aaaa"] = "old docs\n",
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
  progress.stop()
  diff.close()
  for _, w in ipairs(api.nvim_list_wins()) do
    if api.nvim_win_get_config(w).relative ~= "" then
      pcall(api.nvim_win_close, w, true)
    end
  end
  if ac.inline_enabled() then
    ac.toggle_inline()
  end
  if root then
    for _, f in ipairs({ "src/app/a.py", "src/app/b.py", "docs/readme.md" }) do
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
    if file then
      res[side] = w
    end
  end
  return res
end

---The winbar as drawn; `maxwidth` evaluates it as if the pane were that wide.
local function winbar_text(win, maxwidth)
  return api.nvim_eval_statusline(vim.wo[win].winbar, { winid = win, use_winbar = true, maxwidth = maxwidth }).str
end

describe("review UI", function()
  ac.setup({ notify = false })
  fake()
  root = diff.open("acme/ui#21")
  cleanup()

  describe("winbar", function()
    case("keeps the side label when the pane is too narrow for everything", function()
      vim.o.columns = 70
      diff.show_file(root, "src/app/a.py")
      local w = wins_by_side()
      assert(winbar_text(w.new):find("^ NEW"), winbar_text(w.new))
      assert(winbar_text(w.old):find("^ OLD"), winbar_text(w.old))
      vim.o.columns = 80
    end)

    case("labels each side with its branch, commit and place in the PR", function()
      diff.show_file(root, "src/app/a.py")
      local w = wins_by_side()
      local old, new = winbar_text(w.old, 200), winbar_text(w.new, 200)
      assert(old:find("OLD main @BASE212", 1, true), old)
      assert(new:find("NEW feature @HEAD212", 1, true), new)
      assert(new:find("file 2/3", 1, true), new) -- review order is by path: docs/ comes first
      assert(not new:find("viewed", 1, true), new)
    end)

    case("shows when the file is viewed", function()
      diff.show_file(root, "src/app/b.py")
      session.set_viewed(root, "src/app/a.py", true)
      diff.refresh_cache(root)
      diff.show_file(root, "src/app/a.py")
      assert(winbar_text(wins_by_side().new, 200):find("✓ viewed", 1, true))
    end)

    case("goes away when another file is opened in the pane", function()
      diff.show_file(root, "src/app/a.py")
      local w = wins_by_side().new
      api.nvim_set_current_win(w)
      vim.cmd.enew()
      eq(vim.wo[w].winbar, "")
    end)

    case("a single-sided file still says which side it is", function()
      diff.show_file(root, "docs/readme.md") -- removed: only the old side exists
      local w = wins_by_side()
      eq(w.new, nil)
      assert(winbar_text(w.old, 200):find("OLD main", 1, true), winbar_text(w.old, 200))
    end)
  end)

  describe("agent status", function()
    local function status_float()
      for _, w in ipairs(api.nvim_list_wins()) do
        local c = api.nvim_win_get_config(w)
        if c.relative == "editor" and api.nvim_win_get_height(w) == 1 then
          return w
        end
      end
    end

    case("keeps the start of a long branch name in the winbar", function()
      local sess = session.load(root)
      local head = sess.head_ref
      sess.head_ref = "fix-lsp-sync-noop-edit-in-empty-buffer"
      session.save(root, sess)
      diff.show_file(root, "src/app/a.py")
      local new = winbar_text(wins_by_side().new, 200)
      assert(new:find("fix-lsp-sync-noop-edit-…", 1, true), new) -- at most 24 characters
      -- a narrow pane: the start of the branch stays, the function name goes
      local wide = diff.pane_width
      diff.pane_width = function() return 30 end
      local w = wins_by_side().new
      local text = winbar_text(w, 30)
      diff.pane_width = wide
      assert(text:find("NEW fix", 1, true), text)
      assert(vim.fn.strdisplaywidth(text) <= 30 and not text:find("<", 1, true), text)
      sess.head_ref = head
      session.save(root, sess)
    end)

    case("shows in a float during a review, leaving the winbar to the branch and file", function()
      diff.show_file(root, "src/app/a.py")
      progress.start(root, { pane_id = "w1:p1", title = "Reviewer" })
      assert(status_float(), "float expected")
      assert(not winbar_text(wins_by_side().new, 200):find("Reviewer", 1, true))
      eq(ac.status():find("Reviewer", 1, true) ~= nil, true) -- and for lualine
    end)

    case("goes into the NEW pane's winbar instead with progress_float = \"auto\"", function()
      ac.config.progress_float = "auto"
      diff.show_file(root, "src/app/a.py")
      progress.start(root, { pane_id = "w1:p1", title = "Reviewer" })
      local new = winbar_text(wins_by_side().new, 200)
      assert(new:find("Reviewer", 1, true) and new:find("sent", 1, true), new)
      assert(not winbar_text(wins_by_side().old, 200):find("Reviewer", 1, true))
      eq(status_float(), nil)
      ac.config.progress_float = true
    end)

    case("leaves the winbar clean once nothing is followed", function()
      diff.show_file(root, "src/app/a.py")
      progress.start(root, { pane_id = "w1:p1", title = "Reviewer" })
      progress.stop()
      assert(not winbar_text(wins_by_side().new, 200):find("Reviewer", 1, true))
    end)
  end)

  describe("sidebar", function()
    local sidebar = require("code-review.sidebar")
    local function lines()
      local _, buf = sidebar.find_win()
      return api.nvim_buf_get_lines(buf, 0, -1, false)
    end
    local function row_index(text)
      for i, l in ipairs(lines()) do
        if l:find(text, 1, true) then
          return i, l
        end
      end
    end
    local function focus(text)
      local win = sidebar.find_win()
      api.nvim_set_current_win(win)
      api.nvim_win_set_cursor(win, { row_index(text), 0 })
    end
    local function feed(keys)
      api.nvim_feedkeys(api.nvim_replace_termcodes(keys, true, false, true), "x", false)
    end

    case("opens on the left of the diff, as a folder tree, without taking focus", function()
      diff.show_file(root, "src/app/a.py")
      local win = sidebar.find_win()
      assert(win, "sidebar expected")
      eq(api.nvim_win_get_position(win)[2], 0) -- leftmost
      eq(vim.wo[win].winfixwidth, true)
      assert(api.nvim_get_current_win() ~= win)
      local l = lines()
      assert(l[1]:find("acme/ui#21 · 0/3 viewed", 1, true), l[1])
      assert(row_index("▾ docs/") and row_index("▾ src/app/"), vim.inspect(l)) -- src/ + app/ shown as one row
      assert(select(2, row_index("readme.md")):find(" D ", 1, true)) -- removed
      assert(select(2, row_index("b.py")):find(" A ", 1, true)) -- added
    end)

    case("marks the file in the diff and follows it", function()
      diff.show_file(root, "src/app/a.py")
      local i, l = row_index("a.py")
      assert(l:find("▶", 1, true), l)
      assert(not select(2, row_index("b.py")):find("▶", 1, true))
      eq(api.nvim_win_get_cursor((sidebar.find_win()))[1], i)
      diff.step(1) -- next file in review order: b.py
      assert(select(2, row_index("b.py")):find("▶", 1, true))
      assert(not select(2, row_index("a.py")):find("▶", 1, true))
    end)

    case("lines the change counts up in columns", function()
      diff.show_file(root, "src/app/a.py")
      local _, a = row_index("a.py")
      local _, b = row_index("b.py")
      local _, r = row_index("readme.md")
      local function col(line, ch)
        return vim.fn.strdisplaywidth(line:sub(1, line:find(ch, 1, true) - 1))
      end
      eq(col(a, "+"), col(b, "+"))
      eq(col(a, "-"), col(r, "-"))
    end)

    case("fits rows to the sidebar width, shortening long names", function()
      routes["/pulls/21/files"][#routes["/pulls/21/files"] + 1] =
        { filename = "src/app/a_really_long_module_name_that_never_fits.py", status = "added", additions = 7, deletions = 0 }
      routes["contents/src/app/a_really_long_module_name_that_never_fits.py?ref=HEAD2121bbbb"] = "x\n"
      diff.reload(root) -- the PR's file list changed: fetch again
      local win = sidebar.find_win()
      local width = api.nvim_win_get_width(win)
      for _, l in ipairs(lines()) do
        if not l:find("acme/ui#21", 1, true) then -- the header may be cut by the window
          assert(vim.fn.strdisplaywidth(l) <= width, string.format("%d > %d: %s", vim.fn.strdisplaywidth(l), width, l))
        end
      end
      local _, long = row_index("a_really")
      assert(long:find("…", 1, true) and long:find("+7", 1, true), long) -- shortened, counts still visible
      table.remove(routes["/pulls/21/files"])
      diff.reload(root)
    end)

    case("colors rows with extmarks, not window matches", function()
      diff.show_file(root, "src/app/a.py")
      local win, buf = sidebar.find_win()
      eq(#vim.fn.getmatches(win), 0)
      local groups = {}
      for _, m in ipairs(api.nvim_buf_get_extmarks(buf, -1, 0, -1, { details = true })) do
        groups[m[4].hl_group or m[4].line_hl_group or ""] = true
      end
      for _, g in ipairs({ "CodeReviewStatusModified", "CodeReviewStatusAdded", "CodeReviewStatAdd", "CodeReviewStatDel", "CodeReviewQfMarker", "CodeReviewQfCurrent", "Directory" }) do
        assert(groups[g], g .. " missing")
      end
    end)

    case("<CR> opens a file and folds a folder", function()
      diff.show_file(root, "src/app/a.py")
      focus("b.py")
      feed("<CR>")
      assert(api.nvim_buf_get_name(0):find("/head/src/app/b.py", 1, true), api.nvim_buf_get_name(0))
      focus("▾ src/app/")
      feed("<CR>")
      assert(row_index("▸ src/app/") and not row_index("a.py"), vim.inspect(lines()))
      feed("<CR>")
      assert(row_index("a.py"), vim.inspect(lines()))
    end)

    case("counts open threads per file, and flags the ones waiting for you", function()
      diff.show_file(root, "src/app/a.py")
      local id = store.update(root, function(d)
        return store.add_thread(d, {
          file = "src/app/a.py", start = 2, ["end"] = 2,
          anchor = anchor.capture({ "one", "TWO", "three" }, 2, 2), author = "user", body = "why caps?",
        })
      end)
      sidebar.refresh_all()
      local _, l = row_index("a.py")
      assert(l:find("✎1", 1, true) and not l:find("!", 1, true), l)
      store.update(root, function(d) store.add_message(store.find(d, id), "agent", "constant") end)
      sidebar.refresh_all()
      _, l = row_index("a.py")
      assert(l:find("✎1!", 1, true), l)
    end)

    case("stays (same window) when switching files, and leaves a quickfix list open", function()
      diff.show_file(root, "src/app/a.py")
      local win = sidebar.find_win()
      ac.list(false) -- a thread list in the quickfix
      local qf = vim.fn.getqflist({ winid = 0 }).winid
      diff.show_file(root, "src/app/b.py")
      eq(sidebar.find_win(), win)
      eq(api.nvim_win_is_valid(qf), true)
      vim.cmd("cclose")
    end)

    local function layout()
      local win = sidebar.find_win()
      local panes = {}
      for _, w in ipairs(api.nvim_tabpage_list_wins(0)) do
        if vim.wo[w].diff then
          panes[#panes + 1] = w
        end
      end
      return win, panes
    end
    local function box(w)
      local pos = api.nvim_win_get_position(w)
      return { top = pos[1], left = pos[2], bottom = pos[1] + api.nvim_win_get_height(w), right = pos[2] + api.nvim_win_get_width(w) }
    end

    case("can sit at the bottom: full width, fixed height, under both diff panes", function()
      ac.config.sidebar_position = "bottom"
      diff.show_file(root, "src/app/a.py")
      local win, panes = layout()
      eq(#panes, 2)
      local b = box(win)
      for _, p in ipairs(panes) do
        assert(b.top >= box(p).bottom, "file list should be below the diff")
      end
      eq(api.nvim_win_get_width(win), vim.o.columns)
      eq({ vim.wo[win].winfixheight, vim.wo[win].winfixwidth }, { true, false })
      assert(box(panes[1]).top == box(panes[2]).top, "panes stay side by side")
      local _, l = row_index("a.py")
      assert(not l:find("…", 1, true), l) -- room enough: names are not shortened
    end)

    case("can sit at the top or on the right", function()
      ac.config.sidebar_position = "top"
      diff.show_file(root, "src/app/a.py")
      local win, panes = layout()
      for _, p in ipairs(panes) do
        assert(box(win).bottom <= box(p).top, "file list should be above the diff")
      end
      diff.close()
      ac.config.sidebar_position = "right"
      diff.show_file(root, "src/app/a.py")
      win, panes = layout()
      for _, p in ipairs(panes) do
        assert(box(win).left >= box(p).right, "file list should be right of the diff")
      end
      eq(vim.wo[win].winfixwidth, true)
    end)

    case(":CodeReview files bottom moves it while reviewing", function()
      diff.show_file(root, "src/app/a.py")
      local _, panes = layout()
      diff.toggle_sidebar(root, "bottom")
      local win = sidebar.find_win()
      eq(api.nvim_win_get_width(win), vim.o.columns)
      for _, p in ipairs(panes) do
        assert(api.nvim_win_is_valid(p), "the diff panes are kept")
      end
      diff.show_file(root, "src/app/b.py") -- and it stays there
      eq(api.nvim_win_get_width((sidebar.find_win())), vim.o.columns)
    end)

    case("a new diff window never splits the file list", function()
      ac.config.sidebar_position = "bottom"
      diff.show_file(root, "src/app/a.py")
      local win = sidebar.find_win()
      local h = api.nvim_win_get_height(win)
      for _, w in ipairs(api.nvim_tabpage_list_wins(0)) do -- leave only the file list
        if w ~= win then
          pcall(api.nvim_win_close, w, true)
        end
      end
      diff.show_file(root, "src/app/b.py")
      eq(api.nvim_win_get_height((sidebar.find_win())), h)
      eq(api.nvim_win_get_width((sidebar.find_win())), vim.o.columns)
    end)

    case(":CodeReview files hides and shows it, and a hidden sidebar stays hidden", function()
      diff.show_file(root, "src/app/a.py")
      diff.toggle_sidebar(root)
      eq(sidebar.find_win(), nil)
      diff.show_file(root, "src/app/b.py")
      eq(sidebar.find_win(), nil)
      diff.toggle_sidebar(root)
      assert(sidebar.find_win())
    end)
  end)

  describe("inline conversations", function()
    local ns = api.nvim_create_namespace("code-review")
    local ns_mirror = api.nvim_create_namespace("code-review-mirror")

    local function thread(file, line, text, body, reply)
      local id = store.update(root, function(d)
        local lines = vim.fn.readfile(session.snapshot_path(root, file, "new"))
        return store.add_thread(d, {
          file = file, start = line, ["end"] = line,
          anchor = anchor.capture(lines, line, line), author = "user", body = body,
        })
      end)
      if reply then
        store.update(root, function(d) store.add_message(store.find(d, id), "agent", reply) end)
      end
      return id
    end
    local function virt_lines(buf, namespace)
      local res = {}
      for _, m in ipairs(api.nvim_buf_get_extmarks(buf, namespace, 0, -1, { details = true })) do
        if m[4].virt_lines then
          res[#res + 1] = { row = m[2], lines = m[4].virt_lines }
        end
      end
      return res
    end
    local function text_of(vl)
      local out = {}
      for _, chunks in ipairs(vl) do
        local t = ""
        for _, c in ipairs(chunks) do
          t = t .. c[1]
        end
        out[#out + 1] = t
      end
      return out
    end

    case("maps lines across the two sides of a diff", function()
      local text_diff = (vim.text and vim.text.diff) or vim.diff
      local a = "1\n2\n3\n4\n5\n"
      local b = "1\n2\nnew\nnew\n3\n4\n5\n" -- two lines inserted after 2
      local hunks = text_diff(a, b, { result_type = "indices" })
      eq(ac._map_line(hunks, 2, true), 2)
      eq(ac._map_line(hunks, 3, true), 5)
      eq(ac._map_line(hunks, 5, false), 3)
      local c = "1\n3\n4\n5\n" -- line 2 deleted
      hunks = text_diff(a, c, { result_type = "indices" })
      eq(ac._map_line(hunks, 4, true), 3)
      eq(ac._map_line(hunks, 2, true), 1) -- the deleted line lands where it was
    end)

    case("shows the whole conversation under the line instead of a one-line label", function()
      thread("src/app/a.py", 2, "TWO", "why caps?", "it is a constant now")
      diff.show_file(root, "src/app/a.py")
      ac.toggle_inline()
      local nb = api.nvim_win_get_buf(wins_by_side().new)
      local vls = virt_lines(nb, ns)
      eq(#vls, 1)
      eq(vls[1].row, 1) -- under line 2
      local text = table.concat(text_of(vls[1].lines), "\n")
      assert(text:find("needs you", 1, true), text)
      assert(text:find("you: why caps?", 1, true) and text:find("agent: it is a", 1, true) and text:find("constant now", 1, true), text)
      for _, m in ipairs(api.nvim_buf_get_extmarks(nb, ns, 0, -1, { details = true })) do
        eq(m[4].virt_text, nil) -- no end-of-line label while inline
      end
      ac.toggle_inline()
      eq(#virt_lines(nb, ns), 0)
    end)

    case("keeps both diff panes aligned by mirroring blank lines", function()
      thread("src/app/a.py", 2, "TWO", "why caps?", "a constant")
      diff.show_file(root, "src/app/a.py")
      ac.toggle_inline()
      local w = wins_by_side()
      local own = virt_lines(api.nvim_win_get_buf(w.new), ns)[1]
      local mirrored = virt_lines(api.nvim_win_get_buf(w.old), ns_mirror)
      eq(#mirrored, 1)
      eq(#mirrored[1].lines, #own.lines)
      api.nvim_set_current_win(w.old)
      vim.cmd("normal! ggzt")
      vim.cmd("syncbind")
      vim.cmd("redraw!")
      eq(vim.fn.screenpos(w.old, 3, 1).row, vim.fn.screenpos(w.new, 3, 1).row)
    end)

    case("wraps long messages to the pane and cuts very long conversations", function()
      local long = string.rep("word ", 200)
      thread("src/app/a.py", 2, "TWO", long, long)
      diff.show_file(root, "src/app/a.py")
      ac.toggle_inline()
      local win = wins_by_side().new
      local width = api.nvim_win_get_width(win)
      local lines = text_of(virt_lines(api.nvim_win_get_buf(win), ns)[1].lines)
      for _, l in ipairs(lines) do
        assert(vim.fn.strdisplaywidth(l) <= width, l)
      end
      assert(#lines <= ac.config.inline_max_lines + 3, #lines)
      assert(lines[#lines - 1]:find("more in the thread", 1, true), lines[#lines - 1])
    end)

    case("]u and [u go through the threads waiting for you, across files", function()
      thread("src/app/a.py", 2, "TWO", "q1", "answered 1") -- waits for you
      thread("src/app/a.py", 3, "three", "q2") -- waits for the agent: skipped
      thread("src/app/b.py", 1, "new", "q3", "answered 3") -- waits for you
      diff.show_file(root, "src/app/a.py", "new", 1)
      ac.jump_yours(1)
      local function where()
        for _, w in ipairs(api.nvim_tabpage_list_wins(0)) do
          local _, file = session.infer(api.nvim_buf_get_name(api.nvim_win_get_buf(w)))
          if file and api.nvim_win_get_config(w).relative == "" and w == vim.fn.win_getid(vim.fn.winnr("#")) then
            return file, api.nvim_win_get_cursor(w)[1]
          end
        end
      end
      local file, line = where()
      eq({ file, line }, { "src/app/a.py", 2 })
      ac.jump_yours(1)
      file, line = where()
      eq({ file, line }, { "src/app/b.py", 1 })
      local notes, notify = {}, vim.notify
      vim.notify = function(m) notes[#notes + 1] = m end
      ac.jump_yours(1)
      vim.notify = notify
      assert(table.concat(notes):find("no more threads waiting for you", 1, true), vim.inspect(notes))
    end)
  end)

  describe("comment input", function()
    local function input_win()
      for _, w in ipairs(api.nvim_list_wins()) do
        local c = api.nvim_win_get_config(w)
        if c.relative ~= "" and c.title and vim.inspect(c.title):find("Comment on", 1, true) then
          return w, c
        end
      end
    end

    case("opens right under the commented line, so the code stays visible", function()
      diff.show_file(root, "src/app/a.py")
      local src = wins_by_side().new
      api.nvim_set_current_win(src)
      api.nvim_win_set_cursor(src, { 2, 0 })
      vim.cmd("redraw")
      local screen_row = vim.fn.screenpos(src, 2, 1).row -- 1-based
      ac.add(2, 2)
      vim.cmd("redraw")
      local w, c = input_win()
      assert(w, "input window expected")
      assert(c.relative == "cursor" or c.relative == "win", c.relative) -- Neovim reports cursor floats as "win"
      local top = api.nvim_win_get_position(w)[1] -- 0-based screen row of the border
      assert(top + 1 > screen_row, string.format("input at %d covers line at %d", top + 1, screen_row))
      vim.cmd("stopinsert")
      api.nvim_win_close(w, true)
    end)

    case("opens above the line when there is no room below", function()
      local p = tmp_project({})
      local lines = {}
      for i = 1, 200 do
        lines[i] = "line " .. i
      end
      vim.fn.writefile(lines, p .. "/long.txt")
      vim.cmd.edit(p .. "/long.txt")
      vim.cmd("normal! G")
      vim.cmd("redraw")
      local src = api.nvim_get_current_win()
      local screen_row = vim.fn.screenpos(src, 200, 1).row -- 1-based
      ac.add(200, 200)
      vim.cmd("redraw")
      local w = input_win()
      local bottom = api.nvim_win_get_position(w)[1] + api.nvim_win_get_height(w) + 1
      assert(bottom < screen_row, string.format("input ends at %d, line at %d", bottom, screen_row))
      vim.cmd("stopinsert")
      api.nvim_win_close(w, true)
      vim.cmd("bwipeout!")
    end)
  end)

  describe("help", function()
    case("lists the keys of where you are first, then the rest, using your mappings", function()
      local lines = table.concat(ac.help_lines("sidebar"), "\n")
      assert(lines:find("^Sidebar"), lines)
      assert(lines:find("v%s+mark viewed"), lines)
      assert(lines:find("<leader>ca%s+comment on the line"), lines)
      local km = ac.config.keymaps
      local old = km.add
      km.add = "gc"
      assert(table.concat(ac.help_lines(), "\n"):find("gc%s+comment on the line"))
      km.add = false -- unmapped keys are left out
      assert(not table.concat(ac.help_lines(), "\n"):find("comment on the line", 1, true))
      km.add = old
    end)

    case("? in the sidebar and in a thread window opens it; q closes it", function()
      diff.show_file(root, "src/app/a.py")
      local sidebar = require("code-review.sidebar")
      api.nvim_set_current_win((sidebar.find_win()))
      api.nvim_feedkeys("?", "x", false)
      local win = api.nvim_get_current_win()
      eq(api.nvim_win_get_config(win).relative, "editor")
      assert(api.nvim_buf_get_lines(0, 0, 1, false)[1]:find("Sidebar", 1, true))
      api.nvim_feedkeys("q", "x", false)
      eq(api.nvim_win_is_valid(win), false)
    end)
  end)

  describe("end-of-review summary", function()
    local function capture(fn)
      local notes, notify = {}, vim.notify
      vim.notify = function(m) notes[#notes + 1] = m end
      local ok, err = pcall(fn)
      vim.notify = notify
      assert(ok, err)
      return table.concat(notes, "\n")
    end

    case("appears once, when the last file is marked viewed", function()
      diff.show_file(root, "src/app/a.py")
      local id = store.update(root, function(d)
        return store.add_thread(d, {
          file = "src/app/a.py", start = 2, ["end"] = 2,
          anchor = anchor.capture({ "one", "TWO", "three" }, 2, 2), author = "user", body = "q",
        })
      end)
      store.update(root, function(d) store.add_message(store.find(d, id), "agent", "a") end)
      local text = capture(function()
        diff.toggle_viewed(root, "docs/readme.md")
        diff.toggle_viewed(root, "src/app/a.py")
      end)
      assert(not text:find("Review of", 1, true), text) -- one file is still unviewed
      text = capture(function() diff.toggle_viewed(root, "src/app/b.py") end)
      assert(text:find("Review of acme/ui#21: 3/3 files viewed", 1, true), text)
      assert(text:find("1 open thread (1 waits for you)", 1, true), text)
      assert(text:find("]u jumps", 1, true), text)
      text = capture(function() diff.maybe_summary(root) end)
      eq(text, "") -- not twice
      text = capture(function() diff.step(1) end) -- ]f at the end: shown again on purpose
      assert(text:find("Review of", 1, true), text)
    end)

    case("is announced again after a file was reopened and finished", function()
      for _, f in ipairs({ "docs/readme.md", "src/app/a.py", "src/app/b.py" }) do
        session.set_viewed(root, f, true)
      end
      diff.refresh_cache(root)
      capture(function() diff.maybe_summary(root) end)
      diff.toggle_viewed(root, "src/app/b.py") -- unviewed again
      local text = capture(function() diff.toggle_viewed(root, "src/app/b.py") end)
      assert(text:find("Review of", 1, true), text)
    end)
  end)
end)
