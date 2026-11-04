local store = require("code-review.store")
local anchor = require("code-review.anchor")
local session = require("code-review.session")

local function pr_project()
  local root = tmp_project({})
  local cache = root .. "/cache"
  vim.fn.mkdir(cache .. "/base/src", "p")
  vim.fn.mkdir(cache .. "/head/src", "p")
  vim.fn.writefile({ "a", "old line", "b" }, cache .. "/base/src/x.py")
  vim.fn.writefile({ "a", "new line", "b" }, cache .. "/head/src/x.py")
  session.save(root, { kind = "pr", owner = "o", repo = "r", number = 1, cache = cache })
  return root
end

describe("session", function()
  it("is nil for a plain project", function()
    eq(session.load(tmp_project({})), nil)
  end)

  it("reads old and new text from the PR snapshots", function()
    local root = pr_project()
    eq(session.lines(root, "src/x.py", { side = "old" })[2], "old line")
    eq(session.lines(root, "src/x.py")[2], "new line")
    eq(session.lines(root, "src/missing.py"), nil)
  end)

  it("reads plain project files from disk", function()
    local root = tmp_project({ ["f.txt"] = { "one", "two" } })
    eq(session.lines(root, "f.txt"), { "one", "two" })
  end)
end)

describe("reanchor with sides", function()
  it("keeps an old-side thread open against the base snapshot", function()
    local root = pr_project()
    store.update(root, function(data)
      store.add_thread(data, {
        file = "src/x.py", side = "old", base = "abc", start = 2, ["end"] = 2,
        anchor = anchor.capture({ "a", "old line", "b" }, 2, 2), author = "user", body = "why?",
      })
      store.add_thread(data, {
        file = "src/x.py", start = 2, ["end"] = 2,
        anchor = anchor.capture({ "a", "new line", "b" }, 2, 2), author = "user", body = "ok?",
      })
    end)
    anchor.reanchor_root(root)
    local threads = store.read(root).threads
    eq(threads[1].status, "open")
    eq(threads[1].side, "old")
    eq(threads[2].status, "open")
    eq(threads[2].side, nil)
  end)

  it("marks a thread outdated when its text is gone from its own side", function()
    local root = pr_project()
    store.update(root, function(data)
      store.add_thread(data, {
        file = "src/x.py", side = "old", base = "abc", start = 2, ["end"] = 2,
        anchor = anchor.capture({ "a", "removed entirely", "b" }, 2, 2), author = "user", body = "?",
      })
    end)
    anchor.reanchor_root(root)
    eq(store.read(root).threads[1].status, "outdated")
  end)
end)
