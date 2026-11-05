-- Failures while opening a PR must end cleanly: no review stuck "loading", no
-- traceback, one-line messages. Nothing here touches the network or the system:
-- curl, git and the disk are faked by replacing functions.
local session = require("code-review.session")
local github = require("code-review.github")
local diff = require("code-review.diff")
local unified = require("code-review.unified")
local ac = require("code-review")

local api = vim.api
local real_run = github.run -- no earlier spec replaces it

local routes = {}
local function fake(r)
  routes = r
  github.run = function(args)
    local url, best = args[#args], nil
    for k in pairs(routes) do
      if url:find(k, 1, true) and (not best or #k > #best) then
        best = k
      end
    end
    local b = best and routes[best]
    if type(b) == "table" and b.status then -- { status = 500, body = "..." }
      return { code = 0, stdout = (b.body or "") .. "\n" .. b.status, stderr = "" }
    end
    return { code = 0, stdout = best and ((type(b) == "string" and b or vim.json.encode(b)) .. "\n200") or "\n404", stderr = "" }
  end
end

local function pr_routes(n, files, contents)
  local r = {
    [string.format("/pulls/%d/files", n)] = files,
    [string.format("/pulls/%d", n)] = { title = "T", html_url = "u", base = { sha = "B" .. n, ref = "main" }, head = { sha = "H" .. n, ref = "x" } },
  }
  for k, v in pairs(contents or {}) do
    r[k] = v
  end
  return r
end

-- Run `body` with stubs in place; always undo them, then rethrow.
local function with(stubs, body)
  local saved = {}
  for _, s in ipairs(stubs) do
    saved[#saved + 1] = { s[1], s[2], s[1][s[2]] }
    s[1][s[2]] = s[3]
  end
  local notes, one_line = {}, ac.one_line
  ac.one_line = function(m) return m end -- it cuts at the (headless, 80) screen width: check whole messages
  local notify = vim.notify
  vim.notify = function(msg, level)
    notes[#notes + 1] = { msg = msg, level = level }
  end
  local ok, err = pcall(body, notes)
  vim.notify, ac.one_line = notify, one_line
  for i = #saved, 1, -1 do
    saved[i][1][saved[i][2]] = saved[i][3]
  end
  github.run = real_run
  diff.close()
  assert(ok, err)
end

local function find(notes, pat)
  for _, n in ipairs(notes) do
    if n.msg:find(pat) then
      return n
    end
  end
end

describe("PR failures", function()
  ac.setup({ notify = false })
  vim.env.GH_TOKEN = "t"

  it("curl missing: the download fails at once instead of loading forever", function()
    with({
      { vim, "system", function(args) error("ENOENT: no such file or directory (cmd): '" .. args[1] .. "'") end },
    }, function(notes)
      github.run = real_run -- through the real spawn path
      local root = diff.open("acme/fail#901")
      eq(diff.loading(root), false)
      local n = assert(find(notes, "curl failed"), vim.inspect(notes))
      eq(n.level, vim.log.levels.ERROR)
      assert(not n.msg:find("\n"), n.msg)
      -- and a retry is not refused as "already downloading"
      diff.open("acme/fail#901")
      eq(find(notes, "already downloading"), nil)
    end)
  end)

  it("a replaced run that throws is reported the same way", function()
    with({}, function(notes)
      github.run = function() error("boom") end
      local root = diff.open("acme/fail#902")
      eq(diff.loading(root), false)
      assert(find(notes, "boom"), vim.inspect(notes))
    end)
  end)

  it("snapshots that cannot be written are reported, and the download still ends", function()
    local open = io.open
    with({
      { io, "open", function(path, mode)
        if path:find("/base/", 1, true) and mode == "wb" then
          return nil, path .. ": Permission denied"
        end
        return open(path, mode)
      end },
    }, function(notes)
      fake(pr_routes(903, { { filename = "a.txt", status = "modified" }, { filename = "b.txt", status = "modified" } }, {
        ["contents/a.txt?ref=B903"] = "a0\n", ["contents/a.txt?ref=H903"] = "a1\n",
        ["contents/b.txt?ref=B903"] = "b0\n", ["contents/b.txt?ref=H903"] = "b1\n",
      }))
      local root = diff.open("acme/fail#903")
      eq(diff.loading(root), false)
      local n = assert(find(notes, "2 file%(s%) could not be downloaded"), vim.inspect(notes))
      eq(n.level, vim.log.levels.WARN)
      assert(n.msg:find("a.txt, b.txt (cannot save", 1, true), n.msg)
      assert(find(notes, "2 changed files"), vim.inspect(notes)) -- on_done ran to the end
    end)
  end)

  it("a file that fails with a 500 does not stay \"loading\"", function()
    with({}, function(notes)
      fake(pr_routes(904, { { filename = "x.txt", status = "modified" } }, {
        ["contents/x.txt?ref=B904"] = { status = 500, body = '{"message":"Server Error"}' },
        ["contents/x.txt?ref=H904"] = { status = 500, body = '{"message":"Server Error"}' },
      }))
      local saved = github.retries
      github.retries = 0
      local ok, err = pcall(diff.open, "acme/fail#904")
      github.retries = saved
      assert(ok, err)
      local text = table.concat(api.nvim_buf_get_lines(0, 0, -1, false), "\n")
      assert(not text:find("loading", 1, true), text)
      assert(find(notes, "no text content"), vim.inspect(notes))
      local n = assert(find(notes, "could not be downloaded"), vim.inspect(notes))
      assert(n.msg:find("x.txt (GitHub returned 500", 1, true), n.msg)
    end)
  end)

  it("closing the review tab during the download does not reopen it", function()
    local queue, run_async = {}, github.run_async
    with({
      { github, "run_async", function(args, cb) queue[#queue + 1] = function() cb(github.run(args)) end end },
    }, function()
      fake(pr_routes(905, { { filename = "y.txt", status = "added" } }, { ["contents/y.txt?ref=H905"] = "y\n" }))
      diff.open("acme/fail#905")
      table.remove(queue, 1)() -- the PR
      table.remove(queue, 1)() -- its files: the review opens
      local tabs = #api.nvim_list_tabpages()
      eq(tabs > 1, true)
      vim.cmd.tabclose()
      while #queue > 0 do
        table.remove(queue, 1)()
      end
      eq(#api.nvim_list_tabpages(), tabs - 1)

      -- the same during a reload, closed before even the file list arrived
      diff.open("acme/fail#905")
      while #queue > 0 do
        table.remove(queue, 1)()
      end
      tabs = #api.nvim_list_tabpages()
      local root = diff.where()
      diff.reload(root)
      vim.cmd.tabclose()
      while #queue > 0 do
        table.remove(queue, 1)()
      end
      eq(#api.nvim_list_tabpages(), tabs - 1)
      eq(diff.loading(root), false)
    end)
    eq(github.run_async, run_async)
  end)

  it("a PR reviewed before opens from disk when GitHub cannot be reached", function()
    with({}, function(notes)
      fake(pr_routes(906, { { filename = "a.txt", status = "modified" }, { filename = "zz.dat", status = "modified" } }, {
        ["contents/a.txt?ref=B906"] = "a0\n", ["contents/a.txt?ref=H906"] = "a1\n",
      })) -- zz.dat has no text: the review is never "complete"
      local root = diff.open("acme/fail#906")
      diff.close()
      github.run = function() return { code = 6, stdout = "", stderr = "curl: (6) Could not resolve host" } end
      diff.open("acme/fail#906")
      eq(diff.loading(root), false)
      assert(find(notes, "showing your saved copy"), vim.inspect(notes))
      local names = vim.tbl_map(function(w) return api.nvim_buf_get_name(api.nvim_win_get_buf(w)) end, api.nvim_tabpage_list_wins(0))
      assert(table.concat(names, "\n"):find("/head/", 1, true), vim.inspect(names))
    end)
  end)

  it("explains GitHub errors from their message, rate limits included", function()
    local function status(code, body)
      github.run = function() return { code = 0, stdout = body .. "\n" .. code, stderr = "" } end
      return select(2, github.get("github.com", "/x"))
    end
    with({}, function()
      local err = status(403, '{"message":"API rate limit exceeded for 1.2.3.4."}')
      assert(err:find("rate limit", 1, true) and not err:find("scope", 1, true), err)
      err = status(429, '{"message":"You have exceeded a secondary rate limit"}')
      assert(err:find("rate limit", 1, true), err)
      err = status(403, '{"message":"Resource not accessible by integration"}')
      assert(err:find("scope", 1, true) and err:find("Resource not accessible", 1, true), err)
      local saved = github.retries
      github.retries = 0
      err = status(500, "<html>oops</html>")
      github.retries = saved
      eq(err, "GitHub returned 500 for /x")
    end)
  end)

  it("curl gets timeouts, after which the URL stays last", function()
    local seen
    with({}, function()
      github.run = function(args)
        seen = args
        return { code = 0, stdout = "{}\n200", stderr = "" }
      end
      github.get("github.com", "/y")
    end)
    local s = table.concat(seen, " ")
    assert(s:find("--connect-timeout 10", 1, true) and s:find("--max-time 60", 1, true), s)
    eq(seen[#seen], "https://api.github.com/y")
  end)

  it("a failed `gh auth token` is asked again later", function()
    local saved = { vim.env.GH_TOKEN, vim.env.GITHUB_TOKEN }
    vim.env.GH_TOKEN, vim.env.GITHUB_TOKEN = nil, nil
    github.reset_token()
    with({ { vim.fn, "executable", function() return 1 end } }, function()
      github.run = function() return { code = 1, stdout = "", stderr = "not logged in" } end
      eq(github.token(), nil)
      github.run = function() return { code = 0, stdout = "tok\n", stderr = "" } end
      eq(github.token(), "tok")
    end)
    vim.env.GH_TOKEN, vim.env.GITHUB_TOKEN = saved[1], saved[2]
    github.reset_token()
  end)
end)

describe("unified view failures", function()
  local function show(old, new)
    local lines = session.lines
    session.lines = function(_, _, opts)
      return opts and opts.side == "old" and old or new
    end
    local ok, buf = pcall(unified.show, "/tmp/none", "f.bin", api.nvim_get_current_win())
    session.lines = lines
    assert(ok, buf)
    return buf
  end

  it("shows a file with NUL bytes", function()
    local buf = show({ "a\nb" }, { "a\nb", "c" })
    eq(api.nvim_buf_get_lines(buf, 0, -1, false), { "a\0b", "c" })
  end)

  it("commenting in an empty view is refused, not a crash", function()
    local buf = show({}, {})
    eq(unified.translate(buf, 1, 1), nil)
  end)
end)

describe("session without git", function()
  it("has no old text when git is not installed", function()
    local root = tmp_project({ ["f.txt"] = { "x" } })
    local system = vim.system
    vim.system = function() error("ENOENT: no such file or directory (cmd): 'git'") end
    local ok, res = pcall(session.lines, root, "f.txt", { side = "old", base = "HEAD" })
    vim.system = system
    assert(ok, res)
    eq(res, nil)
  end)
end)
