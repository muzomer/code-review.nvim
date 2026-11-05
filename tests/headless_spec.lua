local store = require("code-review.store")
local poke = require("code-review.poke")
local headless = require("code-review.headless")
local progress = require("code-review.progress")
progress.use_timer = false
local ac = require("code-review")

local api = vim.api

local function feed(keys)
  api.nvim_feedkeys(api.nvim_replace_termcodes(keys, true, false, true), "x", false)
end

describe("background agent", function()
  ac.setup({ notify = false })
  local spawned, notes
  local saved = {
    spawn = headless.spawn, avail = headless.available, herdr = poke.available,
    notify = vim.notify, select = vim.ui.select, run = poke.run,
  }
  local function fake()
    spawned, notes = {}, {}
    headless._reset()
    headless.available = function() return true end
    poke.available = function() return false end
    vim.notify = function(msg) notes[#notes + 1] = msg end
    headless.spawn = function(args, cwd, on_line, on_exit)
      local p = { args = args, cwd = cwd, on_line = on_line, on_exit = on_exit, killed = false }
      p.kill = function() p.killed = true end
      spawned[#spawned + 1] = p
      return p
    end
  end
  local function restore()
    progress.stop()
    headless._reset()
    headless.spawn, headless.available, poke.available = saved.spawn, saved.avail, saved.herdr
    vim.notify, vim.ui.select, poke.run = saved.notify, saved.select, saved.run
    ac.config.agent = "auto"
  end
  local function arg_after(p, flag)
    for i, a in ipairs(p.args) do
      if a == flag then
        return p.args[i + 1]
      end
    end
  end
  local function emit(p, event)
    p.on_line(vim.json.encode(event))
  end
  ---A project with one comment waiting for the agent.
  local function project(files)
    local root = tmp_project(files or { ["f.lua"] = { "a" } })
    store.update(root, function(d)
      return store.add_thread(d, { file = "f.lua", start = 1, ["end"] = 1, anchor = { text = { "a" } }, author = "user", body = "why?" })
    end)
    return root
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

  case("without herdr a poke starts claude -p with a new session, in the review root", function()
    local root = project()
    ac.poke(root)
    eq(#spawned, 1)
    local p = spawned[1]
    eq({ p.args[1], p.args[2] }, { "claude", "-p" })
    eq(p.cwd, root)
    local id = arg_after(p, "--session-id")
    assert(id and id:match("^%x+%-%x+%-4%x+%-[89ab]%x+%-%x+$"), tostring(id))
    eq(headless.session_id(root), id)
    eq(arg_after(p, "--output-format"), "stream-json")
    eq(arg_after(p, "--allowedTools"), "Bash(code-review:*)")
    -- the full path of this checkout's CLI is allowed too: nobody can approve it in the background
    local agents = require("code-review.agents")
    assert(vim.tbl_contains(p.args, "Bash(" .. agents.BIN .. "/code-review:*)"), vim.inspect(p.args))
    eq(vim.fn.executable(agents.BIN .. "/code-review"), 1)
    assert(p.args[3]:find("code-review", 1, true) and p.args[3]:find("background", 1, true))
    assert(p.args[3]:find("exactly as written", 1, true), p.args[3])
  end)

  case("a PR review stays read-only; a local one may edit", function()
    local root = project()
    local args = headless.args(root, "x", { new_id = "id" })
    -- only inside the project (`//` = absolute); an Edit rule covers Write, a bare Write would allow any path
    assert(vim.tbl_contains(args, "Edit(/" .. vim.fs.normalize(root) .. "/**)"), vim.inspect(args))
    assert(not vim.tbl_contains(args, "Edit") and not vim.tbl_contains(args, "Write"), vim.inspect(args))
    eq(arg_after({ args = args }, "--add-dir"), nil) -- it runs in the project already
    require("code-review.session").save(root, { kind = "pr", owner = "o", repo = "r", number = 1, files = {}, cache = root .. "/c" })
    args = headless.args(root, "x", { new_id = "id" })
    for _, a in ipairs(args) do
      assert(not a:find("^Edit") and not a:find("^Write"), vim.inspect(args))
    end
  end)

  case("the next poke resumes the same session", function()
    local root = project()
    ac.poke(root)
    local id = arg_after(spawned[1], "--session-id")
    spawned[1].on_exit(0, "")
    ac.poke(root)
    eq(#spawned, 2)
    eq(arg_after(spawned[2], "--resume"), id)
    eq(arg_after(spawned[2], "--session-id"), nil)
  end)

  case("progress follows the run: working, then done when the process ends", function()
    local root = project()
    ac.poke(root)
    progress.tick()
    assert(progress.statusline():find("working"), progress.statusline())
    emit(spawned[1], { type = "assistant", message = { content = {
      { type = "text", text = "Looking at the comments" },
      { type = "tool_use", name = "Bash", input = { command = "code-review list --needs agent" } },
    } } })
    eq(headless.lines(root)[2], "Looking at the comments")
    eq(headless.lines(root)[3], "→ Bash code-review list --needs agent")
    emit(spawned[1], { type = "result", subtype = "success", is_error = false, total_cost_usd = 0.05 })
    spawned[1].on_exit(0, "")
    progress.tick()
    assert(progress.statusline():find("done"), progress.statusline())
    eq(headless.lines(root)[#headless.lines(root)], "✓ done · $0.05")
  end)

  case("a failed run is reported", function()
    local root = project()
    ac.poke(root)
    spawned[1].on_exit(1, "boom")
    progress.tick()
    eq(headless.status(root).status, "failed")
    assert(vim.iter(notes):any(function(n) return n:find("failed: boom", 1, true) end), vim.inspect(notes))
  end)

  case("a process that cannot start is reported, and the next poke tries again", function()
    local root = project()
    local spawn = headless.spawn
    headless.spawn = function() error("ENOENT: no such file or directory (cwd): '/gone'") end
    ac.poke(root)
    eq(headless.status(root).status, "failed")
    assert(vim.iter(notes):any(function(n) return n:find("could not start", 1, true) and n:find("ENOENT", 1, true) end), vim.inspect(notes))
    assert(not vim.iter(notes):any(function(n) return n:find("poked", 1, true) end), vim.inspect(notes))
    eq(headless.session_id(root), nil) -- the session it was going to create does not exist
    headless.spawn = spawn
    ac.poke(root) -- not stuck as "still working"
    eq(#spawned, 1)
  end)

  case("a bad config.headless.args does not leave the run working", function()
    local root = project()
    local args = headless.args
    headless.args = function() error("args must be a list") end
    ac.poke(root)
    headless.args = args
    eq(headless.status(root).status, "failed")
    ac.poke(root)
    eq(#spawned, 1)
  end)

  case("a run killed by a signal is a failure, not done", function()
    local root = project()
    ac.poke(root)
    spawned[1].on_exit(0, "", 9)
    eq(headless.status(root).status, "failed")
    assert(headless.status(root).error:find("signal 9", 1, true), headless.status(root).error)
  end)

  case("a poke queued behind a run whose session was lost still runs", function()
    local root = project()
    ac.poke(root)
    spawned[1].on_exit(0, "")
    ac.poke(root) -- resumes the session
    ac.poke(root) -- queued
    spawned[2].on_exit(1, "No conversation found with session ID: x")
    eq(#spawned, 3) -- the retry in a new session
    spawned[3].on_exit(0, "")
    eq(#spawned, 4) -- then the queued poke
  end)

  case("a queued poke still runs when the retry in a new session cannot start", function()
    local root = project()
    ac.poke(root)
    spawned[1].on_exit(0, "")
    ac.poke(root) -- resumes the session
    ac.poke(root) -- queued
    local spawn, tries = headless.spawn, 0
    headless.spawn = function(...)
      tries = tries + 1
      if tries == 1 then
        error("ENOENT: claude") -- the retry fails to start
      end
      return spawn(...)
    end
    spawned[2].on_exit(1, "No conversation found with session ID: x")
    headless.spawn = spawn
    eq(tries, 2) -- the retry, then the queued poke
    eq(#spawned, 3)
    eq(headless.status(root).status, "working")
  end)

  case("a failed run is reported even when progress is off", function()
    ac.config.progress = false
    local root = project()
    ac.poke(root)
    spawned[1].on_exit(1, "auth expired")
    ac.config.progress = true
    assert(vim.iter(notes):any(function(n) return n:find("auth expired", 1, true) end), vim.inspect(notes))
  end)

  case("leaving Neovim stops the runs still working", function()
    local root = project()
    ac.poke(root)
    headless.stop_all()
    eq(spawned[1].killed, true)
  end)

  case("a poke while it works is queued and runs when the agent is done", function()
    local root = project()
    ac.poke(root)
    ac.poke(root)
    eq(#spawned, 1)
    spawned[1].on_exit(0, "")
    eq(#spawned, 2)
    assert(arg_after(spawned[2], "--resume"))
  end)

  case("a lost session starts a new one", function()
    local root = project()
    ac.poke(root)
    local first = arg_after(spawned[1], "--session-id")
    spawned[1].on_exit(0, "")
    ac.poke(root)
    spawned[2].on_exit(1, "No conversation found with session ID: " .. first)
    eq(#spawned, 3)
    local second = arg_after(spawned[3], "--session-id")
    assert(second and second ~= first)
    eq(headless.session_id(root), second)
  end)

  case("with herdr agents running, the picker offers the background agent too", function()
    local root = project()
    poke.available = function() return true end
    poke.run = function(args)
      return { code = 0, stdout = vim.json.encode({ result = { agents = {
        { pane_id = "w1:p1", agent_status = "idle", terminal_title_stripped = "Other" },
      } } }), stderr = "" }
    end
    local offered
    vim.ui.select = function(items, _, cb)
      offered = vim.tbl_map(function(a) return a.pane_id end, items)
      cb(items[#items])
    end
    ac.poke(root)
    eq(offered, { "w1:p1", poke.HEADLESS })
    eq(#spawned, 1)
    eq(poke.saved_target(root).pane_id, poke.HEADLESS)
    -- remembered: no picker next time
    spawned[1].on_exit(0, "")
    offered = nil
    ac.poke(root)
    eq(offered, nil)
    eq(#spawned, 2)
  end)

  case("<M-s> in the comment box saves the comment and sends it to the agent", function()
    local root = tmp_project({ ["f.lua"] = { "one", "two" } })
    vim.cmd.edit(root .. "/f.lua")
    ac.add(1, 1)
    api.nvim_buf_set_lines(0, 0, -1, false, { "why?" })
    feed("<M-s>")
    eq(store.read(root).threads[1].messages[1].body, "why?")
    eq(#spawned, 1)
    vim.cmd("silent! %bwipeout!")
  end)

  case("<M-s> on a new comment opens its thread to watch the reply", function()
    local root = tmp_project({ ["f.lua"] = { "one", "two" } })
    vim.cmd.edit(root .. "/f.lua")
    local code_win = api.nvim_get_current_win()
    ac.add(2, 2)
    api.nvim_buf_set_lines(0, 0, -1, false, { "explain" })
    feed("<M-s>")
    assert(api.nvim_get_current_win() ~= code_win, "thread window should be focused")
    assert(api.nvim_win_get_config(0).relative ~= "", "a float")
    vim.cmd("silent! %bwipeout!")
  end)

  case("open_after_send = false stays in the code", function()
    ac.config.open_after_send = false
    local root = tmp_project({ ["f.lua"] = { "one", "two" } })
    vim.cmd.edit(root .. "/f.lua")
    local code_win = api.nvim_get_current_win()
    ac.add(1, 1)
    api.nvim_buf_set_lines(0, 0, -1, false, { "explain" })
    feed("<M-s>")
    ac.config.open_after_send = true
    eq(api.nvim_get_current_win(), code_win)
    eq(#spawned, 1)
    vim.cmd("silent! %bwipeout!")
  end)

  case("with auto_poke on, <C-s> sends and <M-s> only saves; the toggle flips it", function()
    local root = tmp_project({ ["f.lua"] = { "one", "two", "three" } })
    vim.cmd.edit(root .. "/f.lua")
    ac.toggle_auto_poke()
    eq(ac.config.auto_poke, true)
    ac.add(1, 1)
    api.nvim_buf_set_lines(0, 0, -1, false, { "a" })
    feed("<C-s>")
    eq(#spawned, 1)
    vim.cmd("silent! only")
    vim.cmd.edit(root .. "/f.lua")
    spawned[1].on_exit(0, "")
    ac.add(2, 2)
    api.nvim_buf_set_lines(0, 0, -1, false, { "b" })
    feed("<M-s>")
    eq(#spawned, 1)
    eq(#store.read(root).threads, 2)
    ac.toggle_auto_poke()
    eq(ac.config.auto_poke, false)
    vim.cmd("silent! %bwipeout!")
  end)

  case("<C-s> only saves", function()
    local root = tmp_project({ ["f.lua"] = { "one", "two" } })
    vim.cmd.edit(root .. "/f.lua")
    ac.add(2, 2)
    api.nvim_buf_set_lines(0, 0, -1, false, { "and this?" })
    feed("<C-s>")
    eq(#store.read(root).threads, 1)
    eq(#spawned, 0)
    vim.cmd("silent! %bwipeout!")
  end)

  it("the last line of output counts even without a newline", function()
    local lines, done = {}, false
    saved.spawn({ "sh", "-c", "printf 'one\\ntwo'" }, vim.fn.getcwd(), function(l) lines[#lines + 1] = l end, function() done = true end)
    assert(vim.wait(2000, function() return done end))
    eq(lines, { "one", "two" })
  end)
end)
