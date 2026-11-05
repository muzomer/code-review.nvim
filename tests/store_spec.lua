local store = require("code-review.store")
local anchor = require("code-review.anchor")

local function add(root, author, body)
  return store.update(root, function(data)
    return store.add_thread(data, {
      file = "f.lua", start = 1, ["end"] = 1,
      anchor = anchor.capture({ "x" }, 1, 1), author = author, body = body,
    })
  end)
end

describe("store", function()
  it("reads an empty store when nothing exists", function()
    eq(store.read(tmp_project()), { version = 1, threads = {} })
  end)

  it("finds the project root from a subdirectory", function()
    local root = tmp_project({ ["src/deep/f.lua"] = { "x" } })
    eq(store.find_root(root .. "/src/deep"), root)
  end)

  it("creates the directory git-ignored and round-trips threads", function()
    local root = tmp_project()
    local id = add(root, "user", "why?")
    eq(vim.fn.readfile(root .. "/.code-review/.gitignore"), { "*" })
    local t = store.find(store.read(root), id)
    eq(t.messages[1].id, id .. ".1")
    eq(t.messages[1].body, "why?")
    eq({ t.status, t.needs }, { "open", "agent" })
  end)

  it("derives needs from the last author and status", function()
    local root = tmp_project()
    local id = add(root, "user", "q")
    store.update(root, function(d) store.add_message(store.find(d, id), "claude", "a") end)
    eq(store.find(store.read(root), id).needs, "user")
    store.update(root, function(d) store.find(d, id).status = "resolved" end)
    eq(store.find(store.read(root), id).needs, "none")
  end)

  it("finds threads by message id", function()
    local root = tmp_project()
    local id = add(root, "user", "q")
    eq(store.find(store.read(root), id .. ".1").id, id)
  end)

  it("encodes empty lists, unicode and slashes cleanly", function()
    local s = store.encode({ version = 1, threads = {} })
    eq(vim.json.decode(s).threads, {})
    eq(store.encode({ "a/b", "é" }):find("\\/", 1, true), nil)
  end)

  it("skips the write on UNCHANGED", function()
    local root = tmp_project()
    add(root, "user", "q")
    local file = select(2, store.paths(root))
    local before = vim.uv.fs_stat(file).ino
    store.update(root, function() return store.UNCHANGED end)
    eq(vim.uv.fs_stat(file).ino, before)
  end)

  it("a failed write keeps the old file", function()
    local root = tmp_project()
    add(root, "user", "keep me")
    local _, file = store.paths(root)
    local before = table.concat(vim.fn.readfile(file), "\n")
    local fsync = vim.uv.fs_fsync
    vim.uv.fs_fsync = function() return nil, "ENOSPC: no space left on device", "ENOSPC" end
    local ok, err = pcall(add, root, "user", "lost")
    vim.uv.fs_fsync = fsync
    assert(not ok and tostring(err):find("ENOSPC", 1, true), tostring(err))
    eq(table.concat(vim.fn.readfile(file), "\n"), before)
    eq(vim.fn.glob(file .. ".tmp.*"), "") -- no temporary file left behind
  end)

  it("refuses an empty or malformed file instead of reading it as no threads", function()
    local root = tmp_project()
    store.ensure_dir(root)
    local _, file = store.paths(root)
    vim.fn.writefile({}, file)
    local ok, err = pcall(store.read, root)
    assert(not ok and tostring(err):find("empty", 1, true), tostring(err))
    vim.fn.writefile({ '{"threads": [{"id": "t_1", "messages": []}]}' }, file)
    ok, err = pcall(store.read, root)
    assert(not ok and tostring(err):find("t_1 has no file", 1, true), tostring(err))
    vim.fn.writefile({ '{"threads": {"a": 1}}' }, file)
    ok, err = pcall(store.read, root)
    assert(not ok and tostring(err):find("not a list", 1, true), tostring(err))
  end)

  it("fails at once when the lock cannot be created", function()
    local root = tmp_project()
    store.ensure_dir(root)
    local dir = store.paths(root)
    vim.uv.fs_chmod(dir, 365) -- r-x
    local t0 = vim.uv.hrtime()
    local ok, err = pcall(add, root, "user", "q")
    vim.uv.fs_chmod(dir, 493)
    assert(not ok and tostring(err):find("cannot lock", 1, true), tostring(err))
    assert((vim.uv.hrtime() - t0) / 1e6 < 1000, "it waited for the timeout")
  end)

  it("breaks stale locks and releases the lock after errors", function()
    local root = tmp_project()
    store.ensure_dir(root)
    local _, _, lock = store.paths(root)
    -- the process that held it is gone
    local dead = vim.system({ "true" })
    dead:wait()
    vim.fn.writefile({ tostring(dead.pid) }, lock)
    vim.uv.fs_utime(lock, os.time() - 2, os.time() - 2)
    add(root, "user", "q")
    eq(vim.uv.fs_stat(lock), nil)
    -- held by a live process, but far longer than any update takes
    vim.fn.writefile({ "1" }, lock)
    vim.uv.fs_utime(lock, os.time() - 120, os.time() - 120)
    add(root, "user", "q")
    eq(vim.uv.fs_stat(lock), nil)
    pcall(store.update, root, function() error("boom") end)
    eq(vim.uv.fs_stat(lock), nil)
  end)
end)
