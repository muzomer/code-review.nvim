local store = require("code-review.store")
local agents = require("code-review.agents")
local poke = require("code-review.poke")
local headless = require("code-review.headless")
local progress = require("code-review.progress")
progress.use_timer = false
local ac = require("code-review")

describe("other agents", function()
  ac.setup({ notify = false })
  local spawned, calls, herdr_agent
  local saved = {
    spawn = headless.spawn, avail = headless.available, herdr = poke.available, run = poke.run,
    notify = vim.notify, select = vim.ui.select, own = vim.env.HERDR_PANE_ID,
  }
  local function fake()
    spawned, calls = {}, {}
    headless._reset()
    headless.available = function() return true end
    poke.available = function() return false end
    vim.notify = function() end
    vim.env.HERDR_PANE_ID = "w1:p5"
    headless.spawn = function(args, cwd, on_line, on_exit)
      local p = { args = args, cwd = cwd, on_line = on_line, on_exit = on_exit }
      p.kill = function() end
      spawned[#spawned + 1] = p
      return p
    end
    poke.run = function(args)
      calls[#calls + 1] = args
      if args[3] == "list" then
        return { code = 0, stdout = vim.json.encode({ result = { agents = { herdr_agent } } }), stderr = "" }
      end
      return { code = 0, stdout = vim.json.encode({ result = { ok = true } }), stderr = "" }
    end
    vim.ui.select = function(items, _, cb) cb(items[1]) end
  end
  local function restore()
    progress.stop()
    headless._reset()
    headless.spawn, headless.available, poke.available, poke.run = saved.spawn, saved.avail, saved.herdr, saved.run
    vim.notify, vim.ui.select, vim.env.HERDR_PANE_ID = saved.notify, saved.select, saved.own
    ac.config.headless.agent = "claude"
    ac.config.headless.permission_mode = nil
    herdr_agent = nil
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
  local function project()
    local root = tmp_project({ ["f.lua"] = { "a" } })
    store.update(root, function(d)
      return store.add_thread(d, { file = "f.lua", start = 1, ["end"] = 1, anchor = { text = { "a" } }, author = "user", body = "why?" })
    end)
    return root
  end
  local function emit(p, ev)
    p.on_line(vim.json.encode(ev))
  end
  local function has_seq(args, seq)
    for i = 1, #args - #seq + 1 do
      if vim.deep_equal(vim.list_slice(args, i, i + #seq - 1), seq) then
        return true
      end
    end
    return false
  end

  case("codex: exec --json with a writable sandbox; its thread id is resumed next time", function()
    ac.config.headless.agent = "codex"
    local root = project()
    ac.poke(root)
    local p = spawned[1]
    eq({ p.args[1], p.args[2], p.args[3] }, { "codex", "exec", "--json" })
    assert(has_seq(p.args, { "--sandbox", "workspace-write" }), vim.inspect(p.args))
    assert(vim.tbl_contains(p.args, "--skip-git-repo-check"))
    emit(p, { type = "thread.started", thread_id = "0199a213-81c0-7800-8aa1-bbab2a035a53" })
    emit(p, { type = "item.started", item = { type = "command_execution", command = "code-review list --needs agent", status = "in_progress" } })
    emit(p, { type = "item.completed", item = { type = "agent_message", text = "Replied in t_1." } })
    emit(p, { type = "turn.completed", usage = {} })
    p.on_exit(0, "")
    local lines = headless.lines(root)
    eq({ lines[2], lines[3] }, { "→ $ code-review list --needs agent", "Replied in t_1." })
    eq(headless.session_id(root), "0199a213-81c0-7800-8aa1-bbab2a035a53")
    store.update(root, function(d)
      return store.add_thread(d, { file = "f.lua", start = 1, ["end"] = 1, anchor = { text = { "a" } }, author = "user", body = "more" })
    end)
    ac.poke(root)
    assert(has_seq(spawned[2].args, { "resume", "0199a213-81c0-7800-8aa1-bbab2a035a53" }), vim.inspect(spawned[2].args))
  end)

  case("codex: a failed turn fails the run", function()
    ac.config.headless.agent = "codex"
    local root = project()
    ac.poke(root)
    emit(spawned[1], { type = "turn.failed", error = { message = "quota exceeded" } })
    spawned[1].on_exit(1, "")
    eq(headless.status(root).status, "failed")
    eq(headless.status(root).error, "quota exceeded")
  end)

  case("gemini: streamed text is joined; later pokes resume the latest session of the review", function()
    ac.config.headless.agent = "gemini"
    ac.config.headless.permission_mode = "yolo"
    local root = project()
    ac.poke(root)
    local p = spawned[1]
    eq({ p.args[1], p.args[2] }, { "gemini", "-p" })
    assert(has_seq(p.args, { "-o", "stream-json" }) and has_seq(p.args, { "--approval-mode", "yolo" }), vim.inspect(p.args))
    eq(p.cwd, root)
    emit(p, { type = "init", session_id = "g-1", model = "x" })
    emit(p, { type = "message", role = "assistant", content = "Looking ", delta = true })
    emit(p, { type = "message", role = "assistant", content = "at it\nnow", delta = true })
    emit(p, { type = "tool_use", tool_name = "run_shell_command", parameters = { command = "code-review show t_1" } })
    emit(p, { type = "result", status = "success" })
    p.on_exit(0, "")
    local lines = headless.lines(root)
    eq(vim.list_slice(lines, 2, 4), { "Looking at it", "now", "→ run_shell_command code-review show t_1" })
    store.update(root, function(d)
      return store.add_thread(d, { file = "f.lua", start = 1, ["end"] = 1, anchor = { text = { "a" } }, author = "user", body = "more" })
    end)
    ac.poke(root)
    assert(has_seq(spawned[2].args, { "-r", "latest" }), vim.inspect(spawned[2].args))
  end)

  case("a session started with another agent is not resumed", function()
    local root = project()
    ac.poke(root) -- claude
    spawned[1].on_exit(0, "")
    assert(headless.session_id(root))
    ac.config.headless.agent = "codex"
    eq(headless.session_id(root), nil)
  end)

  case("a codex pane in herdr gets the plain prompt typed in (no fork, no subagent)", function()
    poke.available = function() return true end
    herdr_agent = { pane_id = "w1:p1", agent = "codex", agent_status = "idle", cwd = "/work", terminal_title_stripped = "Codex",
      agent_session = { value = "abc" } }
    local root = project()
    ac.poke(root)
    eq(#spawned, 0)
    local typed = vim.tbl_filter(function(c) return c[3] == "prompt" end, calls)
    eq(#typed, 1)
    assert(not typed[1][5]:find("subagent", 1, true), typed[1][5])
    assert(typed[1][5]:find("one line only", 1, true), typed[1][5])
  end)

  case("an opencode pane in herdr is answered by a fork of its session", function()
    poke.available = function() return true end
    herdr_agent = { pane_id = "w1:p1", agent = "opencode", agent_status = "idle", cwd = "/work/oc", terminal_title_stripped = "OC",
      agent_session = { value = "ses_123" } }
    local root = project()
    ac.poke(root)
    eq(#spawned, 1)
    local args = spawned[1].args
    eq({ args[1], args[2] }, { "opencode", "run" })
    assert(has_seq(args, { "--session", "ses_123" }) and vim.tbl_contains(args, "--fork") and has_seq(args, { "--dir", "/work/oc" }), vim.inspect(args))
    eq(spawned[1].cwd, "/work/oc")
    eq(headless.session_id(root), nil)
  end)

  it("every adapter builds a command and parses unknown events without failing", function()
    for _, name in ipairs(agents.NAMES) do
      local a = agents.get(name)
      local args = a.args({ cmd = a.cmd, prompt = "hi", cwd = "/x", dirs = { "/c" }, cfg = {}, new_id = "id" })
      eq(args[1], a.cmd)
      assert(vim.tbl_contains(args, "hi"), name)
      a.parse({ type = "something-new" })
      assert(type(a.chat(a.cmd, "id")) == "table", name)
    end
  end)
end)
