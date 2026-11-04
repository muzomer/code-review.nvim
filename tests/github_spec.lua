local github = require("code-review.github")
local session = require("code-review.session")

describe("github.parse_ref", function()
  it("parses a PR URL", function()
    eq(github.parse_ref("https://github.com/acme/api/pull/12"), {
      host = "github.com", owner = "acme", repo = "api", number = 12,
    })
  end)

  it("parses a PR URL with a trailing tab, query or fragment", function()
    local want = { host = "github.com", owner = "acme", repo = "api", number = 12 }
    eq(github.parse_ref("https://github.com/acme/api/pull/12/files"), want)
    eq(github.parse_ref("https://github.com/acme/api/pull/12#discussion_r1"), want)
  end)

  it("parses owner/repo#n", function()
    eq(github.parse_ref("acme/api#12"), { host = "github.com", owner = "acme", repo = "api", number = 12 })
  end)

  it("keeps the host of a GitHub Enterprise URL", function()
    eq(github.parse_ref("https://git.corp.example/acme/api/pull/3").host, "git.corp.example")
  end)

  it("rejects things that are not a PR", function()
    local ref, err = github.parse_ref("https://github.com/acme/api/issues/12")
    eq(ref, nil)
    eq(type(err), "string")
    eq((github.parse_ref("acme/api")), nil)
    eq((github.parse_ref("")), nil)
  end)
end)

describe("github.open_pr", function()
  local old_run, old_token

  local function fake_api(routes)
    github.run = function(args)
      local url = args[#args]
      local best -- the most specific (longest) matching route wins
      for suffix in pairs(routes) do
        if url:find(suffix, 1, true) and (not best or #suffix > #best) then
          best = suffix
        end
      end
      if best then
        local body = routes[best]
        local text = type(body) == "string" and body or vim.json.encode(body)
        return { code = 0, stdout = text .. "\n200", stderr = "" }
      end
      return { code = 0, stdout = "\n404", stderr = "" }
    end
  end

  local function setup()
    old_run, old_token = github.run, vim.env.GH_TOKEN
    vim.env.GH_TOKEN = "test-token"
  end
  local function teardown()
    github.run = old_run
    vim.env.GH_TOKEN = old_token
  end

  it("snapshots changed files on both sides and records the session", function()
    setup()
    fake_api({
      ["/pulls/7/files"] = {
        { filename = "src/a.py", status = "modified", additions = 1, deletions = 1 },
        { filename = "src/new.py", status = "added", additions = 2, deletions = 0 },
        { filename = "src/gone.py", status = "removed", additions = 0, deletions = 3 },
      },
      ["/pulls/7"] = {
        title = "Fix", html_url = "u", base = { sha = "BASE", ref = "main" }, head = { sha = "HEAD", ref = "fix" },
      },
      ["contents/src/a.py?ref=BASE"] = "old a",
      ["contents/src/a.py?ref=HEAD"] = "new a",
      ["contents/src/new.py?ref=HEAD"] = "new file",
      ["contents/src/gone.py?ref=BASE"] = "gone",
    })
    local root = assert(github.open_pr({ host = "github.com", owner = "t", repo = "r", number = 7 }))
    local s = session.load(root)
    eq(s.base_sha, "BASE")
    eq(s.head_sha, "HEAD")
    eq(#s.files, 3)
    eq(session.lines(root, "src/a.py", { side = "old" }), { "old a" })
    eq(session.lines(root, "src/a.py"), { "new a" })
    eq(session.lines(root, "src/new.py", { side = "old" }), nil)
    eq(session.lines(root, "src/gone.py"), nil)
    teardown()
  end)

  it("fetches an unchanged file on demand and then serves it from the cache", function()
    setup()
    local calls = 0
    fake_api({
      ["/pulls/8/files"] = {},
      ["/pulls/8"] = { title = "T", html_url = "u", base = { sha = "B2", ref = "main" }, head = { sha = "H2", ref = "x" } },
    })
    local root = assert(github.open_pr({ host = "github.com", owner = "t", repo = "r", number = 8 }))
    local inner = github.run
    github.run = function(args)
      if args[#args]:find("contents/lib/util.py?ref=H2", 1, true) then
        calls = calls + 1
        return { code = 0, stdout = "helper\n200", stderr = "" }
      end
      return inner(args)
    end
    local path = assert(github.ensure_file(root, "lib/util.py"))
    eq(vim.fn.readfile(path), { "helper" })
    assert(github.ensure_file(root, "lib/util.py"))
    eq(calls, 1)
    teardown()
  end)

  it("reports a missing token clearly", function()
    old_run, old_token = github.run, vim.env.GH_TOKEN
    vim.env.GH_TOKEN, vim.env.GITHUB_TOKEN = nil, nil
    github.run = function() return { code = 1, stdout = "", stderr = "" } end
    local body, err = github.get("github.com", "/x")
    eq(body, nil)
    assert(err:find("no GitHub token", 1, true))
    teardown()
  end)
end)

describe("github.get retries", function()
  it("retries transient 503s and then succeeds", function()
    local old_run, old_delay = github.run, github.retry_delay_ms
    vim.env.GH_TOKEN = "t"
    github.retry_delay_ms = 1
    local calls = 0
    github.run = function()
      calls = calls + 1
      if calls < 3 then
        return { code = 0, stdout = "Service Unavailable\n503", stderr = "" }
      end
      return { code = 0, stdout = '{"ok":true}\n200', stderr = "" }
    end
    local data = github.get("github.com", "/x")
    eq({ data and data.ok, calls }, { true, 3 })
    github.run, github.retry_delay_ms = old_run, old_delay
  end)

  it("gives up after the retry budget and says what happened", function()
    local old_run, old_delay = github.run, github.retry_delay_ms
    vim.env.GH_TOKEN = "t"
    github.retry_delay_ms = 1
    local calls = 0
    github.run = function()
      calls = calls + 1
      return { code = 0, stdout = "x\n503", stderr = "" }
    end
    local data, err = github.get("github.com", "/x")
    eq(data, nil)
    eq(calls, github.retries + 1)
    assert(err:find("503", 1, true), err)
    github.run, github.retry_delay_ms = old_run, old_delay
  end)
end)
