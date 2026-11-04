local keys = require("code-review.keys")
local store = require("code-review.store")
local ac = require("code-review")
local api = vim.api

local function maps(buf, lhs)
  local m = buf and api.nvim_buf_call(buf, function() return vim.fn.maparg(lhs, "n", false, true) end)
    or vim.fn.maparg(lhs, "n", false, true)
  return m and m.lhs ~= nil
end

describe("key bindings", function()
  it("takes a key, a list of keys or false", function()
    eq(keys.list("r"), { "r" })
    eq(keys.list({ "r", "i" }), { "r", "i" })
    eq(keys.list(false), {})
    eq(keys.label({ "<C-l>", "<leader>cl" }), "<C-l> / <leader>cl")
    eq(keys.label(false), nil)
  end)

  it("replaces a binding as a whole, and merges groups binding by binding", function()
    local km = keys.merge(
      { list = { "a", "b" }, thread = { reply = { "r", "i" }, edit = "e" } },
      { list = { "c" }, thread = { reply = "R" } })
    eq(km.list, { "c" })
    eq(km.thread, { reply = "R", edit = "e" })
    eq(keys.merge({ list = { "a" } }, { list = false }).list, false)
  end)

  it("maps both default list keys, and only the configured ones when set", function()
    ac.setup({ notify = false })
    assert(maps(nil, "<C-l>") and maps(nil, "<leader>cl"), "both list keys")
    vim.keymap.del("n", "<leader>cl")
    ac.setup({ notify = false, keymaps = { list = "<leader>cl" } })
    eq(ac.config.keymaps.list, "<leader>cl")
    assert(maps(nil, "<leader>cl"), "configured key")
    pcall(vim.keymap.del, "n", "<leader>cl")
    pcall(vim.keymap.del, "n", "<C-l>")
  end)

  it("fits the thread window footer to its width, the most useful keys first", function()
    ac.setup({ notify = false })
    local narrow = ac.thread_footer(60)
    assert(vim.fn.strdisplaywidth(narrow) <= 58, narrow)
    assert(narrow:find("r reply", 1, true) and narrow:find("q close", 1, true), narrow)
    assert(not narrow:find("across files", 1, true), narrow)
    assert(ac.thread_footer(200):find("N/P across files", 1, true))
  end)

  it("uses the configured keys in the thread window, its footer and the thread list", function()
    ac.setup({ notify = false, keymaps = { thread = { reply = "R", resolve = "X" } } })
    local root = tmp_project({ ["a.lua"] = { "1", "2" } })
    store.update(root, function(d)
      return store.add_thread(d, { file = "a.lua", start = 1, ["end"] = 1, anchor = { text = { "1" } }, author = "user", body = "q" })
    end)
    vim.cmd.edit(root .. "/a.lua")
    local tid = store.read(root).threads[1].id
    ac.open_thread(root, tid)
    local buf = api.nvim_get_current_buf()
    assert(maps(buf, "R") and maps(buf, "X") and not maps(buf, "r"), "thread window keys")
    local footer = api.nvim_win_get_config(0).footer
    local text = type(footer) == "table" and table.concat(vim.tbl_map(function(c) return c[1] end, footer)) or footer
    assert(text:find("R reply", 1, true) and text:find("X resolve", 1, true), text)
    vim.cmd("close")

    ac.list()
    api.nvim_feedkeys("X", "x", false)
    eq(store.read(root).threads[1].status, "resolved")
    vim.cmd("cclose")
    ac.setup({ notify = false })
  end)
end)
