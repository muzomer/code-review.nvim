-- Threads on selected text (part of a line), and several threads on one line.
local store = require("code-review.store")
local anchor = require("code-review.anchor")
local ac = require("code-review")

local api = vim.api
local ns = api.nvim_create_namespace("code-review")

local CODE = { "local x = 1", "local delay = retry_delay_ms * attempt", "return delay" }
local SPAN = { 15, 38 } -- "retry_delay_ms * attempt" on line 2

local function keys(k)
  api.nvim_feedkeys(api.nvim_replace_termcodes(k, true, false, true), "mx", false)
end

local function add(root, o)
  return store.update(root, function(d)
    return store.add_thread(d, {
      file = "f.lua", start = o.s, ["end"] = o.e, start_col = o.sc, end_col = o.ec,
      anchor = anchor.capture(CODE, o.s, o.e, o.sc, o.ec), author = "user", body = o.body,
    })
  end)
end

local function span_marks(buf)
  return vim.tbl_filter(function(m)
    return m[4].hl_group == "CodeReviewSpan"
  end, api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true }))
end

local function open(files)
  ac.setup({ notify = false })
  local root = tmp_project({ ["f.lua"] = files or CODE })
  return root, function()
    vim.cmd.edit(root .. "/f.lua")
    ac.render(api.nvim_get_current_buf())
    return api.nvim_get_current_buf()
  end
end

describe("threads on selected text", function()
  it("v + <leader>ca comments on the selected text; V keeps whole lines", function()
    local root, edit = open()
    edit()
    api.nvim_win_set_cursor(0, { 2, 14 })
    keys("v$" .. ac.config.keymaps.add) -- $ reaches past the end of the line
    api.nvim_buf_set_lines(0, 0, -1, false, { "why linear?" })
    keys("<C-s>")
    local t = store.read(root).threads[1]
    eq(t.range, { start = 2, ["end"] = 2, start_col = 15, end_col = 38 })
    eq(t.anchor.span, "retry_delay_ms * attempt")

    api.nvim_win_set_cursor(0, { 1, 2 })
    keys("V" .. ac.config.keymaps.add)
    api.nvim_buf_set_lines(0, 0, -1, false, { "whole line" })
    keys("<C-s>")
    t = store.read(root).threads[2]
    eq(t.range, { start = 1, ["end"] = 1 })
    eq(t.anchor.span, nil)
  end)

  it("selection_cols takes whole multibyte characters, and whole lines as lines", function()
    local lines = { "a = 'héllo'", "x" }
    eq({ ac.selection_cols(lines, 1, 1, 6, 7) }, { 6, 8 }) -- é is two bytes
    eq({ ac.selection_cols(lines, 1, 1, 1, 99) }, {}) -- every column: whole line
    eq({ ac.selection_cols({ "" }, 1, 1, 1, 1) }, {}) -- empty line
  end)

  it("highlights only the selected text; a thread on whole lines has no highlight", function()
    local root, edit = open()
    add(root, { s = 2, e = 2, sc = SPAN[1], ec = SPAN[2], body = "span" })
    add(root, { s = 3, e = 3, body = "line" })
    local buf = edit()
    local m = span_marks(buf)
    eq(#m, 1)
    eq({ m[1][2], m[1][3], m[1][4].end_row, m[1][4].end_col }, { 1, 14, 1, 38 })
  end)

  it("stale columns past the end of the line do not throw", function()
    local root = tmp_project({ ["f.lua"] = { "short" } })
    ac.setup({ notify = false })
    store.update(root, function(d)
      return store.add_thread(d, {
        file = "f.lua", start = 1, ["end"] = 1, start_col = 40, end_col = 50,
        anchor = { text = { "short" }, span = "gone" }, author = "user", body = "x",
      })
    end)
    vim.cmd.edit(root .. "/f.lua")
    local buf = api.nvim_get_current_buf()
    ac.render(buf)
    eq(#span_marks(buf), 0)
  end)

  it("follows the text when the line is edited and saved", function()
    local root, edit = open()
    local id = add(root, { s = 2, e = 2, sc = SPAN[1], ec = SPAN[2], body = "span" })
    local buf = edit()
    api.nvim_buf_set_text(buf, 1, 0, 1, 0, { "  " }) -- indent the line
    vim.cmd.write()
    local t = store.find(store.read(root), id)
    eq(t.range, { start = 2, ["end"] = 2, start_col = 17, end_col = 40 })
    eq(t.anchor.span, "retry_delay_ms * attempt")
  end)

  it("keeps the lines when only the selected text is deleted", function()
    local root, edit = open()
    local id = add(root, { s = 2, e = 2, sc = SPAN[1], ec = SPAN[2], body = "span" })
    local buf = edit()
    api.nvim_buf_set_text(buf, 1, 14, 1, 38, { "" })
    vim.cmd.write()
    local t = store.find(store.read(root), id)
    eq(t.status, "open")
    eq(t.range, { start = 2, ["end"] = 2 })
  end)

  it("the agent's prompt quotes the selected text", function()
    local root = open()
    add(root, { s = 2, e = 2, sc = SPAN[1], ec = SPAN[2], body = "why linear?" })
    local text = require("code-review.prompt").build(root, { style = "plain", all = true })
    assert(text:find('f.lua:2-2 on "retry_delay_ms * attempt"', 1, true), text)
  end)
end)

describe("several threads on one line", function()
  local function setup_two()
    local root, edit = open()
    local span = add(root, { s = 2, e = 2, sc = SPAN[1], ec = SPAN[2], body = "why linear?" })
    local line = add(root, { s = 2, e = 2, body = "rename delay" })
    return root, edit(), span, line
  end

  it("the gutter shows how many start on the line", function()
    local _, buf = setup_two()
    local signs = vim.tbl_filter(function(m)
      return m[4].sign_text and m[2] == 1
    end, api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true }))
    eq(#signs, 1)
    eq(vim.trim(signs[1][4].sign_text), "2")
  end)

  it("inside the selected text, <leader>cr opens that thread", function()
    local root, _, span = setup_two()
    api.nvim_win_set_cursor(0, { 2, 20 })
    eq({ ac.thread_at_cursor() }, { root, span })
  end)

  it("outside every selected text, it asks which one", function()
    local root, _, span, line = setup_two()
    api.nvim_win_set_cursor(0, { 2, 2 })
    local r, tid, many = ac.thread_at_cursor()
    eq({ r, tid, many }, { root, nil, { span, line } })
    local select, shown = vim.ui.select, nil
    vim.ui.select = function(items, o, cb)
      shown = vim.tbl_map(o.format_item, items)
      cb(items[2])
    end
    local got
    ac.with_thread_at_cursor(function(_, t) got = t end)
    vim.ui.select = select
    eq(got, line)
    assert(shown[1]:find('"retry_delay_ms * attempt"', 1, true) and shown[1]:find("you: why linear?", 1, true), shown[1])
    assert(shown[2]:find("whole line", 1, true), shown[2])
  end)

  it("overlapping threads on whole lines are both reachable", function()
    local root, edit = open()
    local a = add(root, { s = 1, e = 3, body = "block" })
    local b = add(root, { s = 2, e = 2, body = "line" })
    edit()
    api.nvim_win_set_cursor(0, { 2, 0 })
    local _, tid, many = ac.thread_at_cursor()
    eq({ tid, many }, { nil, { a, b } })
  end)

  it("]r stops at each thread, and <leader>cr opens the one it landed on", function()
    local root, edit = open()
    local a = add(root, { s = 2, e = 2, body = "first" })
    local b = add(root, { s = 2, e = 2, body = "second" })
    local c = add(root, { s = 2, e = 2, sc = SPAN[1], ec = SPAN[2], body = "span" })
    edit()
    api.nvim_win_set_cursor(0, { 1, 0 })
    local landed = {}
    for _ = 1, 4 do
      ac.jump(1)
      landed[#landed + 1] = select(2, ac.thread_at_cursor())
    end
    eq(landed, { a, b, c, a }) -- whole lines first, then the selected text; wraps around
    eq(api.nvim_win_get_cursor(0), { 2, 0 })
    ac.jump(-1)
    eq({ api.nvim_win_get_cursor(0), select(2, ac.thread_at_cursor()) }, { { 2, 14 }, c })
    eq(root ~= nil, true)
  end)
end)
