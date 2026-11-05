-- Discuss first: the agent changes code only for threads the reviewer approved.
local store = require("code-review.store")
local prompt = require("code-review.prompt")
local headless = require("code-review.headless")
local ac = require("code-review")

local function project()
  ac.setup({ notify = false })
  local root = tmp_project({ ["f.lua"] = { "a", "b" } })
  local ids = {}
  for i = 1, 2 do
    ids[i] = store.update(root, function(d)
      return store.add_thread(d, { file = "f.lua", start = i, ["end"] = i, anchor = { text = { "ab" } }, author = "user", body = "rename this?" })
    end)
  end
  return root, ids
end

local function edits(root)
  return vim.iter(headless.args(root, "x", { new_id = "id" })):any(function(a) return a:find("^Edit") ~= nil end)
end

local function thread(root, id)
  return store.find(store.read(root), id)
end

describe("approving code changes", function()
  it("by default the agent may only discuss: no edits, and the prompt says so", function()
    local root = project()
    local text = prompt.build(root, { style = "plain", all = true })
    assert(text:find("Do not edit any file", 1, true), text)
    assert(not text:find("Make the changes", 1, true), text)
    eq(edits(root), false)
  end)

  it("approving a thread tells the agent in the thread and lets it edit", function()
    local root, ids = project()
    local _, sent = prompt.build(root, { style = "plain" })
    prompt.mark_sent(root, sent)
    -- the agent answered; you approve the change it proposed
    store.update(root, function(d) store.add_message(store.find(d, ids[1]), "claude", "suggest renaming to `b`") end)
    ac.toggle_approved(root, ids[1])
    local t = thread(root, ids[1])
    eq({ t.approved, t.needs, t.messages[#t.messages].body }, { true, "agent", store.APPROVE })
    local text = prompt.build(root, { style = "plain" })
    assert(text and text:find("[" .. ids[1] .. "]", 1, true) and text:find("change approved", 1, true), tostring(text))
    assert(text:find("For the threads marked `change approved`", 1, true), text)
    assert(text:find("For every other thread, do not edit any file", 1, true), text)
    eq(edits(root), true)
  end)

  it("an approved thread sent before still allows the change", function()
    local root, ids = project()
    ac.toggle_approved(root, ids[1])
    local _, sent = prompt.build(root, { style = "plain" })
    prompt.mark_sent(root, sent) -- the run stopped before it got to it
    local text = prompt.build(root, { style = "plain" })
    assert(text:find(ids[1] .. " (change approved)", 1, true), text)
    assert(text:find("For the threads marked `change approved`", 1, true), text)
    assert(not text:find("Do not edit any file", 1, true), text)
    eq(edits(root), true)
  end)

  it("`a` in the thread window approves", function()
    local root, ids = project()
    vim.cmd.edit(root .. "/f.lua")
    ac.open_thread(root, ids[1])
    vim.api.nvim_feedkeys("a", "mx", false)
    eq(thread(root, ids[1]).approved, true)
    pcall(vim.cmd, "close")
  end)

  it("an approval is for one answer: the agent's reply ends it", function()
    local root, ids = project()
    ac.toggle_approved(root, ids[1])
    eq(store.find(store.read(root), ids[1]).messages[3], nil) -- (just the comment and the approval)
    eq(thread(root, ids[1]).messages[2].body, "Go ahead: apply the changes")
    store.update(root, function(d) store.add_message(store.find(d, ids[1]), "claude", "renamed it") end)
    eq(thread(root, ids[1]).approved, nil)
    eq(edits(root), false)
    -- a follow-up question is discussed, not changed
    store.update(root, function(d) store.add_message(store.find(d, ids[1]), "user", "and the other one?") end)
    local text = prompt.build(root, { style = "plain", all = true })
    assert(not text:find("change approved", 1, true) and text:find("Do not edit any file", 1, true), text)
    -- approving again works
    ac.toggle_approved(root, ids[1])
    eq(thread(root, ids[1]).approved, true)
  end)

  it("an approval without a new message is still sent again", function()
    local root, ids = project()
    local t = thread(root, ids[2])
    local before = prompt.signature(t)
    t.approved = true
    assert(prompt.signature(t) ~= before)
  end)

  it("approving, and withdrawing, are sent to the agent at once", function()
    local root, ids = project()
    local poke, poked = ac.poke, {}
    ac.poke = function(r) poked[#poked + 1] = r end
    local ok, err = pcall(function()
      ac.toggle_approved(root, ids[1])
      eq(poked, { root })
      ac.toggle_approved(root, ids[1])
      eq(poked, { root, root })
    end)
    ac.poke = poke
    assert(ok, err)
  end)

  it("pressing it again withdraws the approval", function()
    local root, ids = project()
    ac.toggle_approved(root, ids[1])
    ac.toggle_approved(root, ids[1])
    local t = thread(root, ids[1])
    eq({ t.approved, t.messages[#t.messages].body }, { nil, store.REVOKE })
    eq(edits(root), false)
  end)

  it("a resolved thread's approval does not let the agent edit", function()
    local root, ids = project()
    ac.toggle_approved(root, ids[1])
    store.update(root, function(d) store.find(d, ids[1]).status = "resolved" end)
    eq(edits(root), false)
  end)

  it("agent_changes = auto keeps the old behaviour", function()
    local root = project()
    ac.config.agent_changes = "auto"
    local ok, err = pcall(function()
      local text = prompt.build(root, { style = "plain", all = true })
      assert(text:find("Make the changes the comments ask for", 1, true), text)
      eq(edits(root), true)
    end)
    ac.config.agent_changes = "discuss"
    assert(ok, err)
  end)

  it("a PR review cannot approve changes", function()
    local root, ids = project()
    require("code-review.session").save(root, { kind = "pr", owner = "o", repo = "r", number = 1, files = {}, cache = root .. "/c" })
    local notify, notes = vim.notify, {}
    vim.notify = function(m) notes[#notes + 1] = m end
    ac.toggle_approved(root, ids[1])
    vim.notify = notify
    eq(thread(root, ids[1]).approved, nil)
    assert(table.concat(notes, "\n"):find("no checkout", 1, true), vim.inspect(notes))
  end)

  it("the CLI shows which threads are approved", function()
    local root, ids = project()
    ac.toggle_approved(root, ids[1])
    local r = vim.system({ PLUGIN_ROOT .. "/bin/code-review", "--root", root, "show", ids[1] }, { text = true, env = { NVIM_CODE_REVIEW_ROOT = "" } }):wait()
    assert(r.stdout:find("change approved", 1, true), r.stdout .. r.stderr)
  end)
end)
