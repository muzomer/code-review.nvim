local store = require("code-review.store")
local anchor = require("code-review.anchor")
local ac = require("code-review")

local api = vim.api
local bin = PLUGIN_ROOT .. "/bin/code-review"

local function run(cwd, args, stdin)
  local cmd = { bin }
  vim.list_extend(cmd, args)
  local r = vim.system(cmd, { cwd = cwd, stdin = stdin, text = true, env = { NVIM_CODE_REVIEW_ROOT = "" } }):wait()
  return r.code, r.stdout, r.stderr
end

local function feed(keys)
  api.nvim_feedkeys(api.nvim_replace_termcodes(keys, true, false, true), "x", false)
end

local function close_floats()
  for _, w in ipairs(api.nvim_list_wins()) do
    if api.nvim_win_get_config(w).relative ~= "" then
      pcall(api.nvim_win_close, w, true)
    end
  end
end

local function thread(root, body)
  return store.update(root, function(d)
    return store.add_thread(d, {
      file = "f.lua", start = 2, ["end"] = 2,
      anchor = anchor.capture({ "one", "two" }, 2, 2), author = "user", body = body,
    })
  end)
end

describe("editing a comment", function()
  ac.setup({ notify = false })
  local root = tmp_project({ ["f.lua"] = { "one", "two" } })
  vim.cmd.edit(root .. "/f.lua")

  local function body_of(id) return store.find(store.read(root), id).messages[1].body end

  it("store: edits the user's last message and marks it", function()
    local id = thread(root, "first")
    store.update(root, function(d)
      local ok = store.edit_last_user_message(store.find(d, id), "second")
      assert(ok)
    end)
    local m = store.find(store.read(root), id).messages[1]
    eq(m.body, "second")
    assert(m.edited, "edited timestamp expected")
  end)

  it("store: refuses once the agent has replied, and for agent messages", function()
    local id = thread(root, "q")
    store.update(root, function(d) store.add_message(store.find(d, id), "agent", "a") end)
    store.update(root, function(d)
      local ok, err = store.edit_last_user_message(store.find(d, id), "changed")
      eq(ok, false)
      assert(err:find("already replied", 1, true), err)
      return store.UNCHANGED
    end)
    eq(store.find(store.read(root), id).messages[1].body, "q")
  end)

  it("store: an unchanged text is not marked as edited", function()
    local id = thread(root, "same")
    store.update(root, function(d) store.edit_last_user_message(store.find(d, id), "same") end)
    eq(store.find(store.read(root), id).messages[1].edited, nil)
  end)

  it("e opens the editor pre-filled and saves the new text", function()
    local id = thread(root, "old text\nsecond line")
    ac.open_thread(root, id)
    feed("e")
    eq(api.nvim_buf_get_lines(0, 0, -1, false), { "old text", "second line" })
    api.nvim_buf_set_lines(0, 0, -1, false, { "new text" })
    feed("<C-s>")
    local t = store.find(store.read(root), id)
    eq({ #t.messages, t.messages[1].body, t.needs }, { 1, "new text", "agent" })
    assert(t.messages[1].edited)
    assert(table.concat(ac.thread_markdown(t), "\n"):find("· edited", 1, true))
  end)

  it("cancelling leaves the comment untouched", function()
    local id = thread(root, "keep me")
    ac.open_thread(root, id)
    feed("e")
    feed("<Esc>q") -- <Esc> leaves insert mode, q cancels
    eq(body_of(id), "keep me")
  end)

  it("says so instead of opening the editor when the agent already replied", function()
    local id = thread(root, "asked")
    store.update(root, function(d) store.add_message(store.find(d, id), "agent", "answered") end)
    close_floats()
    vim.cmd.edit(root .. "/f.lua")
    ac.edit(root, id)
    eq(api.nvim_win_get_config(0).relative, "") -- no float opened
  end)

  it("does not overwrite when the agent replies while the editor is open", function()
    local id = thread(root, "before")
    close_floats()
    vim.cmd.edit(root .. "/f.lua")
    ac.edit(root, id)
    api.nvim_buf_set_lines(0, 0, -1, false, { "late edit" })
    store.update(root, function(d) store.add_message(store.find(d, id), "agent", "too late") end)
    feed("<C-s>")
    local t = store.find(store.read(root), id)
    eq({ t.messages[1].body, #t.messages }, { "before", 2 })
  end)

  it("the CLI marks an edited comment", function()
    local p = tmp_project({ ["f.lua"] = { "one", "two" } })
    local id = store.update(p, function(d)
      return store.add_thread(d, {
        file = "f.lua", start = 2, ["end"] = 2,
        anchor = anchor.capture({ "one", "two" }, 2, 2), author = "user", body = "why?",
      })
    end)
    store.update(p, function(d) store.edit_last_user_message(store.find(d, id), "why is it two?") end)
    local _, shown = run(p, { "show", id })
    assert(shown:find("[edited ", 1, true) and shown:find("why is it two?", 1, true), shown)
  end)
end)
