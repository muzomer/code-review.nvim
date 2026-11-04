local store = require("code-review.store")
local anchor = require("code-review.anchor")
local poke = require("code-review.poke")
local progress = require("code-review.progress")
local ac = require("code-review")

local api = vim.api
progress.use_timer = false

describe("progress", function()
  ac.setup({ notify = false })
  local agent_status, reads, notes, errors, state_seq, completion_seq
  local saved = { run = poke.run, avail = poke.available, select = vim.ui.select, notify = vim.notify, own = vim.env.HERDR_PANE_ID }

  local ESC = string.char(27)
  local TERMINAL = table.concat({
    ESC .. "[1mReading the PR" .. ESC .. "[0m",
    "╭────────────────────╮",
    "│                    │",
    "╰────────────────────╯",
    "",
    "",
    "● Ran 3 shell commands",
    "  replied in t_a",
  }, "\n")

  local function fake()
    ac.config.progress_float = true -- these tests check the float renderer explicitly
    agent_status, reads, notes, errors = "idle", 0, {}, 0
    state_seq, completion_seq = 10, 10 -- herdr's counters: every status change / every finished turn
    vim.env.HERDR_PANE_ID = "w1:p5"
    poke.available = function() return true end
    poke.run = function(args)
      local verb = args[3]
      if verb == "list" then
        return { code = 0, stdout = vim.json.encode({ result = { agents = { { pane_id = "w1:p1", agent_status = "idle", cwd = "/w", terminal_title_stripped = "Review PR" } } } }), stderr = "" }
      elseif verb == "get" then
        if errors > 0 then
          errors = errors - 1
          return { code = 1, stdout = "", stderr = "socket gone" }
        end
        return {
          code = 0,
          stdout = vim.json.encode({ result = { agent = { pane_id = "w1:p1", agent_status = agent_status, state_change_seq = state_seq, completion_seq = completion_seq } } }),
          stderr = "",
        }
      elseif verb == "read" then
        reads = reads + 1
        return { code = 0, stdout = TERMINAL, stderr = "" }
      end
      return { code = 0, stdout = vim.json.encode({ result = { ok = true } }), stderr = "" }
    end
    vim.ui.select = function(items, _, cb) cb(items[1]) end
    vim.notify = function(msg) notes[#notes + 1] = msg end
  end
  local function restore()
    ac.config.progress_float = "auto"
    progress.stop()
    poke.run, poke.available, vim.ui.select, vim.notify = saved.run, saved.avail, saved.select, saved.notify
    vim.env.HERDR_PANE_ID = saved.own
  end

  local function floats()
    return vim.tbl_filter(function(w)
      return api.nvim_win_get_config(w).relative == "editor"
    end, api.nvim_list_wins())
  end
  local function status_text()
    for _, w in ipairs(floats()) do
      if api.nvim_win_get_height(w) == 1 then
        return (api.nvim_buf_get_lines(api.nvim_win_get_buf(w), 0, -1, false)[1] or "")
      end
    end
  end

  -- like `it`, but windows and fakes are cleaned up even when the test fails
  local function case(name, fn)
    it(name, function()
      local ok, err = pcall(fn)
      restore()
      if not ok then
        error(err, 0)
      end
    end)
  end

  local root = tmp_project({ ["f.lua"] = { "one", "two" } })
  local function waiting_thread()
    return store.update(root, function(d)
      return store.add_thread(d, {
        file = "f.lua", start = 1, ["end"] = 1,
        anchor = anchor.capture({ "one", "two" }, 1, 1), author = "user", body = "check this",
      })
    end)
  end
  local function agent_replies(id)
    store.update(root, function(d) store.add_message(store.find(d, id), "agent", "looked, fine") end)
  end

  case("shows a status window right after the poke", function()
    fake()
    waiting_thread()
    ac.poke(root)
    assert(status_text():find("Review PR", 1, true) and status_text():find("sent", 1, true), tostring(status_text()))
    restore()
  end)

  case("follows working -> done and counts the answered threads", function()
    fake()
    progress.linger_ms = 0
    local id = waiting_thread()
    ac.poke(root)
    agent_status, state_seq, completion_seq = "working", 11, nil
    progress.tick()
    assert(status_text():find("working", 1, true), tostring(status_text()))
    assert(progress.statusline():find("working", 1, true))
    agent_replies(id)
    agent_status, state_seq, completion_seq = "idle", 12, 12
    progress.tick()
    local text = status_text()
    assert(text:find("done in", 1, true), tostring(text))
    assert(text:find("answered", 1, true), tostring(text))
    assert(table.concat(notes, "\n"):find("finished", 1, true), vim.inspect(notes))
    vim.wait(300, function() return status_text() == nil end)
    eq(status_text(), nil) -- the window goes away after lingering
    eq(progress.statusline(), "")
    restore()
  end)

  case("does not call a not-yet-started agent done", function()
    fake()
    waiting_thread()
    ac.poke(root)
    progress.tick() -- still idle: the prompt was just submitted
    assert(status_text():find("waiting to start", 1, true), tostring(status_text()))
    restore()
  end)

  case("says so when the agent never starts", function()
    fake()
    progress.linger_ms = 5000
    local grace = progress.start_grace_ms
    progress.start_grace_ms = 0
    waiting_thread()
    ac.poke(root)
    progress.tick()
    assert(status_text():find("did not start", 1, true), tostring(status_text()))
    progress.start_grace_ms = grace
    restore()
  end)

  case("warns when the agent is blocked waiting for the user", function()
    fake()
    waiting_thread()
    ac.poke(root)
    agent_status = "blocked"
    progress.tick()
    progress.tick()
    assert(status_text():find("waiting for you", 1, true), tostring(status_text()))
    local n = 0
    for _, m in ipairs(notes) do
      if m:find("blocked", 1, true) then n = n + 1 end
    end
    eq(n, 1) -- one notification, not one per poll
    restore()
  end)

  case("stops following when herdr stops answering", function()
    fake()
    waiting_thread()
    ac.poke(root)
    errors = 3
    progress.tick(); progress.tick(); progress.tick()
    eq(progress.statusline(), "")
    assert(table.concat(notes, "\n"):find("lost contact", 1, true), vim.inspect(notes))
    restore()
  end)

  case("cleans terminal text for the live view", function()
    eq(progress.clean(TERMINAL), { "Reading the PR", "", "● Ran 3 shell commands", "  replied in t_a" })
  end)

  case("a turn that ends between two polls still counts as done", function()
    fake()
    waiting_thread()
    ac.poke(root)
    agent_status, state_seq, completion_seq = "idle", 12, 12 -- started and finished unseen
    progress.tick()
    assert(status_text():find("done in", 1, true), tostring(status_text()))
  end)

  case("a brief idle in the middle of a turn is not 'done' and does not flicker", function()
    fake()
    waiting_thread()
    ac.poke(root)
    agent_status, state_seq, completion_seq = "working", 11, nil
    progress.tick()
    agent_status, state_seq, completion_seq = "idle", 12, nil -- between two tool calls: no turn completed
    progress.tick()
    local text = status_text()
    assert(text:find("working", 1, true) and not text:find("done", 1, true), tostring(text))
    assert(not text:find("waiting to start", 1, true), tostring(text))
    agent_status, state_seq, completion_seq = "idle", 13, 13 -- now the turn really ended
    progress.tick()
    assert(status_text():find("done in", 1, true), tostring(status_text()))
  end)

  case("a slow poll makes the next one wait, so answers never overtake each other", function()
    fake()
    waiting_thread()
    ac.poke(root)
    local pending, requests = nil, 0
    local run_async = poke.run_async
    poke.run_async = function(args, cb)
      if args[3] == "get" then
        requests = requests + 1
        pending = cb
      end
    end
    progress.tick()
    progress.tick() -- first one has not answered yet
    eq(requests, 1)
    agent_status, state_seq, completion_seq = "working", 11, nil
    pending(poke.run({ "herdr", "agent", "get", "w1:p1" }))
    progress.tick()
    eq(requests, 2) -- free again
    poke.run_async = run_async
  end)

  case("the status window never shrinks or moves while following", function()
    fake()
    waiting_thread()
    ac.poke(root)
    local function geometry()
      for _, w in ipairs(floats()) do
        if api.nvim_win_get_height(w) == 1 then
          local c = api.nvim_win_get_config(w)
          return { w = c.width, right = c.col + c.width }
        end
      end
    end
    agent_status, state_seq, completion_seq = "blocked", 11, nil
    progress.tick() -- the longest text
    local long = geometry()
    agent_status, state_seq, completion_seq = "working", 12, nil
    progress.tick() -- a shorter one
    local short = geometry()
    eq(short.w >= long.w, true)
    eq(short.right, long.right) -- stays glued to the same right edge
  end)

  case("drops rule lines even when herdr cut one in the middle of a character", function()
    local cut = string.rep("─", 20) .. "\239\191\189" -- ends in a replacement character
    eq(progress.clean("answer\n\n" .. cut .. "\n❯ next"), { "answer", "", "❯ next" })
  end)

  case("drops a titled border line such as Claude's input box", function()
    local titled = string.rep("─", 30) .. " Code-review.nvim review ─"
    eq(progress.clean("answer\n" .. titled .. "\n❯ next"), { "answer", "❯ next" })
  end)

  case("toggles a live output window with the cleaned terminal text", function()
    fake()
    waiting_thread()
    ac.poke(root)
    agent_status = "working"
    progress.toggle_output(root)
    local out
    for _, w in ipairs(floats()) do
      if api.nvim_win_get_height(w) > 1 then out = w end
    end
    assert(out, "output window expected")
    eq(api.nvim_win_get_config(out).focusable, false)
    local lines = api.nvim_buf_get_lines(api.nvim_win_get_buf(out), 0, -1, false)
    eq(lines[1], "Reading the PR")
    assert(not table.concat(lines, "\n"):find("\27", 1, true), "no escape codes")
    assert(not table.concat(lines, "\n"):find("╭", 1, true), "no frame lines")
    local before = reads
    progress.tick() -- refreshes while following
    assert(reads > before, "output should refresh on each poll")
    progress.toggle_output(root)
    eq(api.nvim_win_is_valid(out), false)
    restore()
  end)

  case("a new poke restarts the count", function()
    fake()
    local fresh = tmp_project({ ["f.lua"] = { "one", "two" } })
    local id = store.update(fresh, function(d)
      return store.add_thread(d, {
        file = "f.lua", start = 1, ["end"] = 1,
        anchor = anchor.capture({ "one", "two" }, 1, 1), author = "user", body = "check this",
      })
    end)
    ac.poke(fresh)
    store.update(fresh, function(d) store.add_message(store.find(d, id), "agent", "ok") end) -- answered: nothing waits any more
    ac.poke(fresh)
    agent_status = "working"
    progress.tick()
    assert(not status_text():find("answered", 1, true), tostring(status_text())) -- no thread was waiting at the second poke
    restore()
  end)
end)
