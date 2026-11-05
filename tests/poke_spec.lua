local store = require("code-review.store")
local session = require("code-review.session")
local poke = require("code-review.poke")
local progress = require("code-review.progress")
progress.use_timer = false -- tests drive polling by hand
local ac = require("code-review")

local api = vim.api

local function feed(keys)
  api.nvim_feedkeys(api.nvim_replace_termcodes(keys, true, false, true), "x", false)
end

describe("poke", function()
  ac.setup({ notify = false })
  local calls, notes, picks, prompt_reply
  local agents = {
    { pane_id = "w1:p1", agent = "claude", agent_status = "idle", cwd = "/work/a", terminal_title_stripped = "Review PR" },
    { pane_id = "w1:p9", agent = "claude", agent_status = "working", cwd = "/work/b", terminal_title_stripped = "Other task" },
    { pane_id = "w1:p5", agent = "claude", agent_status = "idle", cwd = "/work/me", terminal_title_stripped = "This nvim" },
  }

  local saved = { run = poke.run, avail = poke.available, select = vim.ui.select, notify = vim.notify, own = vim.env.HERDR_PANE_ID }
  local function fake()
    calls, notes, picks = {}, {}, 0
    prompt_reply = { result = { ok = true } }
    vim.env.HERDR_PANE_ID = "w1:p5"
    poke.available = function() return true end
    poke.run = function(args)
      calls[#calls + 1] = args
      if args[3] == "list" then
        return { code = 0, stdout = vim.json.encode({ result = { agents = agents } }), stderr = "" }
      end
      return { code = 0, stdout = vim.json.encode(prompt_reply), stderr = "" }
    end
    vim.ui.select = function(items, _, cb)
      picks = picks + 1
      cb(items[1])
    end
    vim.notify = function(msg) notes[#notes + 1] = msg end
  end
  local function restore()
    progress.stop() -- close the status window a poke opened
    poke.run, poke.available, vim.ui.select, vim.notify = saved.run, saved.avail, saved.select, saved.notify
    vim.env.HERDR_PANE_ID = saved.own
    ac.config.auto_poke = false
  end
  local function prompts()
    return vim.tbl_filter(function(c) return c[3] == "prompt" end, calls)
  end

  local root = tmp_project({ ["f.lua"] = { "one", "two", "three" } })
  store.update(root, function(d) -- a comment waiting for the agent, so pokes have something to send
    return store.add_thread(d, { file = "f.lua", start = 1, ["end"] = 1, anchor = { text = { "one" } }, author = "user", body = "first?" })
  end)

  it("asks which agent once, leaves this pane out, then remembers", function()
    fake()
    ac.poke(root)
    eq(picks, 1)
    eq(#prompts(), 1)
    eq({ prompts()[1][1], prompts()[1][2], prompts()[1][4] }, { "herdr", "agent", "w1:p1" }) -- first agent, not w1:p5 (this pane)
    assert(prompts()[1][5]:find("code-review", 1, true), prompts()[1][5])
    eq(poke.saved_target(root).pane_id, "w1:p1")
    ac.poke(root)
    eq(picks, 1) -- not asked again
    eq(#prompts(), 2)
    restore()
  end)

  it("lets you choose again with pick", function()
    fake()
    ac.poke(root)
    ac.poke(root, { pick = true })
    eq(picks, 1) -- the saved target was still valid, but pick forces the picker once
    restore()
  end)

  it("hides the thread window while the picker is up, then brings it back", function()
    fake()
    local tid = store.read(root).threads[1].id
    vim.cmd.edit(root .. "/f.lua")
    local src = api.nvim_get_current_win()
    local function thread_wins()
      return vim.tbl_filter(function(w)
        return api.nvim_win_get_config(w).relative ~= "" and vim.bo[api.nvim_win_get_buf(w)].filetype == "markdown"
      end, api.nvim_list_wins())
    end
    ac.open_thread(root, tid)
    eq(#thread_wins(), 1)
    local during
    vim.ui.select = function(items, _, cb)
      picks = picks + 1
      during = #thread_wins()
      cb(items[1])
    end
    ac.poke(root, { pick = true })
    eq(picks, 1)
    eq(during, 0) -- not under the picker
    assert(vim.wait(500, function() return #thread_wins() == 1 end), "thread window did not come back")
    for _, w in ipairs(thread_wins()) do
      api.nvim_win_close(w, true)
    end
    api.nvim_set_current_win(src)
    restore()
  end)

  it("remembers an agent only once a poke to it went through", function()
    fake()
    os.remove(store.paths(root) .. "/poke-target.json") -- forget what earlier tests remembered
    prompt_reply = { error = { code = "pane_not_found", message = "no such pane" } }
    ac.poke(root)
    eq(picks, 1)
    eq(poke.saved_target(root), nil)
    assert(table.concat(notes, "\n"):find("poke pick", 1, true), vim.inspect(notes))
    prompt_reply = { result = { ok = true } }
    ac.poke(root)
    eq(picks, 2) -- asked again
    eq(poke.saved_target(root).pane_id, "w1:p1")
    restore()
  end)

  it("a failed agent list keeps the remembered agent instead of switching", function()
    fake()
    ac.poke(root, { pick = true }) -- remembers w1:p1
    local run = poke.run
    poke.run = function(args)
      calls[#calls + 1] = args
      return { code = 1, stdout = "", stderr = "socket closed" }
    end
    ac.poke(root)
    poke.run = run
    eq(poke.saved_target(root).pane_id, "w1:p1")
    eq(picks, 1)
    assert(table.concat(notes, "\n"):find("socket closed", 1, true), vim.inspect(notes))
    restore()
  end)

  it("output that is not JSON is not taken for a success", function()
    local res, err = poke.decode({ code = 0, stdout = "Usage: herdr <command>\n", stderr = "" })
    eq(res, nil)
    assert(err:find("Usage: herdr", 1, true), err)
    eq(poke.decode({ code = 0, stdout = "", stderr = "" }), {})
    res, err = poke.decode({ code = 124, signal = 15, stdout = "", stderr = "" })
    assert(err:find("did not answer", 1, true), err)
  end)

  it("asks again when the remembered agent is gone", function()
    fake()
    local gone = vim.deepcopy(agents)
    table.remove(gone, 1)
    local old = agents
    agents = gone
    ac.poke(root)
    agents = old
    assert(table.concat(notes, "\n"):find("is gone", 1, true), vim.inspect(notes))
    eq(poke.saved_target(root).pane_id, "w1:p9") -- the first one left
    restore()
  end)

  it("reports herdr errors instead of failing silently", function()
    fake()
    poke.saved_target(root) -- remembered from before
    prompt_reply = { error = { code = "agent_blocked", message = "waiting for permission" } }
    ac.poke(root, { pick = true })
    local text = table.concat(notes, "\n")
    assert(text:find("agent_blocked", 1, true) and text:find("waiting for permission", 1, true), text)
    restore()
  end)

  it("copies the prompt when herdr is not available", function()
    fake()
    poke.available = function() return false end
    ac.poke(root)
    eq(#calls, 0)
    assert(vim.fn.getreg('"'):find("code-review", 1, true))
    assert(table.concat(notes, "\n"):find("needs herdr", 1, true), vim.inspect(notes))
    restore()
  end)

  it("a PR review prompt names the PR so the agent passes --pr", function()
    local pr = tmp_project({})
    session.save(pr, { kind = "pr", owner = "acme", repo = "api", number = 12, files = {}, cache = pr .. "/c" })
    assert(ac.prompt_for(pr):find("--pr acme/api#12", 1, true))
  end)

  describe("from comments", function()
    vim.cmd.edit(root .. "/f.lua")

    it("does not poke after adding a comment by default", function()
      fake()
      ac.add(2, 2)
      api.nvim_buf_set_lines(0, 0, -1, false, { "why?" })
      feed("<C-s>")
      eq(#prompts(), 0)
      restore()
    end)

    it("pokes right after adding a comment when auto_poke is on", function()
      fake()
      ac.config.auto_poke = true
      vim.cmd.edit(root .. "/f.lua")
      ac.add(3, 3)
      api.nvim_buf_set_lines(0, 0, -1, false, { "and this?" })
      feed("<C-s>")
      eq(#prompts(), 1)
      restore()
    end)

    it("s in the thread window pokes the agent", function()
      fake()
      local id = store.read(root).threads[1].id
      vim.cmd.edit(root .. "/f.lua")
      ac.open_thread(root, id)
      feed("s")
      eq(#prompts(), 1)
      restore()
    end)
  end)
end)
