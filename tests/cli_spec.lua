local bin = PLUGIN_ROOT .. "/bin/code-review"

local function run(cwd, args, stdin, env)
  local cmd = { bin }
  vim.list_extend(cmd, args)
  env = vim.tbl_extend("force", { NVIM_CODE_REVIEW_ROOT = "", NVIM_CODE_REVIEW_HOOK = "" }, env or {})
  local r = vim.system(cmd, { cwd = cwd, stdin = stdin, text = true, env = env }):wait()
  return r.code, r.stdout, r.stderr
end

local function json(cwd, args)
  local code, out, err = run(cwd, vim.list_extend(vim.deepcopy(args), { "--json" }))
  assert(code == 0, err)
  return vim.json.decode(out)
end

describe("cli", function()
  local root = tmp_project({ ["src/a.lua"] = { "local a = 1", "local b = 2", "return a + b" } })

  it("adds, lists and shows agent threads", function()
    local id = json(root .. "/src", { "add", "a.lua", "2", "rename b?", "--author", "claude" }).id
    local list = json(root, { "list" })
    eq(#list, 1)
    eq({ list[1].id, list[1].file, list[1].needs }, { id, "src/a.lua", "user" })
    eq(list[1].messages[1].author, "claude")
    local code, out = run(root, { "show", id })
    eq(code, 0)
    assert(out:find("local b = 2", 1, true), out)
  end)

  it("replies from stdin and filters by needs", function()
    local id = json(root, { "list" })[1].id
    local code = run(root, { "reply", id, "-" }, "line one\nline two\n")
    eq(code, 0)
    local t = json(root, { "show", id })
    eq(t.messages[2].body, "line one\nline two")
    eq(#json(root, { "list", "--needs", "agent" }), 0)
  end)

  it("re-anchors on list after the file changes", function()
    vim.fn.writefile({ "-- header", "local a = 1", "local b = 2", "return a + b" }, root .. "/src/a.lua")
    eq(json(root, { "list" })[1].range, { start = 3, ["end"] = 3 })
    vim.fn.writefile({ "return 3" }, root .. "/src/a.lua")
    eq(json(root, { "list" })[1].status, "outdated")
  end)

  it("resolves with a message and hides resolved threads by default", function()
    local id = json(root, { "list" })[1].id
    eq(run(root, { "resolve", id, "done" }), 0)
    eq(#json(root, { "list" }), 0)
    local t = json(root, { "list", "--all" })[1]
    eq({ t.status, t.needs, t.messages[#t.messages].body }, { "resolved", "none", "done" })
  end)

  it("refuses to impersonate the user and reports errors", function()
    local code, _, err = run(root, { "reply", "t_0000", "x", "--author", "user" })
    eq(code, 1)
    assert(err:find("reserved", 1, true), err)
    code, _, err = run(root, { "reply", "t_nope", "x" })
    eq(code, 1)
    assert(err:find("no thread", 1, true), err)
  end)

  it("hook announces only threads that are new to the session", function()
    local p = tmp_project({ ["f.lua"] = { "one", "two" } })
    local function hook(session, cwd)
      local code, out = run("/", { "hook" }, vim.json.encode({ session_id = session, cwd = cwd or p }))
      eq(code, 0)
      return out
    end
    eq(hook("s1"), "") -- no store yet
    local store = require("code-review.store")
    local anchor = require("code-review.anchor")
    local id = store.update(p, function(d)
      return store.add_thread(d, {
        file = "f.lua", start = 2, ["end"] = 2,
        anchor = anchor.capture({ "one", "two" }, 2, 2), author = "user", body = "why\ntwo?",
      })
    end)
    local out = hook("s1")
    assert(out:find("1 review thread", 1, true) and out:find(id .. " f.lua:2: why two?", 1, true), out)
    eq(hook("s1"), "") -- already told
    assert(hook("s2"):find(id, 1, true)) -- other session hears about it
    run(p, { "reply", id, "because" })
    eq(hook("s1"), "") -- now waiting on the user, nothing to say
    store.update(p, function(d) store.add_message(store.find(d, id), "user", "really?") end)
    assert(hook("s1"):find("really?", 1, true)) -- new user message
  end)

  it("hook mode comes from NVIM_CODE_REVIEW_HOOK", function()
    local p = tmp_project({ ["f.lua"] = { "one" } })
    local store = require("code-review.store")
    store.update(p, function(d)
      return store.add_thread(d, {
        file = "f.lua", start = 1, ["end"] = 1,
        anchor = require("code-review.anchor").capture({ "one" }, 1, 1), author = "user", body = "fix",
      })
    end)
    local function hook(session, mode)
      local _, out = run("/", { "hook" }, vim.json.encode({ session_id = session, cwd = p }), { NVIM_CODE_REVIEW_HOOK = mode })
      return out
    end
    assert(hook("m", ""):find("don't act on them unasked", 1, true)) -- default
    assert(hook("m2", "mention"):find("don't act on them unasked", 1, true))
    local act = hook("a", "act")
    assert(act:find("handle these threads now", 1, true) and not act:find("unasked", 1, true), act)
    eq(hook("o", "off"), "")
    -- "off" records nothing, so switching that session to mention still reports
    assert(hook("o", "mention"):find("fix", 1, true))
    assert(hook("x", "bogus"):find("unasked", 1, true)) -- unknown value -> mention
  end)

  it("hook stays silent and succeeds on garbage input or outside projects", function()
    local code, out = run("/", { "hook" }, "not json")
    eq({ code, out }, { 0, "" })
  end)

  it("prints the skill", function()
    local code, out = run(root, { "skill" })
    eq(code, 0)
    assert(out:find("code-review list --needs agent", 1, true))
  end)
end)
