local store = require("code-review.store")
local anchor = require("code-review.anchor")
local ac = require("code-review")

local api = vim.api
local ns = api.nvim_create_namespace("code-review")

local function main_marks(buf)
  return vim.tbl_filter(function(m)
    return m[4].virt_text ~= nil
  end, api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true }))
end

describe("ui", function()
  ac.setup({ notify = false })
  local lines = { "one", "two", "three", "four" }
  local root = tmp_project({ ["f.lua"] = lines })
  local id = store.update(root, function(d)
    return store.add_thread(d, {
      file = "f.lua", start = 2, ["end"] = 3,
      anchor = anchor.capture(lines, 2, 3), author = "user", body = "first line\nsecond",
    })
  end)

  vim.cmd.edit(root .. "/f.lua")
  local buf = api.nvim_get_current_buf()

  it("renders a sign and virtual text on the commented range", function()
    local m = main_marks(buf)
    eq(#m, 1)
    eq({ m[1][2], m[1][4].end_row }, { 1, 2 })
    eq(m[1][4].virt_text[1][1], "  ▍ user: first line")
  end)

  it("finds the thread under the cursor", function()
    api.nvim_win_set_cursor(0, { 3, 0 })
    eq({ ac.thread_at_cursor() }, { root, id })
    api.nvim_win_set_cursor(0, { 4, 0 })
    eq(ac.thread_at_cursor(), nil)
  end)

  it("persists moved ranges on save", function()
    api.nvim_buf_set_lines(buf, 0, 0, false, { "new 1", "new 2" })
    vim.cmd.write()
    local t = store.find(store.read(root), id)
    eq(t.range, { start = 4, ["end"] = 5 })
    eq(t.anchor.text, { "two", "three" })
  end)

  it("marks the thread outdated when its code is deleted and saved", function()
    api.nvim_buf_set_lines(buf, 3, 5, false, {})
    vim.cmd.write()
    eq(store.find(store.read(root), id).status, "outdated")
  end)

  it("re-renders when the agent replies through the store", function()
    vim.fn.writefile({ "one", "two", "three", "four" }, root .. "/f.lua")
    vim.cmd("edit!")
    eq(store.find(store.read(root), id).status, "open")
    store.update(root, function(d)
      store.add_message(store.find(d, id), "claude", "agent says hi")
    end)
    vim.wait(2000, function()
      local m = main_marks(buf)[1]
      return m and m[4].virt_text[1][1]:find("agent says hi", 1, true) ~= nil
    end)
    local m = main_marks(buf)[1]
    eq(m[4].virt_text[1][1], "  ▍ claude: agent says hi  (2)")
    eq(m[4].virt_text[1][2], "CodeReviewNeedsUser")
  end)

  it("opens the thread float with all messages", function()
    api.nvim_win_set_cursor(0, { 2, 0 })
    ac.command({ fargs = { "open" }, line1 = 2, line2 = 2 })
    local text = table.concat(api.nvim_buf_get_lines(0, 0, -1, false), "\n")
    assert(text:find("first line", 1, true) and text:find("agent says hi", 1, true), text)
    eq(vim.bo.filetype, "markdown")
    api.nvim_win_close(0, true)
  end)

  it("renders threads as valid markdown", function()
    local t = {
      file = "src/a.lua", range = { start = 3, ["end"] = 4 }, status = "open", needs = "user",
      anchor = { text = { "local s = '```'", "return s" } },
      messages = {
        { author = "user", ts = "T1", body = "why?" },
        { author = "claude", ts = "T2", body = "Because:\n```lua\nlocal x = 1" }, -- unclosed fence
      },
    }
    eq(ac.thread_markdown(t), {
      "`src/a.lua:3-4` · open · needs user",
      "",
      "````lua",
      "local s = '```'",
      "return s",
      "````",
      "",
      "**you** · T1",
      "",
      "why?",
      "",
      "---",
      "",
      "**claude** (agent) · T2",
      "",
      "Because:",
      "```lua",
      "local x = 1",
      "```",
    })
  end)

  it("toggles resolved and hides resolved threads", function()
    ac.toggle_resolved(root, id)
    eq(store.find(store.read(root), id).status, "resolved")
    eq(#main_marks(buf), 0)
    ac.toggle_resolved(root, id)
    eq(#main_marks(buf), 1)
  end)

  it("adds a thread through the input float", function()
    api.nvim_set_current_buf(buf)
    ac.add(4, 4)
    api.nvim_buf_set_lines(0, 0, -1, false, { "please fix", "this" })
    api.nvim_feedkeys(api.nvim_replace_termcodes("<C-s>", true, false, true), "x", false)
    local data = store.read(root)
    local t = data.threads[#data.threads]
    eq({ #data.threads, t.range, t.messages[1].body, t.anchor.text }, { 2, { start = 4, ["end"] = 4 }, "please fix\nthis", { "four" } })
    eq(api.nvim_get_current_buf(), buf)
    store.update(root, function(d) table.remove(d.threads) end)
  end)

  it("submits with <CR> in normal mode and keeps a draft on <Esc>", function()
    api.nvim_set_current_buf(buf)
    ac.add(4, 4)
    vim.cmd.stopinsert()
    api.nvim_buf_set_lines(0, 0, -1, false, { "draft" })
    api.nvim_feedkeys(api.nvim_replace_termcodes("<Esc>", true, false, true), "x", false)
    eq(api.nvim_buf_get_lines(0, 0, -1, false), { "draft" }) -- still open
    api.nvim_feedkeys(api.nvim_replace_termcodes("<CR>", true, false, true), "x", false)
    local data = store.read(root)
    eq(data.threads[#data.threads].messages[1].body, "draft")
    eq(api.nvim_get_current_buf(), buf)
    store.update(root, function(d) table.remove(d.threads) end)
  end)

  it("keeps live positions of unsaved edits across agent-triggered re-renders", function()
    vim.wait(300) -- let watcher events from earlier tests settle
    api.nvim_set_current_buf(buf)
    api.nvim_buf_set_lines(buf, 0, 0, false, { "x1", "x2", "x3" }) -- unsaved
    store.update(root, function(d)
      store.add_message(store.find(d, id), "claude", "re-render please")
    end)
    vim.wait(2000, function()
      local m = main_marks(buf)[1]
      return m and m[4].virt_text[1][1]:find("re-render please", 1, true) ~= nil
    end)
    eq(main_marks(buf)[1][2], 4) -- mark stayed on the moved code (0-based)
    ac.render(buf) -- e.g. BufEnter
    eq(main_marks(buf)[1][2], 4)
    vim.cmd.write()
    local t = store.find(store.read(root), id)
    eq({ t.range, t.anchor.text }, { { start = 5, ["end"] = 6 }, { "two", "three" } })
  end)

  it("fills the quickfix list", function()
    ac.list()
    local qf = vim.fn.getqflist()
    eq(#qf, 1)
    eq(qf[1].lnum, 5)
  end)

  it("jumps between threads with wrap-around and counts", function()
    vim.cmd("cclose")
    api.nvim_set_current_buf(buf)
    local lines_now = api.nvim_buf_get_lines(buf, 0, -1, false)
    local ids = {}
    for _, l in ipairs({ 7, 2 }) do
      ids[#ids + 1] = store.update(root, function(d)
        return store.add_thread(d, {
          file = "f.lua", start = l, ["end"] = l,
          anchor = anchor.capture(lines_now, l, l), author = "user", body = "c" .. l,
        })
      end)
    end
    ac.render(buf)
    local function at() return api.nvim_win_get_cursor(0)[1] end
    api.nvim_win_set_cursor(0, { 1, 0 })
    ac.jump(1); eq(at(), 2)
    ac.jump(1); eq(at(), 5)
    ac.jump(1); eq(at(), 7)
    ac.jump(1); eq(at(), 2) -- wraps
    ac.jump(-1); eq(at(), 7) -- wraps backwards
    api.nvim_win_set_cursor(0, { 1, 0 })
    ac.jump(1, 2); eq(at(), 5)
    -- resolved threads are hidden, so they are skipped
    store.update(root, function(d) store.find(d, ids[1]).status = "resolved" end)
    ac.render(buf)
    ac.jump(1); eq(at(), 2)
  end)

  it("lists project threads sorted, optionally with resolved ones", function()
    ac.list() -- the thread on line 5 has the agent's reply, so it waits for you and comes first
    eq(vim.tbl_map(function(i) return i.lnum end, vim.fn.getqflist()), { 5, 2 })
    ac.list(true)
    eq(vim.tbl_map(function(i) return i.lnum end, vim.fn.getqflist()), { 5, 2, 7 })
    vim.cmd("cclose")
  end)
end)

describe("thread list: whose turn", function()
  ac.setup({ notify = false })
  local root = tmp_project({ ["a.lua"] = { "1", "2", "3", "4" }, ["b.lua"] = { "1", "2" } })
  local function add(file, line, author, reply, status)
    store.update(root, function(d)
      local id = store.add_thread(d, {
        file = file, start = line, ["end"] = line, anchor = { text = { tostring(line) } }, author = "user", body = "q" .. line,
      })
      local t = store.find(d, id)
      if reply then
        store.add_message(t, "agent", reply)
      end
      t.status = status or t.status
    end)
  end
  add("a.lua", 1, "user")                   -- waiting for agent
  add("b.lua", 2, "user", "answered")      -- waiting for you
  add("a.lua", 3, "user", "done", "resolved")
  add("a.lua", 4, "user", "see this")      -- waiting for you

  it("puts threads waiting for you first, labels and types them", function()
    vim.cmd.edit(root .. "/a.lua")
    ac.list()
    local qf = vim.fn.getqflist()
    eq(vim.tbl_map(function(i) return { vim.fn.fnamemodify(vim.fn.bufname(i.bufnr), ":t"), i.lnum, i.type } end, qf),
      { { "a.lua", 4, "W" }, { "b.lua", 2, "W" }, { "a.lua", 1, "I" } })
    eq(qf[1].text, "● waiting for you · agent: see this")
    eq(qf[3].text, "○ waiting for agent · you: q1")
    eq(vim.fn.getqflist({ title = 1 }).title, "Code review · 2 waiting for you · 1 waiting for agent")
    -- columns line up whatever the file names and labels are
    local shown = api.nvim_buf_get_lines(vim.fn.getqflist({ qfbufnr = 1 }).qfbufnr, 0, -1, false)
    eq(shown, {
      "a.lua:4  ● waiting for you    agent: see this",
      "b.lua:2  ● waiting for you    agent: answered",
      "a.lua:1  ○ waiting for agent  you: q1",
    })
    local groups = vim.tbl_map(function(m) return m.group end, vim.fn.getmatches())
    assert(vim.tbl_contains(groups, "CodeReviewNeedsUser") and vim.tbl_contains(groups, "CodeReviewNeedsAgent"), vim.inspect(groups))
    vim.cmd("cclose")
  end)

  it("<CR> on a thread jumps to its line and opens the conversation", function()
    vim.cmd.edit(root .. "/a.lua")
    ac.list()
    api.nvim_win_set_cursor(0, { 2, 0 }) -- b.lua:2
    vim.cmd("normal \r")
    assert(api.nvim_win_get_config(0).relative ~= "", "thread float has focus")
    assert(table.concat(api.nvim_buf_get_lines(0, 0, -1, false), "\n"):find("answered", 1, true))
    vim.cmd("close")
    eq(vim.fn.fnamemodify(api.nvim_buf_get_name(0), ":t"), "b.lua")
    eq(api.nvim_win_get_cursor(0)[1], 2)
    vim.cmd("cclose")
  end)

  it("toggles the thread list, and q closes it", function()
    vim.cmd.edit(root .. "/a.lua")
    local function qf_open()
      return vim.fn.getqflist({ winid = 0 }).winid ~= 0
    end
    ac.toggle_list(false)
    assert(qf_open(), "opened")
    ac.toggle_list(true) -- another mode replaces it
    assert(qf_open(), "still open")
    eq(vim.fn.getqflist({ context = 1 }).context.code_review_mode, true)
    ac.toggle_list(true)
    assert(not qf_open(), "closed")
    ac.toggle_list(false)
    vim.cmd("wincmd b")
    eq(vim.bo.filetype, "qf")
    vim.cmd("normal q")
    assert(not qf_open(), "q closed it")
    -- any other list: q is left alone (macro recording)
    vim.fn.setqflist({ { filename = root .. "/a.lua", lnum = 1, text = "x" } }, " ")
    vim.cmd.copen()
    api.nvim_feedkeys("qa", "x", false)
    eq(vim.fn.reg_recording(), "a")
    api.nvim_feedkeys("q", "x", false)
    assert(qf_open(), "other list stays open")
    vim.cmd("cclose")
  end)

  it("lists only what waits for you with yours, resolved last with all", function()
    vim.cmd.edit(root .. "/a.lua")
    ac.list("yours")
    eq(vim.tbl_map(function(i) return i.lnum end, vim.fn.getqflist()), { 4, 2 })
    ac.list("all")
    local qf = vim.fn.getqflist()
    eq(qf[#qf].lnum, 3)
    eq(qf[#qf].text:sub(1, #"✓ resolved"), "✓ resolved")
    vim.cmd("cclose")
    vim.cmd("silent! %bwipeout!")
  end)
end)

describe("ui without a git repo", function()
  it("uses the cwd as root for files under it, like the CLI", function()
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir .. "/sub/deep", "p")
    dir = vim.fs.normalize(vim.uv.fs_realpath(dir))
    vim.fn.writefile({ "hello" }, dir .. "/sub/deep/f.lua")
    local old = vim.fn.getcwd()
    vim.cmd.cd(dir)
    vim.cmd.edit(dir .. "/sub/deep/f.lua")
    ac.add(1, 1)
    api.nvim_buf_set_lines(0, 0, -1, false, { "hi" })
    api.nvim_feedkeys(api.nvim_replace_termcodes("<C-s>", true, false, true), "x", false)
    vim.cmd.cd(old)
    eq(#store.read(dir).threads, 1)
    eq(store.read(dir).threads[1].file, "sub/deep/f.lua")
  end)
end)

describe("thread float navigation", function()
  it("steps to the next/previous thread without closing the float", function()
    local lines = { "a", "b", "c", "d", "e" }
    local root = tmp_project({ ["nav.lua"] = lines })
    for _, l in ipairs({ 2, 4 }) do
      store.update(root, function(d)
        return store.add_thread(d, {
          file = "nav.lua", start = l, ["end"] = l,
          anchor = anchor.capture(lines, l, l), author = "user", body = "comment on " .. l,
        })
      end)
    end
    vim.cmd.edit(root .. "/nav.lua")
    local src = api.nvim_get_current_win()
    api.nvim_win_set_cursor(0, { 2, 0 })
    ac.command({ fargs = { "open" } })
    local function shown()
      return table.concat(api.nvim_buf_get_lines(0, 0, -1, false), "\n")
    end
    local function press(keys)
      api.nvim_feedkeys(api.nvim_replace_termcodes(keys, true, false, true), "x", false)
    end
    assert(shown():find("comment on 2", 1, true))
    press("n")
    assert(api.nvim_get_current_win() ~= src, "focus stays in a float")
    assert(shown():find("comment on 4", 1, true), shown())
    eq(api.nvim_win_get_cursor(src)[1], 4) -- source cursor followed
    press("n") -- wraps
    assert(shown():find("comment on 2", 1, true), shown())
    press("[r")
    assert(shown():find("comment on 4", 1, true), shown())
    press("p")
    assert(shown():find("comment on 2", 1, true), shown())
    eq(#vim.tbl_filter(function(w)
      return api.nvim_win_get_config(w).relative ~= ""
    end, api.nvim_list_wins()), 1) -- old floats are closed, not stacked
    press("q")
  end)
end)

describe("thread float navigation across files", function()
  it("N/P step through threads of all files in file/line order", function()
    local a_lines, b_lines = { "a1", "a2", "a3" }, { "b1", "b2", "b3" }
    local root = tmp_project({ ["a.lua"] = a_lines, ["b.lua"] = b_lines })
    local function add(file, lines, l)
      store.update(root, function(d)
        return store.add_thread(d, {
          file = file, start = l, ["end"] = l,
          anchor = anchor.capture(lines, l, l), author = "user", body = file .. ":" .. l,
        })
      end)
    end
    add("b.lua", b_lines, 2)
    add("a.lua", a_lines, 3)
    add("a.lua", a_lines, 1)
    vim.cmd.edit(root .. "/a.lua")
    local src = api.nvim_get_current_win()
    api.nvim_win_set_cursor(0, { 1, 0 })
    ac.command({ fargs = { "open" } })
    local function press(keys)
      api.nvim_feedkeys(api.nvim_replace_termcodes(keys, true, false, true), "x", false)
    end
    local function at()
      local body = api.nvim_buf_get_lines(0, -2, -1, false)[1] -- last message line
      local file = vim.fn.fnamemodify(api.nvim_buf_get_name(api.nvim_win_get_buf(src)), ":t")
      return { file, api.nvim_win_get_cursor(src)[1], body }
    end
    eq(at(), { "a.lua", 1, "a.lua:1" })
    press("N"); eq(at(), { "a.lua", 3, "a.lua:3" })
    press("N"); eq(at(), { "b.lua", 2, "b.lua:2" }) -- crosses into the next file
    press("N"); eq(at(), { "a.lua", 1, "a.lua:1" }) -- wraps around the project
    press("P"); eq(at(), { "b.lua", 2, "b.lua:2" })
    press("2P"); eq(at(), { "a.lua", 1, "a.lua:1" }) -- count
    press("q")
  end)
end)
