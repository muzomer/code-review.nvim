local store = require("code-review.store")
local session = require("code-review.session")
local prompt = require("code-review.prompt")
local poke = require("code-review.poke")
local headless = require("code-review.headless")
local progress = require("code-review.progress")
progress.use_timer = false
local ac = require("code-review")

local function add(root, o)
  return store.update(root, function(d)
    return store.add_thread(d, vim.tbl_extend("keep", o, { author = "user" }))
  end)
end

describe("poke prompt", function()
  ac.setup({ notify = false })

  it("carries each waiting thread: id, place, code and your message", function()
    local root = tmp_project({ ["a.lua"] = { "x" } })
    add(root, { file = "a.lua", start = 3, ["end"] = 4, anchor = { text = { "local ok = pcall(load)", "if not ok then return end" } }, body = "why swallow\nthe error?" })
    local text, _, counts = prompt.build(root, { style = "subagent", cwd = root })
    assert(text:find("(1 new)", 1, true), text)
    assert(text:find("a.lua:3-4 — new", 1, true), text)
    assert(text:find("    > local ok = pcall(load)", 1, true), text)
    assert(text:find("  you: why swallow\n    the error?", 1, true), text)
    assert(text:find("code-review reply <id>", 1, true), text)
    -- an agent elsewhere (a fork runs where its session started) is told which project
    local elsewhere = prompt.build(root, { style = "fork", cwd = "/somewhere/else" })
    assert(elsewhere:find("code-review --root " .. root .. " reply <id>", 1, true), elsewhere)
    assert(prompt.build(root, { style = "plain" }):find("--root", 1, true)) -- unknown: say it too
    assert(text:find("subagent (Task tool)", 1, true), text)
    eq(counts, { new = 1, followup = 0, waiting = 0 })
  end)

  it("asks a background agent to sign its replies with its name", function()
    local root = tmp_project({ ["a.lua"] = { "x" } })
    add(root, { file = "a.lua", start = 1, ["end"] = 1, anchor = { text = { "x" } }, body = "why?" })
    assert(prompt.build(root, { style = "background", author = "claude" }):find('reply <id> "..." --author claude', 1, true))
    assert(not prompt.build(root, { style = "plain", all = true }):find("--author", 1, true))
  end)

  it("sends only what changed since the last poke; the rest is named", function()
    local root = tmp_project({ ["a.lua"] = { "x" } })
    local first = add(root, { file = "a.lua", start = 1, ["end"] = 1, anchor = { text = { "x" } }, body = "one" })
    local _, sent = prompt.build(root)
    prompt.mark_sent(root, sent)
    local second = add(root, { file = "a.lua", start = 2, ["end"] = 2, anchor = { text = { "y" } }, body = "two" })
    local text = prompt.build(root)
    assert(text:find("[" .. second .. "]", 1, true), text)
    assert(not text:find("[" .. first .. "]", 1, true), text)
    assert(text:find("Also still open from before: " .. first, 1, true), text)
    -- all = true (copying) sends everything again
    assert(prompt.build(root, { all = true }):find("[" .. first .. "]", 1, true))
  end)

  it("a reply after the agent answered is a follow-up with only your new messages", function()
    local root = tmp_project({ ["a.lua"] = { "x" } })
    local id = add(root, { file = "a.lua", start = 1, ["end"] = 1, anchor = { text = { "x" } }, body = "first question" })
    store.update(root, function(d)
      local t = store.find(d, id)
      store.add_message(t, "agent", "an answer")
      store.add_message(t, "user", "but why?")
    end)
    local text = prompt.build(root)
    assert(text:find("— follow-up", 1, true), text)
    assert(text:find("you: but why?", 1, true), text)
    assert(not text:find("first question", 1, true), text)
    assert(text:find("show " .. id, 1, true), text)
  end)

  it("an edited comment is sent again", function()
    local root = tmp_project({ ["a.lua"] = { "x" } })
    local id = add(root, { file = "a.lua", start = 1, ["end"] = 1, anchor = { text = { "x" } }, body = "draft" })
    local _, sent = prompt.build(root)
    prompt.mark_sent(root, sent)
    store.update(root, function(d) store.edit_last_user_message(store.find(d, id), "better wording") end)
    local text = prompt.build(root)
    assert(text:find("better wording", 1, true), text)
  end)

  it("names the PR and the snapshot commands in a PR review", function()
    local root = tmp_project({})
    session.save(root, { kind = "pr", owner = "acme", repo = "api", number = 12, files = {}, cache = root .. "/c" })
    add(root, { file = "src/x.py", side = "old", start = 2, ["end"] = 2, anchor = { text = { "old" } }, body = "q" })
    local text = prompt.build(root)
    assert(text:find("on PR acme/api#12", 1, true), text)
    assert(text:find("(old side, base commit)", 1, true), text)
    assert(text:find("code-review --pr acme/api#12 diff", 1, true), text)
  end)

  it("is nil when nothing waits on the agent", function()
    local root = tmp_project({ ["a.lua"] = { "x" } })
    eq(prompt.build(root), nil)
  end)
end)

describe("poke: keeping the agent's session small", function()
  ac.setup({ notify = false })
  local claude_home = vim.fn.tempname()
  local saved = {
    run = poke.run, avail = poke.available, h_avail = headless.available, spawn = headless.spawn,
    notify = vim.notify, select = vim.ui.select, own = vim.env.HERDR_PANE_ID, cfg = vim.env.CLAUDE_CONFIG_DIR,
  }
  local calls, spawned, notes, herdr_session
  local function fake()
    calls, spawned, notes = {}, {}, {}
    headless._reset()
    vim.env.CLAUDE_CONFIG_DIR = claude_home
    vim.env.HERDR_PANE_ID = "w1:p5"
    poke.available = function() return true end
    headless.available = function() return true end
    headless.spawn = function(args, cwd, _, _, env)
      spawned[#spawned + 1] = { args = args, cwd = cwd, env = env }
      return { kill = function() end }
    end
    poke.run = function(args)
      calls[#calls + 1] = args
      if args[3] == "list" then
        return { code = 0, stdout = vim.json.encode({ result = { agents = {
          { pane_id = "w1:p1", agent = "claude", agent_status = "idle", cwd = "/work/now", terminal_title_stripped = "Main",
            agent_session = herdr_session and { value = herdr_session } or nil },
        } } }), stderr = "" }
      end
      return { code = 0, stdout = vim.json.encode({ result = { ok = true } }), stderr = "" }
    end
    vim.ui.select = function(items, _, cb) cb(items[1]) end
    vim.notify = function(msg) notes[#notes + 1] = msg end
  end
  local function restore()
    progress.stop()
    headless._reset()
    poke.run, poke.available, headless.available, headless.spawn = saved.run, saved.avail, saved.h_avail, saved.spawn
    vim.notify, vim.ui.select, vim.env.HERDR_PANE_ID, vim.env.CLAUDE_CONFIG_DIR = saved.notify, saved.select, saved.own, saved.cfg
    ac.config.isolate = nil
    herdr_session = nil
  end
  local function case(name, fn)
    it(name, function()
      fake()
      local ok, err = xpcall(fn, debug.traceback)
      restore()
      if not ok then
        error(err, 0)
      end
    end)
  end
  ---A Claude Code transcript started in `cwd`.
  local function transcript(id, cwd)
    local dir = claude_home .. "/projects/" .. poke.project_dir_name(cwd)
    vim.fn.mkdir(dir, "p")
    local path = dir .. "/" .. id .. ".jsonl"
    vim.fn.writefile({ '{"type":"summary"}', vim.json.encode({ type = "user", cwd = cwd, sessionId = id }) }, path)
    return path
  end
  local function project()
    local root = tmp_project({ ["f.lua"] = { "a" } })
    add(root, { file = "f.lua", start = 1, ["end"] = 1, anchor = { text = { "a" } }, body = "why?" })
    return root
  end
  local function typed()
    return vim.tbl_filter(function(c) return c[3] == "prompt" end, calls)
  end
  local function arg_after(args, flag)
    for i, a in ipairs(args) do
      if a == flag then
        return args[i + 1]
      end
    end
  end

  case("forks the agent's session instead of typing into it", function()
    local root = project()
    herdr_session = "11111111-2222-4333-8444-555555555555"
    transcript(herdr_session, "/work/started-here")
    ac.poke(root)
    eq(#typed(), 0) -- the main session gets nothing
    eq(#spawned, 1)
    eq(arg_after(spawned[1].args, "--resume"), "11111111-2222-4333-8444-555555555555")
    assert(vim.tbl_contains(spawned[1].args, "--fork-session"))
    eq(spawned[1].cwd, "/work/started-here") -- where the session was started, not where the pane is now
    eq(spawned[1].env, { NVIM_CODE_REVIEW_ROOT = root }) -- the CLI still finds this project's comments
    -- it may change the code the comments are about, in the reviewed project
    assert(vim.tbl_contains(spawned[1].args, "Edit") and vim.tbl_contains(spawned[1].args, "Write"), vim.inspect(spawned[1].args))
    eq(arg_after(spawned[1].args, "--add-dir"), root)
    assert(spawned[1].args[3]:find("--root " .. root, 1, true), spawned[1].args[3])
    assert(spawned[1].args[3]:find("temporary copy", 1, true), spawned[1].args[3])
    eq(headless.session_id(root), nil) -- a fork is not the review's background session
    assert(progress.agent_title():find("Main (fork)", 1, true), tostring(progress.agent_title()))
  end)

  case("without a known session it types the prompt and asks for a subagent", function()
    local root = project()
    herdr_session = "00000000-0000-4000-8000-000000000000" -- no transcript: not trusted
    ac.poke(root)
    eq(#spawned, 0)
    eq(#typed(), 1)
    assert(typed()[1][5]:find("subagent (Task tool)", 1, true), typed()[1][5])
    -- says so: the prompt lands in the live session the fork was meant to spare
    assert(vim.iter(notes):any(function(n) return n:find("could not find the session of Main to fork", 1, true) end), vim.inspect(notes))
  end)

  case("isolate = false types the plain prompt", function()
    ac.config.isolate = false
    local root = project()
    ac.poke(root)
    eq(#typed(), 1)
    assert(not typed()[1][5]:find("subagent", 1, true), typed()[1][5])
  end)

  case("nothing waiting: no poke", function()
    local root = tmp_project({ ["f.lua"] = { "a" } })
    ac.poke(root)
    eq(#typed() + #spawned, 0)
    assert(vim.iter(notes):any(function(n) return n:find("no comment is waiting", 1, true) end), vim.inspect(notes))
  end)

  case("the second poke sends only the new comment", function()
    ac.config.isolate = false
    local root = project()
    ac.poke(root)
    add(root, { file = "f.lua", start = 1, ["end"] = 1, anchor = { text = { "a" } }, body = "another one" })
    ac.poke(root)
    local second = typed()[2][5]
    assert(second:find("another one", 1, true) and not second:find("why?", 1, true), second)
  end)
end)
