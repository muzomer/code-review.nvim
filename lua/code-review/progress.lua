-- Follow the agent after a poke: a small status window (working / done /
-- waiting for you) and an optional live view of its terminal output.
--
-- For a herdr agent everything comes from herdr, polled once a second while a
-- poke is being followed:  `herdr agent get <pane>`  for the state and
--                          `herdr agent read <pane>` for the terminal text.
-- For the background agent (headless.lua) both come from its process.
local store = require("code-review.store")
local poke = require("code-review.poke")

local api = vim.api
local uv = vim.uv or vim.loop

local M = {}

M.interval = 1000 -- ms between polls
M.use_timer = true -- tests drive `M.tick()` by hand
M.linger_ms = 6000 -- how long the "done" window stays
M.start_grace_ms = 8000 -- idle this long after a poke without ever working = nothing happened
M.timeout_ms = 20 * 60 * 1000 -- stop following after this long
M.output_lines = 20 -- height of the live output window

local state -- the poke being followed
local timer
local anim -- fast timer that only redraws the spinner while the agent works

M.FRAMES = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }
M.frame_ns = 120 * 1e6 -- one spinner frame (120 ms)
M.clock = function() -- replaceable in tests
  return uv.hrtime()
end

---The spinner frame for now.
function M.frame()
  return M.FRAMES[(math.floor(M.clock() / M.frame_ns) % #M.FRAMES) + 1]
end

---State text as shown now: a working state gets the spinner instead of ⟳.
local function animated(text, kind)
  if kind == "working" then
    return (text:gsub("^⟳", M.frame()))
  end
  return text
end
local status_win -- { buf, win }
local out_win -- { buf, win, pane_id }

local function notify(msg, level)
  vim.notify("code-review: " .. msg, level or vim.log.levels.INFO)
end

local function valid(w)
  return w and api.nvim_win_is_valid(w.win)
end

local function close(w)
  if valid(w) then
    pcall(api.nvim_win_close, w.win, true)
  end
end

-- Status window ---------------------------------------------------------------

local HL = {
  working = "CodeReviewProgressWorking",
  done = "CodeReviewProgressDone",
  blocked = "CodeReviewProgressBlocked",
}

function M.highlights()
  local function link(name, target)
    api.nvim_set_hl(0, name, { link = target, default = true })
  end
  link(HL.working, "DiagnosticInfo")
  link(HL.done, "DiagnosticOk")
  link(HL.blocked, "DiagnosticWarn")
end

local MIN_WIDTH = 44

---Is a PR review winbar on screen (which then shows the status instead of a float)?
local function winbar_visible()
  for _, w in ipairs(api.nvim_tabpage_list_wins(0)) do
    if (vim.wo[w].winbar or ""):find("code-review.diff", 1, true) then
      return true
    end
  end
  return false
end

---Should the status float be used? config.progress_float: true | false | "auto"
---("auto": only when no review winbar shows the status).
local function use_float()
  local mode = require("code-review").config.progress_float
  if mode == nil then
    mode = "auto"
  end
  return mode == true or (mode == "auto" and not winbar_visible())
end

local ns_status = api.nvim_create_namespace("code-review-progress")

---The float shows the agent's name as its title, like the thread and chat
---windows, so its body is the state alone: "<icon> <state> · <details>".
---@return string body, string? title
local function split_title(text, title)
  if title and title ~= "" then
    local i, j = text:find(" " .. title .. " · ", 1, true)
    if i then
      return text:sub(1, i) .. text:sub(j + 1), title
    end
  end
  return text, nil
end

---Write the body and color only the icon and the state word (the rest stays
---in the normal float colors, like the other windows).
local function fill_status(text, kind)
  local body = " " .. text
  api.nvim_buf_set_lines(status_win.buf, 0, -1, false, { body })
  api.nvim_buf_clear_namespace(status_win.buf, ns_status, 0, -1)
  local stop = body:find(" · ", 1, true) or (#body + 1)
  api.nvim_buf_set_extmark(status_win.buf, ns_status, 0, 1, { end_col = stop - 1, hl_group = HL[kind] })
  api.nvim_buf_set_extmark(status_win.buf, ns_status, 0, stop - 1, { end_col = #body, hl_group = "Comment" })
end

---@param kind "working"|"done"|"blocked"
---@param min_width? integer never go narrower than this, so the window does not jump around
---@param title? string the agent's name
---@return integer width
local function show_status(text, kind, min_width, title)
  vim.cmd("redrawstatus!") -- winbars and statuslines render the state text themselves
  if require("code-review").config.progress == false or not use_float() then
    close(status_win)
    status_win = nil
    return min_width or 0
  end
  M.highlights()
  local body, name = split_title(text, title)
  local width = math.min(math.max(vim.fn.strdisplaywidth(body) + 2, vim.fn.strdisplaywidth(name or "") + 4, min_width or 0, MIN_WIDTH), vim.o.columns - 4)
  local cfg = {
    relative = "editor", width = width, height = 1, row = 0, col = vim.o.columns - width - 2,
    title = name and (" " .. name .. " ") or "", title_pos = "left",
  }
  if not valid(status_win) then
    local buf = api.nvim_create_buf(false, true)
    vim.bo[buf].bufhidden = "wipe"
    cfg = vim.tbl_extend("force", cfg, { style = "minimal", border = "rounded", focusable = false, zindex = 60, noautocmd = true })
    status_win = { buf = buf, win = api.nvim_open_win(buf, false, cfg) }
  else
    api.nvim_win_set_config(status_win.win, cfg)
  end
  status_win.title = name
  fill_status(body, kind)
  return width
end

---Show a state of the followed poke; the window only ever grows while following.
local function stop_anim()
  if anim then
    anim:stop()
    if not anim:is_closing() then
      anim:close()
    end
    anim = nil
  end
end

---Is the spinner animating?
function M.animating()
  return anim ~= nil
end

---Re-render threads (float, inline cards) after the agent's state changed, so
---"is replying…" appears and goes away. Only on changes, never on every poll.
local function views_changed()
  vim.schedule(function()
    pcall(function()
      require("code-review").refresh_views()
    end)
  end)
end

---Is the followed agent working on thread `tid` (waiting at poke time, not
---answered since)?
function M.replying(tid)
  local st = state
  if not st or st.finished or st.kind ~= "working" or not st.baseline[tid] then
    return false
  end
  local ok, data = pcall(store.read, st.root)
  local t = ok and store.find(data, tid)
  return t ~= nil and #t.messages <= st.baseline[tid]
end

---Name of the agent being followed.
function M.agent_title()
  return state and state.title
end

local function present(st, text, kind)
  if st.kind ~= kind then
    views_changed()
  end
  st.text, st.kind = text, kind
  st.width = show_status(animated(text, kind), kind, st.width, st.title)
  if kind == "working" and text:find("^⟳") then
    if M.use_timer and not anim then
      anim = uv.new_timer()
      anim:start(M.frame_ns / 1e6, M.frame_ns / 1e6, vim.schedule_wrap(function()
        if not (state and state.kind == "working") then
          return stop_anim()
        end
        if valid(status_win) then
          fill_status((split_title(animated(state.text, state.kind), state.title)), state.kind)
        end
        pcall(vim.cmd, "redrawstatus")
      end))
    end
  else
    stop_anim()
  end
end

-- Counting -----------------------------------------------------------------------

---Threads that waited on the agent at poke time, and how many got an answer since.
local function counts(st)
  local ok, data = pcall(store.read, st.root)
  local total, answered = 0, 0
  for tid, n in pairs(st.baseline) do
    total = total + 1
    local t = ok and store.find(data, tid)
    if t and #t.messages > n then
      answered = answered + 1
    end
  end
  return answered, total
end

local function elapsed(st)
  return math.floor((uv.hrtime() - st.t0) / 1e9)
end

local function clock(secs)
  return string.format("%d:%02d", math.floor(secs / 60), secs % 60)
end

-- Live output -----------------------------------------------------------------------

---Plain text of a terminal snapshot: no colors, no frame lines, no blank runs.
---@return string[]
function M.clean(text)
  text = (text or ""):gsub("\27%[[%d;?]*[%a]", ""):gsub("\r", "")
  local out, blank = {}, false
  for line in (text .. "\n"):gmatch("(.-)\n") do
    line = line:gsub("%s+$", "")
    -- frame decoration: box-drawing characters (U+2500..U+257F = E2 94/95 xx) and
    -- nothing readable. Tolerates a rule that was cut in the middle of a character.
    local frame = not line:find("%w") and (line:find("\226\148", 1, true) or line:find("\226\149", 1, true)) ~= nil
    -- a border that carries a title ("───── my session ──") starts with a run of one rule character
    frame = frame or line:match("^%s*(\226[\148\149][\128-\191])%1%1%1%1") ~= nil
    if line == "" then
      if not blank and #out > 0 then
        out[#out + 1] = ""
      end
      blank = true
    elseif not frame then
      out[#out + 1] = line
      blank = false
    end
  end
  while out[#out] == "" do
    out[#out] = nil
  end
  return out
end

local function show_output(lines)
  local h = api.nvim_win_get_height(out_win.win)
  lines = vim.list_slice(lines, math.max(1, #lines - h + 1), #lines)
  if #lines == 0 then
    lines = { "(no output yet)" }
  end
  api.nvim_buf_set_lines(out_win.buf, 0, -1, false, lines)
  pcall(api.nvim_win_set_cursor, out_win.win, { #lines, 0 })
end

local function refresh_output()
  if not valid(out_win) then
    return
  end
  local pane = out_win.pane_id
  if pane == poke.HEADLESS then
    return show_output(require("code-review.headless").lines(out_win.root))
  end
  poke.run_async({ "herdr", "agent", "read", pane, "--lines", "80" }, function(res)
    if not valid(out_win) or out_win.pane_id ~= pane then
      return
    end
    show_output(M.clean(res and res.stdout or ""))
  end)
end

---Show or hide the live output of the agent being followed (or, when none is,
---the agent remembered for this review).
function M.toggle_output(root)
  if valid(out_win) then
    close(out_win)
    out_win = nil
    return
  end
  local pane, title
  if state then
    pane, title = state.pane_id, state.title
  else
    local saved = root and poke.saved_target(root)
    pane, title = saved and saved.pane_id, saved and saved.title
  end
  if not pane then
    return notify("no agent to show yet; poke one first (s / <leader>cp)", vim.log.levels.WARN)
  end
  local width = math.max(40, math.min(100, math.floor(vim.o.columns * 0.55)))
  local buf = api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  local win = api.nvim_open_win(buf, false, {
    relative = "editor",
    anchor = "SE",
    row = vim.o.lines - 2,
    col = vim.o.columns - 1,
    width = width,
    height = M.output_lines,
    style = "minimal",
    border = "rounded",
    title = " " .. (title or pane) .. " · live ",
    title_pos = "left",
    focusable = false,
    zindex = 55,
  })
  vim.wo[win].wrap = true
  vim.wo[win].linebreak = true
  out_win = { buf = buf, win = win, pane_id = pane, root = state and state.root or root }
  refresh_output()
end

-- Following ------------------------------------------------------------------------------

local function stop_timer()
  if timer then
    timer:stop()
    if not timer:is_closing() then
      timer:close()
    end
    timer = nil
  end
end

---Stop following: poll no more and close the windows.
function M.stop()
  stop_anim()
  stop_timer()
  if state then
    views_changed()
  end
  state = nil
  close(status_win)
  status_win = nil
  close(out_win)
  out_win = nil
  pcall(vim.cmd, "redrawstatus!")
end

local function finish(st, text, kind)
  stop_timer()
  stop_anim()
  st.finished = true
  views_changed()
  present(st, text, kind)
  refresh_output()
  vim.defer_fn(function()
    if state == st then -- not replaced by a newer poke
      close(status_win)
      status_win = nil
      state = nil
      pcall(vim.cmd, "redrawstatus!")
    end
  end, M.linger_ms)
end

---Has the agent finished a turn since the poke? Exact when herdr's counters
---were captured before the poke; otherwise (no baseline) we need to have seen
---it working first.
local function turn_finished(st, agent)
  local base = st.before
  if base and base.completion ~= nil or (base and base.state ~= nil) then
    return agent.completion_seq ~= nil and agent.completion_seq > (base.completion or 0)
  end
  return st.seen_working == true
end

---Apply one reading of the agent (`agent` = herdr's agent record).
local function apply(st, agent)
  local status = agent.agent_status
  local secs = elapsed(st)
  local answered, total = counts(st)
  local tally = total > 0 and string.format(" · %d/%d answered", answered, total) or ""
  st.status = status
  if status == "working" then
    st.seen_working = true
    st.blocked_notified = false
    present(st, string.format("⟳ %s · working %s%s", st.title, clock(secs), tally), "working")
  elseif status == "blocked" then
    present(st, string.format("⚠ %s · waiting for you (permission?) %s%s", st.title, clock(secs), tally), "blocked")
    if not st.blocked_notified then
      st.blocked_notified = true
      notify(st.title .. " is blocked and waiting for you", vim.log.levels.WARN)
    end
  elseif status == "idle" or status == "done" then
    if turn_finished(st, agent) then
      local text = string.format("✓ %s · done in %s%s", st.title, clock(secs), tally)
      notify(string.format("%s finished (%s)%s", st.title, clock(secs), tally))
      return finish(st, text, "done")
    elseif secs * 1000 >= M.start_grace_ms then
      local text = string.format("%s · did not start (still idle)%s", st.title, tally)
      notify(st.title .. " did not start working; is the prompt waiting in its input box?", vim.log.levels.WARN)
      return finish(st, text, "blocked")
    elseif st.seen_working then
      -- idle for a moment between two steps of the same turn: do not flicker
      present(st, string.format("⟳ %s · working %s%s", st.title, clock(secs), tally), "working")
    else
      present(st, string.format("… %s · sent, waiting to start", st.title), "working")
    end
  else
    present(st, string.format("… %s · %s", st.title, status or "unknown"), "working")
  end
  if elapsed(st) * 1000 > M.timeout_ms then
    notify("stopped following " .. st.title .. " (taking very long)", vim.log.levels.WARN)
    M.stop()
  end
end

---Poll the agent once. A poll that is still running makes the next one skip, so
---answers can never arrive out of order.
function M.tick()
  local st = state
  if not st or st.finished or st.inflight then
    return
  end
  if st.pane_id == poke.HEADLESS then
    local h = require("code-review.headless").status(st.root)
    if not h or h.status == "failed" then
      local err = h and h.error or "the run is gone"
      notify(st.title .. " failed: " .. err, vim.log.levels.ERROR)
      finish(st, string.format("✗ %s · failed", st.title), "blocked")
    else
      -- the same record herdr gives: a turn is complete when the process ended
      apply(st, { agent_status = h.status == "done" and "done" or "working", completion_seq = h.status == "done" and 1 or 0 })
    end
    return refresh_output()
  end
  st.inflight = true
  poke.run_async({ "herdr", "agent", "get", st.pane_id }, function(res)
    st.inflight = false
    if state ~= st or st.finished then
      return
    end
    local result, err = poke.decode(res)
    if not (result and result.agent) then
      st.errors = (st.errors or 0) + 1
      if st.errors >= 3 then
        notify("lost contact with herdr: " .. tostring(err or "no agent in the answer"), vim.log.levels.ERROR)
        return M.stop()
      end
      return
    end
    st.errors = 0
    apply(st, result.agent)
    refresh_output()
  end)
end

---Start following an agent that was just poked.
---@param target { pane_id: string, title: string }
---@param before? { state: integer?, completion: integer? } the agent's counters just before the poke
function M.start(root, target, before)
  local was_open = valid(out_win)
  M.stop()
  local baseline = {}
  local ok, data = pcall(store.read, root)
  for _, t in ipairs(ok and data.threads or {}) do
    if t.needs == "agent" then
      baseline[t.id] = #t.messages
    end
  end
  state = {
    root = root,
    pane_id = target.pane_id,
    title = target.title,
    t0 = uv.hrtime(),
    baseline = baseline,
    before = before or (target.pane_id == poke.HEADLESS and { completion = 0 } or nil),
  }
  present(state, string.format("… %s · sent", target.title), "working")
  if M.use_timer then
    timer = uv.new_timer()
    timer:start(300, M.interval, vim.schedule_wrap(M.tick))
    api.nvim_create_autocmd("VimLeavePre", { once = true, callback = stop_timer })
  end
  if was_open or require("code-review").config.progress_output then
    M.toggle_output(root)
  end
end

---For a statusline (e.g. lualine): the progress text while following, else "".
function M.statusline()
  return state and state.text and animated(state.text, state.kind) or ""
end

---The state being shown, for renderers: text and its highlight group.
---@return { text: string, hl: string }?
function M.current()
  if state and state.text then
    return { text = animated(state.text, state.kind), hl = HL[state.kind or "working"] }
  end
end

return M
