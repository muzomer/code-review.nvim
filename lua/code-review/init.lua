-- Neovim UI: signs + virtual text, thread float, reply input, quickfix list,
-- live refresh when an agent writes the store.
local store = require("code-review.store")
local anchor = require("code-review.anchor")
local session = require("code-review.session")

local uv = vim.uv or vim.loop
local api = vim.api

local M = {}

M.config = {
  keymaps = {
    add = "<leader>ca", -- normal: current line, visual: selection
    open = "<leader>cr", -- open thread under cursor (reply from there)
    edit = "<leader>ce", -- edit your last comment of the thread under the cursor
    poke = "<leader>cp", -- poke the agent to check your comments (needs herdr)
    output = "<leader>cP", -- show / hide the live output of the agent you poked
    resolve = "<leader>cx", -- toggle resolved
    list = "<leader>cl", -- open threads in the project -> quickfix
    list_all = "<leader>cL", -- including resolved
    next = "]r", -- next thread in buffer (takes a count)
    prev = "[r", -- previous thread in buffer
    description = "<leader>cd", -- PR review: show the PR description
    viewed = "<leader>cv", -- PR review: mark the file as viewed (skipped by ]f / [f) and move on
    inline = "<leader>ci", -- show / hide conversations inline under the code
    next_yours = "]u", -- next thread waiting for you (the agent replied)
    prev_yours = "[u", -- previous thread waiting for you
    help = "<leader>c?", -- show the keys
    layout = "<leader>cu", -- PR review: switch between split and unified diff
    recent = "<leader>cR", -- resume one of your recent PR reviews (no network)
    panel = "<leader>cc", -- switch threads between the float and the conversation panel
    find_file = "<leader>cg", -- pick a file of the PR (fzf-lua with preview, else vim.ui.select)
    find_thread = "<leader>ct", -- pick a thread
    next_file = "]f", -- PR review: next changed file
    prev_file = "[f", -- PR review: previous changed file
  },
  show_resolved = false,
  inline_threads = false, -- show whole conversations under the commented lines (toggle: keymaps.inline)
  inline_max_lines = 12, -- longest inline conversation before it is cut ("open the thread for more")
  notify = true, -- notify when an agent replies
  conversation = "float", -- open threads in a "float" (default) or a docked chat "panel" with an input box
  panel_width = nil, -- width of the conversation panel (default: ~35% of the screen, 40..70)
  mouse = true, -- click a thread's sign to open it; click a file in the file list to open it
  notify_group_ms = 1500, -- replies arriving within this window become one notification
  flash_ms = 350, -- briefly highlight where a jump lands (0 / false: off)
  progress = true, -- after a poke, show the agent's state (working / done / waiting)
  progress_float = "auto", -- where: true = floating window, false = winbar/statusline only, "auto" = float only outside a PR review
  progress_output = false, -- ... and also open the live output window right away
  auto_poke = false, -- poke the review agent (herdr) right after you add, reply or edit a comment
  icons = "auto", -- file-type icons in the file list: "auto" (when nvim-web-devicons is installed), true, false
  diff_layout = "split", -- PR diff: "split" (side by side) or "unified" (one column, like GitHub)
  sidebar_position = "left", -- PR review file list: "left", "right", "bottom" or "top"
  sidebar_width = nil, -- width when left/right (default: a quarter of the screen, 24..42 columns)
  sidebar_height = nil, -- height when bottom/top (default: 30% of the screen, 6..15 lines)
  diff_colors = true, -- PR diff palette: true/"auto" = from your colorscheme, "github-dark" = GitHub Dark Default, false = Neovim's own
  add_bin_to_path = true, -- so agents started from inside Neovim find the CLI
  signs = { user = "▍", agent = "◆", resolved = "✓", outdated = "?" },
}

local ns = api.nvim_create_namespace("code-review")
local ns_mirror = api.nvim_create_namespace("code-review-mirror") -- blank lines that keep diff panes aligned
local inline_on -- runtime toggle; nil = config.inline_threads
local ns_flash = api.nvim_create_namespace("code-review-flash")

---Briefly highlight `row` (default: cursor row) of `win`, so the eye finds where
---a jump landed.
function M.flash(win, row)
  local ms = M.config.flash_ms
  if not ms or ms <= 0 then
    return
  end
  win = (win and win ~= 0) and win or api.nvim_get_current_win()
  if not api.nvim_win_is_valid(win) then
    return
  end
  local buf = api.nvim_win_get_buf(win)
  row = row or api.nvim_win_get_cursor(win)[1]
  api.nvim_buf_clear_namespace(buf, ns_flash, 0, -1)
  pcall(api.nvim_buf_set_extmark, buf, ns_flash, row - 1, 0, { line_hl_group = "CodeReviewFlash", priority = 300 })
  vim.defer_fn(function()
    if api.nvim_buf_is_valid(buf) then
      api.nvim_buf_clear_namespace(buf, ns_flash, 0, -1)
    end
  end, ms)
end

-- Replies are announced together: each `code-review reply` is its own process
-- and its own file event, so they are collected for a moment first.
local pending_notes, note_timer = {}, nil

---Announce the collected replies now (one notification).
function M.flush_notifications()
  if note_timer then
    note_timer:stop()
    if not note_timer:is_closing() then
      note_timer:close()
    end
    note_timer = nil
  end
  if #pending_notes == 0 then
    return
  end
  local notes = pending_notes
  pending_notes = {}
  if #notes == 1 then
    local n = notes[1]
    return vim.notify(string.format("code-review: %s on %s:%d: %s", n.author, n.file, n.line, n.text))
  end
  local authors, where = {}, {}
  for _, n in ipairs(notes) do
    authors[n.author] = true
    where[#where + 1] = string.format("%s:%d", n.file:match("[^/]+$"), n.line)
  end
  local who = vim.tbl_keys(authors)
  table.sort(who)
  vim.notify(string.format("code-review: %s replied to %d threads: %s", table.concat(who, ", "), #notes, table.concat(where, ", ")))
end

local function queue_notification(n)
  pending_notes[#pending_notes + 1] = n
  if note_timer then
    note_timer:stop()
  else
    note_timer = (vim.uv or vim.loop).new_timer()
  end
  note_timer:start(M.config.notify_group_ms or 1500, 0, vim.schedule_wrap(M.flush_notifications))
end
local group = api.nvim_create_augroup("code-review", { clear = true })
local did_setup = false
local marks = {} -- buf -> { [extmark id] = thread id }
local watchers = {} -- root -> { handle, timer }
local seen = {} -- root -> { [thread id] = message count }
local float -- { buf, win, root, tid }

local function notify(msg, level)
  vim.notify("code-review: " .. msg, level or vim.log.levels.INFO)
end

local function buf_info(buf)
  if not api.nvim_buf_is_valid(buf) then
    return nil
  end
  -- a unified PR view shows both sides of one file
  local u = vim.b[buf].code_review_unified
  if u then
    return u.root, u.file, "both", true
  end
  if vim.bo[buf].buftype ~= "" then
    return nil
  end
  local name = api.nvim_buf_get_name(buf)
  if name == "" then
    return nil
  end
  name = vim.fs.normalize(vim.fn.fnamemodify(name, ":p"))
  -- A PR snapshot: the session, file and side are encoded in its path.
  local sroot, sfile, sside = session.infer(name)
  if sroot then
    return sroot, sfile, sside, true
  end
  -- Outside a repo, match the CLI (which falls back to its cwd): use Neovim's
  -- cwd when the file is under it.
  local cwd = vim.fs.normalize(vim.fn.getcwd())
  local root = store.find_root(vim.fs.dirname(name), store.relpath(cwd, name) and cwd or nil)
  local rel = store.relpath(root, name)
  if rel then
    return root, rel
  end
end

local function safe_read(root)
  local ok, data = pcall(store.read, root)
  if not ok then
    notify(data, vim.log.levels.ERROR)
    return nil
  end
  return data
end

local function threads_for(data, rel, side)
  local res = {}
  for _, t in ipairs(data.threads) do
    if t.file == rel and (side == "both" or (t.side or "new") == (side or "new")) then
      res[#res + 1] = t
    end
  end
  return res
end

-- Times ---------------------------------------------------------------------------

M.now = os.time -- replaceable in tests

---Seconds since the epoch of a stored UTC timestamp ("2026-11-04T09:12:33Z"), or nil.
function M.parse_utc(ts)
  local y, mo, d, h, mi, s = tostring(ts or ""):match("^(%d+)%-(%d+)%-(%d+)T(%d+):(%d+):(%d+)Z$")
  if not y then
    return nil
  end
  -- os.time() reads a table as local time: add the local offset back
  local t = os.time({ year = tonumber(y), month = tonumber(mo), day = tonumber(d), hour = tonumber(h), min = tonumber(mi), sec = tonumber(s), isdst = false })
  local now = os.time()
  local offset = os.difftime(now, os.time(os.date("!*t", now) --[[@as osdateparam]]))
  return t + offset
end

---"just now", "5 min ago", "3 h ago", "2 d ago", else the date. Text that is not
---a stored timestamp is returned as it is.
function M.reltime(ts)
  local t = M.parse_utc(ts)
  if not t then
    return ts
  end
  local d = math.max(0, M.now() - t)
  if d < 60 then
    return "just now"
  elseif d < 3600 then
    return string.format("%d min ago", math.floor(d / 60))
  elseif d < 86400 then
    return string.format("%d h ago", math.floor(d / 3600))
  elseif d < 7 * 86400 then
    return string.format("%d d ago", math.floor(d / 86400))
  end
  return os.date("%Y-%m-%d", t)
end

local function first_line(s)
  return (s:match("^[^\n]*"))
end

local function style(t)
  local s = M.config.signs
  if t.status == "resolved" then
    return s.resolved, "CodeReviewDim", "CodeReviewDim"
  elseif t.status == "outdated" then
    return s.outdated, "CodeReviewDim", "CodeReviewDim"
  end
  local sign = store.is_agent_thread(t) and s.agent or s.user
  local sign_hl = store.is_agent_thread(t) and "CodeReviewAgent"
    or (t.needs == "user" and "CodeReviewNeedsUser" or "CodeReviewNeedsAgent")
  local virt_hl = t.needs == "user" and "CodeReviewNeedsUser" or "CodeReviewVirt"
  return sign, sign_hl, virt_hl
end

-- Inline conversations ---------------------------------------------------------

local function inline_enabled()
  if inline_on ~= nil then
    return inline_on
  end
  return M.config.inline_threads == true
end

---Word-wrap `text` (may hold newlines) to `width` display cells.
local function wrap(text, width)
  local out = {}
  for _, para in ipairs(vim.split(text, "\n", { plain = true })) do
    local line = ""
    for word in para:gmatch("%S+") do
      if line == "" then
        line = word
      elseif vim.fn.strdisplaywidth(line .. " " .. word) <= width then
        line = line .. " " .. word
      else
        out[#out + 1] = line
        line = word
      end
    end
    out[#out + 1] = line
  end
  return out
end

---Text width of the window showing `buf` (virt_lines do not wrap by themselves).
local function text_width(buf)
  local win = vim.fn.bufwinid(buf)
  if win == -1 then
    return 76
  end
  local info = vim.fn.getwininfo(win)[1]
  return math.max(24, api.nvim_win_get_width(win) - (info and info.textoff or 0) - 2)
end

---Cut `text` to at most `width` display cells.
local function fit(text, width)
  if vim.fn.strdisplaywidth(text) <= width then
    return text
  end
  return vim.fn.strcharpart(text, 0, math.max(1, width - 1)) .. "…"
end

---The conversation of `t` as virt_lines, framed and wrapped.
function M.inline_lines(t, width)
  local hl = t.needs == "user" and "CodeReviewNeedsUser" or "CodeReviewVirt"
  local lines = {
    { { fit(string.format("╭ %s · %s · %s", t.id, t.status == "resolved" and "resolved" or ("needs " .. (t.needs == "user" and "you" or t.needs)), M.reltime(t.messages[#t.messages].ts))
      .. ((package.loaded["code-review.progress"] and package.loaded["code-review.progress"].replying(t.id)) and " · agent replying…" or ""), width), hl } },
  }
  local used = 0
  for _, m in ipairs(t.messages) do
    local who = m.author == "user" and "you" or m.author
    local body = wrap(m.body, math.max(10, width - vim.fn.strdisplaywidth(who) - 4))
    for i, l in ipairs(body) do
      used = used + 1
      if used > M.config.inline_max_lines then
        lines[#lines + 1] = { { fit("│ … more in the thread (" .. ((M.config.keymaps or {}).open or "<leader>cr") .. ")", width), hl } }
        lines[#lines + 1] = { { "╰", hl } }
        return lines
      end
      local prefix = i == 1 and (who .. ": ") or string.rep(" ", vim.fn.strdisplaywidth(who) + 2)
      lines[#lines + 1] = {
        { "│ ", hl },
        { prefix, m.author == "user" and "CodeReviewAuthorYou" or "CodeReviewAuthorAgent" },
        { l, "CodeReviewVirt" },
      }
    end
  end
  lines[#lines + 1] = { { "╰", hl } }
  return lines
end

local function loaded_buf(path)
  local b = path and vim.fn.bufnr(path) or -1
  return b ~= -1 and api.nvim_buf_is_loaded(b) and b or nil
end

local hunks = require("code-review.hunks")
local map_line = hunks.map_line
M._map_line = map_line

---Inline conversations push one diff pane down; give the other pane as many
---blank lines at the matching line, so both stay aligned.
function M.mirror(root, file)
  local ob = loaded_buf(session.snapshot_path(root, file, "old"))
  local nb = loaded_buf(session.snapshot_path(root, file, "new"))
  if not (ob and nb) then
    return
  end
  api.nvim_buf_clear_namespace(ob, ns_mirror, 0, -1)
  api.nvim_buf_clear_namespace(nb, ns_mirror, 0, -1)
  if not inline_enabled() then
    return -- nothing inline, nothing to mirror (and no diff to compute)
  end
  local ol, nl = api.nvim_buf_get_lines(ob, 0, -1, false), api.nvim_buf_get_lines(nb, 0, -1, false)
  local h = hunks.indices(ol, nl)
  for _, pair in ipairs({ { ob, nb, true }, { nb, ob, false } }) do
    local from, to, from_old = pair[1], pair[2], pair[3]
    local n_to = api.nvim_buf_line_count(to)
    for _, m in ipairs(api.nvim_buf_get_extmarks(from, ns, 0, -1, { details = true })) do
      local vl = m[4].virt_lines
      if vl and #vl > 0 then
        local row = math.max(1, math.min(map_line(h, m[2] + 1, from_old), n_to)) - 1
        local blank = {}
        for i = 1, #vl do
          blank[i] = { { "", "" } }
        end
        api.nvim_buf_set_extmark(to, ns_mirror, row, 0, { virt_lines = blank })
      end
    end
  end
end

-- Rendering -------------------------------------------------------------------

local lost = {} -- buf -> { [thread id] = true } code deleted, not yet saved

local function try_update(root, fn)
  local ok, err = pcall(store.update, root, fn)
  if not ok then
    notify(err, vim.log.levels.ERROR)
  end
end

---Where the extmarks say each tracked thread is now (1-based), or false when
---its code was deleted. Reflects unsaved edits.
local function live_positions(buf)
  local pos = {}
  for _, tid in pairs(marks[buf] or {}) do
    pos[tid] = false -- a mark that vanished counts as deleted code
  end
  for _, m in ipairs(api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })) do
    local tid = marks[buf] and marks[buf][m[1]]
    if tid and not m[4].invalid then
      pos[tid] = { m[2] + 1, m[4].end_row + 1 }
    end
  end
  for tid in pairs(lost[buf] or {}) do
    pos[tid] = false
  end
  return pos
end

---@param reanchor? boolean relocate threads against buffer text first
function M.render(buf, reanchor)
  local root, rel, side, snapshot = buf_info(buf)
  if not root then
    return
  end
  if snapshot then
    vim.bo[buf].modifiable = false -- snapshots are read-only views of the PR
    if not vim.b[buf].code_review_keys then
      vim.b[buf].code_review_keys = true
      local km = M.config.keymaps or {}
      local function map(lhs, dir, desc)
        if lhs then
          vim.keymap.set("n", lhs, function() require("code-review.diff").step(dir) end, { buffer = buf, desc = desc })
        end
      end
      map(km.next_file, 1, "Code review: next PR file")
      map(km.prev_file, -1, "Code review: previous PR file")
    end
  end
  M.watch(root)
  local data = safe_read(root)
  if not data then
    return
  end
  local threads = threads_for(data, rel, side)
  if side == "both" and require("code-review.unified").is_since(buf) then
    -- the old column is your last review, not the PR base: base-side threads do not belong
    threads = vim.tbl_filter(function(t) return t.side ~= "old" end, threads)
  end
  if reanchor and side ~= "both" and #threads > 0 then
    local lines = api.nvim_buf_get_lines(buf, 0, -1, false)
    if anchor.reanchor_threads(vim.deepcopy(threads), lines) then
      try_update(root, function(d)
        if not anchor.reanchor_threads(threads_for(d, rel, side), lines) then
          return store.UNCHANGED
        end
      end)
      data = safe_read(root) or data
      threads = threads_for(data, rel, side)
    end
  end

  -- With unsaved edits the stored ranges are stale; keep where the marks went.
  local live = (not reanchor and vim.bo[buf].modified) and live_positions(buf) or {}
  api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  marks[buf], lost[buf] = {}, {}
  local n = api.nvim_buf_line_count(buf)
  for _, t in ipairs(threads) do
    local p = live[t.id]
    if p == false then
      lost[buf][t.id] = true
    elseif t.status ~= "resolved" or M.config.show_resolved then
      local r = p or { t.range.start, t.range["end"] }
      if side == "both" and not p then -- unified view: the thread's side and line → buffer row
        local u, ts = require("code-review.unified"), t.side or "new"
        local first = u.row_of(buf, ts, t.range.start) or 1
        r = { first, u.row_of(buf, ts, t.range["end"]) or first }
      end
      local s = math.max(1, math.min(r[1], n)) - 1
      local e = math.max(s + 1, math.min(r[2], n)) - 1
      local sign, sign_hl, virt_hl = style(t)
      local last = t.messages[#t.messages]
      local label = string.format(" %s: %s", last.author, first_line(last.body))
      if #t.messages > 1 then
        label = label .. string.format("  (%d)", #t.messages)
      end
      -- the end-of-line label: finished and stale threads stay small
      local chunks = { { "  " .. sign .. label, virt_hl } }
      if t.status == "resolved" then
        chunks = { { string.format("  %s resolved%s", sign, #t.messages > 1 and string.format(" · %d messages", #t.messages) or ""), virt_hl } }
      elseif t.status == "outdated" then
        local gone = vim.trim(((t.anchor or {}).text or {})[1] or "")
        chunks = { { "  " .. sign .. " outdated · ", virt_hl } }
        if gone ~= "" then
          chunks[#chunks + 1] = { gone, "CodeReviewOutdated" } -- the code it was about, struck through
        end
        chunks[#chunks + 1] = { label, virt_hl }
      end
      local end_line = api.nvim_buf_get_lines(buf, e, e + 1, false)[1] or ""
      local inline = inline_enabled() and t.status ~= "resolved"
      local id = api.nvim_buf_set_extmark(buf, ns, s, 0, {
        end_row = e,
        end_col = #end_line,
        sign_text = sign,
        sign_hl_group = sign_hl,
        virt_text = not inline and chunks or nil,
        virt_text_pos = not inline and "eol" or nil,
        invalidate = true,
        priority = 20,
      })
      marks[buf][id] = t.id
      if inline then
        -- the conversation goes under the last commented line
        api.nvim_buf_set_extmark(buf, ns, e, 0, { virt_lines = M.inline_lines(t, text_width(buf)), priority = 20 })
      end
      for row = s + 1, e do
        api.nvim_buf_set_extmark(buf, ns, row, 0, { sign_text = "│", sign_hl_group = sign_hl, priority = 19 })
      end
    end
  end
  if snapshot and side ~= "both" then
    M.mirror(root, rel)
  end
  if next(marks[buf]) then
    M.map_mouse(buf)
  end
end

---Are conversations shown inline right now?
function M.inline_enabled()
  return inline_enabled()
end

---Which thread a mouse click hits: only clicks in the gutter (signs/numbers) of a
---line that has a thread count. `pos` is vim.fn.getmousepos().
---@return string? root, string? tid
function M.mouse_thread(pos)
  if not pos or (pos.winid or 0) == 0 or not api.nvim_win_is_valid(pos.winid) then
    return nil
  end
  local info = vim.fn.getwininfo(pos.winid)[1]
  if not info or pos.wincol > info.textoff or (pos.line or 0) < 1 then
    return nil -- a click in the text itself: leave it alone
  end
  local buf = api.nvim_win_get_buf(pos.winid)
  local row = pos.line - 1
  for _, m in ipairs(api.nvim_buf_get_extmarks(buf, ns, { row, 0 }, { row, -1 }, { details = true, overlap = true })) do
    local tid = marks[buf] and marks[buf][m[1]]
    if tid then
      return (buf_info(buf)), tid
    end
  end
end

function M.map_mouse(buf)
  if not M.config.mouse or vim.b[buf].code_review_mouse then
    return
  end
  vim.b[buf].code_review_mouse = true
  vim.keymap.set("n", "<LeftMouse>", function()
    local r, tid = M.mouse_thread(vim.fn.getmousepos())
    if tid then
      vim.schedule(function()
        M.open_thread(r, tid)
      end)
    end
    return "<LeftMouse>" -- the click itself still happens
  end, { buffer = buf, expr = true, desc = "Code review: click a thread sign to open it" })
end

---Show or hide whole conversations under the code.
function M.toggle_inline()
  inline_on = not inline_enabled()
  for _, b in ipairs(api.nvim_list_bufs()) do
    if api.nvim_buf_is_loaded(b) then
      M.render(b)
    end
  end
  notify(inline_on and "conversations shown inline" or "inline conversations hidden")
end


local function render_root(root)
  for _, buf in ipairs(api.nvim_list_bufs()) do
    if api.nvim_buf_is_loaded(buf) then
      local r = buf_info(buf)
      if r == root then
        M.render(buf)
      end
    end
  end
end

-- After a save, extmarks know where the commented code went: persist that.
function M.sync_from_marks(buf)
  local root, rel, side = buf_info(buf)
  local pos = root and live_positions(buf) or {}
  if not next(pos) then
    return
  end
  local lines = api.nvim_buf_get_lines(buf, 0, -1, false)
  try_update(root, function(data)
    local changed = false
    for _, t in ipairs(data.threads) do
      local p = pos[t.id]
      if t.file == rel and (t.side or "new") == (side or "new") and p ~= nil and t.status ~= "outdated" then
        if p == false then
          if t.status == "open" then
            t.status = "outdated"
            changed = true
          end
        else
          local a = anchor.capture(lines, p[1], p[2])
          if p[1] ~= t.range.start or p[2] ~= t.range["end"] or not vim.deep_equal(a, t.anchor) then
            t.range = { start = p[1], ["end"] = p[2] }
            t.anchor = a
            changed = true
          end
        end
      end
    end
    if not changed then
      return store.UNCHANGED
    end
  end)
end

-- Watching the store ----------------------------------------------------------

local function on_store_changed(root)
  local data = safe_read(root)
  if not data then
    return
  end
  local prev, now = seen[root], {}
  for _, t in ipairs(data.threads) do
    now[t.id] = #t.messages
    local last = t.messages[#t.messages]
    if M.config.notify and prev and last and last.author ~= "user" and (prev[t.id] or 0) < #t.messages then
      queue_notification({ author = last.author, file = t.file, line = t.range.start, text = first_line(last.body) })
    end
  end
  seen[root] = now
  render_root(root)
  pcall(require("code-review.sidebar").refresh_all) -- thread counts per file
  if float and float.root == root and api.nvim_win_is_valid(float.win) then
    M.open_thread(root, float.tid, true)
  end
  local panel = package.loaded["code-review.panel"]
  if panel and panel.current() == root then
    panel.render()
  end
end

function M.watch(root)
  if watchers[root] then
    return
  end
  local dir = store.paths(root)
  if vim.fn.isdirectory(dir) == 0 then
    return
  end
  local data = safe_read(root)
  seen[root] = {}
  for _, t in ipairs(data and data.threads or {}) do
    seen[root][t.id] = #t.messages
  end
  local handle, timer = uv.new_fs_event(), uv.new_timer()
  handle:start(dir, {}, function(err, fname)
    if err or (fname and fname ~= store.FILE) then
      return
    end
    timer:stop()
    timer:start(80, 0, vim.schedule_wrap(function()
      on_store_changed(root)
    end))
  end)
  watchers[root] = { handle = handle, timer = timer }
end

-- Floats ------------------------------------------------------------------------

---@param initial? string text to start from (editing)
local function input(title, on_submit, initial)
  local buf = api.nvim_create_buf(false, true)
  vim.bo[buf].filetype = "markdown"
  vim.bo[buf].bufhidden = "wipe"
  if initial then
    api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(initial, "\n", { plain = true }))
  end
  local width = math.min(80, vim.o.columns - 4)
  local height = 8
  -- Right under the commented line, so the code stays visible; above it when
  -- there is no room below.
  local below = vim.fn.winline() + height + 2 <= api.nvim_win_get_height(0)
  local win = api.nvim_open_win(buf, true, {
    relative = "cursor",
    width = width,
    height = height,
    row = below and 1 or -(height + 2),
    col = 0,
    border = "rounded",
    title = " " .. title .. " ",
    footer = " <C-s> / <CR> submit · q cancel ",
    footer_pos = "right",
  })
  if initial then
    local n = api.nvim_buf_line_count(buf)
    api.nvim_win_set_cursor(win, { n, #api.nvim_buf_get_lines(buf, n - 1, n, false)[1] })
  end
  vim.cmd.startinsert({ bang = initial ~= nil })
  local function close()
    if api.nvim_win_is_valid(win) then
      api.nvim_win_close(win, true)
    end
    vim.cmd.stopinsert()
  end
  local function submit()
    local text = vim.trim(table.concat(api.nvim_buf_get_lines(buf, 0, -1, false), "\n"))
    close()
    if text ~= "" then
      on_submit(text)
    end
  end
  local o = { buffer = buf, nowait = true }
  vim.keymap.set({ "n", "i" }, "<C-s>", submit, o)
  vim.keymap.set("n", "<CR>", submit, o)
  vim.keymap.set("n", "q", close, o)
  -- <Esc> only closes an empty draft, so a habitual double <Esc> loses nothing.
  vim.keymap.set("n", "<Esc>", function()
    if vim.trim(table.concat(api.nvim_buf_get_lines(buf, 0, -1, false), "\n")) == "" then
      close()
    end
  end, o)
end

-- A fence longer than any backtick run inside `lines`, so code containing
-- ``` cannot close it early.
local function fence_for(lines)
  local longest = 0
  for _, l in ipairs(lines) do
    for run in l:gmatch("`+") do
      longest = math.max(longest, #run)
    end
  end
  return string.rep("`", math.max(3, longest + 1))
end

---The thread as a markdown document (rendered with filetype=markdown).
---Turn ```suggestion blocks (GitHub's convention: the lines that should replace
---the commented ones) into a ```diff of the commented code against them.
---Other code blocks, and a suggestion block left open, stay as they are.
function M.expand_suggestions(body, anchor_lines)
  local lines = vim.split(body, "\n", { plain = true })
  local out, i = {}, 1
  while i <= #lines do
    local open = lines[i]:match("^%s*(```+)suggestion%s*$")
    local close
    if open then
      for j = i + 1, #lines do
        if lines[j]:match("^%s*" .. open .. "%s*$") then
          close = j
          break
        end
      end
    end
    if close then
      out[#out + 1] = open .. "diff"
      for _, l in ipairs(anchor_lines or {}) do
        out[#out + 1] = "- " .. l
      end
      for j = i + 1, close - 1 do
        out[#out + 1] = "+ " .. lines[j]
      end
      out[#out + 1] = open
      i = close + 1
    else
      out[#out + 1] = lines[i]
      i = i + 1
    end
  end
  return table.concat(out, "\n")
end

function M.thread_markdown(t)
  local r = t.range
  local loc = r.start == r["end"] and tostring(r.start) or (r.start .. "-" .. r["end"])
  local lines = {
    string.format("`%s:%s` · %s · needs %s", t.file, loc, t.status, t.needs),
    "",
  }
  local code = (t.anchor or {}).text or {}
  if #code > 0 then
    local fence = fence_for(code)
    lines[#lines + 1] = fence .. (vim.filetype.match({ filename = t.file }) or "")
    vim.list_extend(lines, code)
    lines[#lines + 1] = fence
  end
  for i, m in ipairs(t.messages) do
    if i > 1 then
      vim.list_extend(lines, { "", "---" })
    end
    local who = m.author == "user" and "**you**" or ("**" .. m.author .. "** (agent)")
    vim.list_extend(lines, { "", who .. " · " .. M.reltime(m.ts) .. (m.edited and " · edited" or ""), "" })
    local body = vim.split(M.expand_suggestions(m.body, (t.anchor or {}).text), "\n")
    vim.list_extend(lines, body)
    -- Close a fence the author left open, so it can't swallow later messages.
    local open
    for _, l in ipairs(body) do
      local f = l:match("^%s*(```+)")
      if f then
        open = (open == nil) and f or nil
      end
    end
    if open then
      lines[#lines + 1] = open
    end
  end
  local progress = package.loaded["code-review.progress"]
  if progress and progress.replying(t.id) then
    vim.list_extend(lines, { "", "---", "", string.format("_%s is replying…_", progress.agent_title() or "the agent") })
  end
  return lines
end

---Color who said what in a rendered thread.
function M.color_authors(buf, lines)
  api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  for i, l in ipairs(lines) do
    local who = l:match("^(%*%*you%*%*)") or l:match("^(%*%*[^*]+%*%* %(agent%))")
    if who then
      api.nvim_buf_set_extmark(buf, ns, i - 1, 0, {
        end_col = #who,
        hl_group = who == "**you**" and "CodeReviewAuthorYou" or "CodeReviewAuthorAgent",
        priority = 200,
      })
    end
  end
end

---Threads in a float or in the docked panel (config.conversation); switch.
function M.toggle_conversation()
  local panel = require("code-review.panel")
  if M.config.conversation == "panel" then
    M.config.conversation = "float"
    local r, tid = panel.current()
    panel.close()
    if r then
      M.open_thread(r, tid)
    end
  else
    M.config.conversation = "panel"
    if float and api.nvim_win_is_valid(float.win) then
      local r, tid = float.root, float.tid
      api.nvim_win_close(float.win, true)
      panel.show(r, tid)
    end
  end
  notify("threads open in the " .. M.config.conversation)
end

---Open (or refresh in place) the thread float.
function M.open_thread(root, tid, refresh)
  if M.config.conversation == "panel" then
    return require("code-review.panel").show(root, tid)
  end
  local data = safe_read(root)
  local t = data and store.find(data, tid)
  if not t then
    if float and api.nvim_win_is_valid(float.win) then
      api.nvim_win_close(float.win, true)
    end
    return
  end
  local lines = M.thread_markdown(t)
  local buf, win
  if refresh and float and api.nvim_win_is_valid(float.win) and api.nvim_win_get_buf(float.win) == float.buf then
    buf, win = float.buf, float.win
  else
    if float and api.nvim_win_is_valid(float.win) then
      api.nvim_win_close(float.win, true)
    end
    local src_win = api.nvim_get_current_win()
    buf = api.nvim_create_buf(false, true)
    vim.bo[buf].bufhidden = "wipe"
    vim.bo[buf].filetype = "markdown" -- treesitter / render-markdown.nvim
    local width = math.min(100, vim.o.columns - 4)
    win = api.nvim_open_win(buf, true, {
      relative = "cursor",
      row = 1,
      col = 0,
      width = width,
      height = math.min(#lines, math.floor(vim.o.lines / 2)),
      border = "rounded",
      title = " " .. t.id .. " ",
      footer = " n/p next/prev · N/P across files · r reply · e edit · s send · x resolve · d delete · ? keys · q close ",
      footer_pos = "right",
      style = "minimal",
    })
    vim.wo[win].wrap = true
    vim.wo[win].linebreak = true
    vim.wo[win].conceallevel = 2 -- hide ** and ` without render-markdown too
    vim.wo[win].concealcursor = "n"
    float ={ buf = buf, win = win, root = root, tid = tid }
    local o = { buffer = buf, nowait = true }
    vim.keymap.set("n", "q", function() api.nvim_win_close(win, true) end, o)
    vim.keymap.set("n", "<Esc>", function() api.nvim_win_close(win, true) end, o)
    vim.keymap.set("n", "r", function() M.reply(root, tid) end, o)
    vim.keymap.set("n", "e", function() M.edit(root, tid) end, o)
    vim.keymap.set("n", "s", function() M.poke(root) end, o)
    vim.keymap.set("n", "?", function() M.help("thread") end, o)
    vim.keymap.set("n", "g?", function() M.help("thread") end, o)
    vim.keymap.set("n", "x", function() M.toggle_resolved(root, tid) end, o)
    vim.keymap.set("n", "d", function() M.delete(root, tid) end, o)
    -- Step to the neighbouring thread in the source buffer without closing.
    local function step(dir)
      if not api.nvim_win_is_valid(src_win) then
        return
      end
      local count = vim.v.count1
      api.nvim_set_current_win(src_win)
      M.jump(dir, count)
      local r2, t2 = M.thread_at_cursor()
      if t2 then
        M.open_thread(r2, t2)
      end
    end
    local km = M.config.keymaps or {}
    for _, key in ipairs({ "n", km.next or "]r" }) do
      vim.keymap.set("n", key, function() step(1) end, o)
    end
    for _, key in ipairs({ "p", km.prev or "[r" }) do
      vim.keymap.set("n", key, function() step(-1) end, o)
    end
    vim.keymap.set("n", "N", function() M.step_project(src_win, root, tid, 1, vim.v.count1) end, o)
    vim.keymap.set("n", "P", function() M.step_project(src_win, root, tid, -1, vim.v.count1) end, o)
  end
  vim.bo[buf].modifiable = true
  api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  M.color_authors(buf, lines)
  if refresh then
    api.nvim_win_set_height(win, math.min(#lines, math.floor(vim.o.lines / 2)))
  end
end

---Re-render every loaded buffer and the open thread window.
function M.refresh_views()
  for _, b in ipairs(api.nvim_list_bufs()) do
    if api.nvim_buf_is_loaded(b) then
      M.render(b)
    end
  end
  if float and api.nvim_win_is_valid(float.win) then
    M.open_thread(float.root, float.tid, true)
  end
  local panel = package.loaded["code-review.panel"]
  if panel then
    panel.render()
  end
end

---Visible threads of the project in review order: by file, then line.
local function project_threads(root)
  local data = safe_read(root)
  local res = {}
  for _, t in ipairs(data and data.threads or {}) do
    if t.status ~= "resolved" or M.config.show_resolved then
      res[#res + 1] = t
    end
  end
  table.sort(res, function(a, b)
    if a.file ~= b.file then
      return a.file < b.file
    end
    return a.range.start < b.range.start
  end)
  return res
end

---Where a thread currently is in `buf` (1-based line): its live extmark if
---rendered, else its stored range.
local function thread_line(buf, t)
  for id, tid in pairs(marks[buf] or {}) do
    if tid == t.id then
      local pos = api.nvim_buf_get_extmark_by_id(buf, ns, id, {})
      if pos[1] then
        return pos[1] + 1
      end
    end
  end
  return t.range.start
end

---Open the thread `count` steps after (dir = 1) or before (dir = -1) `tid`
---across all files of the project, wrapping around. The file opens in
---`src_win` and the thread float follows.
function M.step_project(src_win, root, tid, dir, count)
  if not api.nvim_win_is_valid(src_win) then
    return
  end
  local list = project_threads(root)
  if #list == 0 then
    return notify("no comments in this project")
  end
  local idx
  for i, t in ipairs(list) do
    if t.id == tid then
      idx = i
      break
    end
  end
  idx = idx or (dir > 0 and 0 or 1)
  local t = list[((idx - 1 + dir * math.max(1, count or 1)) % #list) + 1]

  api.nvim_set_current_win(src_win)
  local path = session.thread_path(root, t)
  local pr = session.load(root)
  if pr and pr.kind == "pr" then
    vim.cmd("normal! m'")
    require("code-review.diff").show_file(root, t.file, t.side or "new", t.range.start)
  elseif vim.fs.normalize(api.nvim_buf_get_name(0)) ~= path then
    vim.cmd("normal! m'")
    local ok, err = pcall(vim.cmd.edit, vim.fn.fnameescape(path))
    if not ok then
      return notify(tostring(err), vim.log.levels.ERROR)
    end
  else
    vim.cmd("normal! m'")
  end
  local buf = api.nvim_get_current_buf()
  src_win = api.nvim_get_current_win()
  local line = math.max(1, math.min(thread_line(buf, t), api.nvim_buf_line_count(buf)))
  api.nvim_win_set_cursor(src_win, { line, 0 })
  vim.cmd("normal! ^")
  M.open_thread(root, t.id)
end

-- Actions -------------------------------------------------------------------------

local function after_write(root)
  M.watch(root)
  on_store_changed(root)
end

---After a write to the store: watch it and redraw everything that shows it.
function M.after_write(root)
  after_write(root)
end

---Poke the agent session that reviews (herdr) to check the comments.
---@param opts? { pick?: boolean } pick = choose the agent again
-- Help ------------------------------------------------------------------------------

local HELP_GLOBAL = {
  { "add", "comment on the line / selection" },
  { "open", "open the thread under the cursor" },
  { "edit", "edit your last comment (until the agent replies)" },
  { "resolve", "resolve / reopen the thread" },
  { "next", "next thread in this file" },
  { "prev", "previous thread in this file" },
  { "next_yours", "next thread waiting for you" },
  { "prev_yours", "previous thread waiting for you" },
  { "inline", "show / hide conversations under the code" },
  { "find_thread", "pick a thread (with preview)" },
  { "find_file", "PR: pick a file (with preview)" },
  { "list", "open threads → quickfix" },
  { "list_all", "all threads, resolved too → quickfix" },
  { "poke", "poke the agent to check your comments" },
  { "output", "show / hide the agent's live output" },
  { "next_file", "PR: next unreviewed file" },
  { "prev_file", "PR: previous unreviewed file" },
  { "viewed", "PR: mark the file viewed and move on" },
  { "layout", "PR: split / unified diff" },
  { "recent", "resume a recent PR review" },
  { "panel", "threads: float / docked conversation panel" },
  { "description", "PR: title and description" },
  { "help", "this help" },
}

local HELP_CONTEXT = {
  panel = {
    title = "Conversation panel",
    keys = {
      { "i / r", "write a reply (input box)" },
      { "<C-s> / <CR>", "send (in the input box)" },
      { "<M-s>", "send and poke the agent" },
      { "e", "edit your last message" },
      { "x", "resolve / reopen" },
      { "d", "delete the thread" },
      { "s", "poke the agent" },
      { "q", "close the panel" },
    },
  },
  thread = {
    title = "Thread window",
    keys = {
      { "n / p", "next / previous thread in the file" },
      { "N / P", "next / previous thread across files" },
      { "r", "reply" },
      { "e", "edit your last message" },
      { "s", "send to the agent (poke)" },
      { "x", "resolve / reopen" },
      { "d", "delete the thread" },
      { "q", "close" },
    },
  },
  sidebar = {
    title = "Sidebar",
    keys = {
      { "<CR> / o", "open the file / fold a folder" },
      { "<Tab> / za", "fold a folder" },
      { "v", "mark viewed (or not) and go to the next" },
      { "f", "filter: all / unviewed / with threads / waiting for you / changed since last review" },
      { "U", "reload the PR (new commits)" },
      { "S", "changes since your last review / whole PR" },
      { "]f / [f", "next / previous unreviewed file" },
      { "d", "PR description" },
      { "R", "refresh" },
      { "q", "close the sidebar (:CodeReview files reopens)" },
    },
  },
}

---Lines of the help for `context` ("thread", "sidebar" or nil = anywhere).
function M.help_lines(context)
  local lines = {}
  local function section(title, rows)
    local w = 0
    for _, r in ipairs(rows) do
      w = math.max(w, vim.fn.strdisplaywidth(r[1]))
    end
    lines[#lines + 1] = title
    for _, r in ipairs(rows) do
      lines[#lines + 1] = "  " .. r[1] .. string.rep(" ", w - vim.fn.strdisplaywidth(r[1]) + 2) .. r[2]
    end
    lines[#lines + 1] = ""
  end
  local ctx = HELP_CONTEXT[context or ""]
  if ctx then
    section(ctx.title, ctx.keys)
  end
  local km, rows = M.config.keymaps or {}, {}
  for _, item in ipairs(HELP_GLOBAL) do
    if km[item[1]] then -- unmapped (false/nil) keys are left out
      rows[#rows + 1] = { km[item[1]], item[2] }
    end
  end
  section("Anywhere", rows)
  vim.list_extend(lines, {
    "Commands: :CodeReview pr <url> · recent · reload · since · files [left|right|bottom|top]",
    "          · layout [split|unified] · panel · find · threads [all] · poke [pick] · inline · stop",
    "",
  })
  return lines
end

local help_win

---Show the keys that work where you are.
---@param context? "thread"|"sidebar"
function M.help(context)
  if help_win and api.nvim_win_is_valid(help_win) then
    api.nvim_win_close(help_win, true)
  end
  local lines = M.help_lines(context)
  local width = 0
  for _, l in ipairs(lines) do
    width = math.max(width, vim.fn.strdisplaywidth(l))
  end
  width = math.min(width + 2, vim.o.columns - 4)
  local height = math.min(#lines, vim.o.lines - 4)
  local buf = api.nvim_create_buf(false, true)
  api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].bufhidden = "wipe"
  help_win = api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width,
    height = height,
    row = math.floor((vim.o.lines - height) / 2) - 1,
    col = math.floor((vim.o.columns - width) / 2),
    style = "minimal",
    border = "rounded",
    title = " code-review keys · q to close ",
    title_pos = "center",
  })
  for i, l in ipairs(lines) do
    if l ~= "" and not l:find("^ ") then
      api.nvim_buf_set_extmark(buf, ns, i - 1, 0, { end_col = #l, hl_group = "Title" })
    end
  end
  for _, key in ipairs({ "q", "<Esc>", "?", "g?" }) do
    vim.keymap.set("n", key, function()
      if api.nvim_win_is_valid(help_win) then
        api.nvim_win_close(help_win, true)
      end
    end, { buffer = buf, nowait = true })
  end
end

local line_cache = {} -- root -> { key, text }

---Root of the review shown in `buf` (PR pane, unified view or file list), cheaply.
local function review_root(buf)
  local u = vim.b[buf].code_review_unified
  if u then
    return u.root
  end
  local sb = vim.b[buf].code_review_sidebar
  if sb then
    return sb
  end
  return (session.infer(api.nvim_buf_get_name(buf)))
end

---Statusline component (lualine: `lualine_x = { require("code-review").lualine }`):
---"acme/api#12 · 12/35 viewed · 2 waiting for you", plus the agent's progress.
---Empty outside a review. Cached: recomputed only when comments or viewed marks change.
function M.lualine()
  local progress = package.loaded["code-review.progress"]
  local p = progress and progress.statusline() or ""
  local root = review_root(api.nvim_get_current_buf())
  if not root then
    return p
  end
  local _, file = store.paths(root)
  local st = (vim.uv or vim.loop).fs_stat(file)
  local viewed = require("code-review.diff").viewed(root)
  local key = st and string.format("%d.%d:%d", st.mtime.sec, st.mtime.nsec, st.size) or "none"
  local c = line_cache[root]
  if not (c and c.key == key and c.viewed == viewed) then
    local s = session.load(root) or {}
    local n_viewed, total = 0, #(s.files or {})
    for _, f in ipairs(s.files or {}) do
      if viewed[f.path] then
        n_viewed = n_viewed + 1
      end
    end
    local yours = 0
    local data = safe_read(root)
    for _, t in ipairs(data and data.threads or {}) do
      if t.needs == "user" and t.status ~= "resolved" then
        yours = yours + 1
      end
    end
    local parts = { string.format("%s/%s#%s", s.owner or "?", s.repo or "?", s.number or "?") }
    if total > 0 then
      parts[#parts + 1] = string.format("%d/%d viewed", n_viewed, total)
    end
    if yours > 0 then
      parts[#parts + 1] = string.format("%d waiting for you", yours)
    end
    c = { key = key, viewed = viewed, text = table.concat(parts, " · ") }
    line_cache[root] = c
  end
  return p ~= "" and (c.text .. " · " .. p) or c.text
end

---Progress text of the agent being followed, for a statusline ("" when none).
function M.status()
  return require("code-review.progress").statusline()
end

function M.poke(root, opts)
  require("code-review.poke").send(root, M.prompt_for(root), opts)
end

local function maybe_poke(root)
  if M.config.auto_poke then
    M.poke(root)
  end
end

function M.thread_at_cursor()
  local buf = api.nvim_get_current_buf()
  local root = buf_info(buf)
  local row = api.nvim_win_get_cursor(0)[1] - 1
  for _, m in ipairs(api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })) do
    local tid = marks[buf] and marks[buf][m[1]]
    if tid and row >= m[2] and row <= (m[4].end_row or m[2]) then
      return root, tid
    end
  end
end

function M.add(line1, line2)
  local buf = api.nvim_get_current_buf()
  local root, rel, side = buf_info(buf)
  if not root then
    return notify("buffer is not a file inside a project", vim.log.levels.WARN)
  end
  if vim.bo[buf].modified then
    notify("buffer has unsaved changes; save it so agents see the same code", vim.log.levels.WARN)
  end
  if side == "both" then -- unified view: rows → the side and lines they show
    side, line1, line2 = require("code-review.unified").translate(buf, line1, line2)
    if not side then
      return notify("this line only existed in your last review; comment on the current code", vim.log.levels.WARN)
    end
  end
  -- the anchor is taken from the text of that side (a unified buffer mixes both)
  local lines = vim.b[buf].code_review_unified and (session.lines(root, rel, { side = side }) or {})
    or api.nvim_buf_get_lines(buf, 0, -1, false)
  local pr = session.load(root)
  local base = side == "old" and pr and pr.base_sha or nil
  local where = side == "old" and " (old side)" or ""
  input(string.format("Comment on %s:%d-%d%s", rel, line1, line2, where), function(body)
    store.update(root, function(data)
      return store.add_thread(data, {
        file = rel,
        side = side,
        base = base,
        start = line1,
        ["end"] = line2,
        anchor = anchor.capture(lines, line1, line2),
        author = "user",
        body = body,
      })
    end)
    after_write(root)
    maybe_poke(root)
  end)
end

function M.reply(root, tid)
  input("Reply to " .. tid, function(body)
    store.update(root, function(data)
      local t = store.find(data, tid)
      if t then
        store.add_message(t, "user", body)
        if t.status == "resolved" then
          t.status = "open"
        end
      end
    end)
    after_write(root)
    maybe_poke(root)
  end)
end

---Edit your last message of a thread, as long as the agent has not answered it.
function M.edit(root, tid)
  local data = safe_read(root)
  local t = data and store.find(data, tid)
  if not t then
    return
  end
  local last = t.messages[#t.messages]
  if not last or last.author ~= "user" then
    return notify("the agent has already replied; press r to reply instead", vim.log.levels.WARN)
  end
  input("Edit your comment (" .. tid .. ")", function(body)
    local refused
    try_update(root, function(d)
      local t2 = store.find(d, tid)
      if not t2 then
        return store.UNCHANGED
      end
      local ok, err = store.edit_last_user_message(t2, body)
      if not ok then
        refused = err -- the agent replied while the editor was open
        return store.UNCHANGED
      end
      if t2.messages[#t2.messages].body == last.body then
        return store.UNCHANGED
      end
    end)
    if refused then
      notify("not saved: " .. refused, vim.log.levels.WARN)
    end
    after_write(root)
    if not refused then
      maybe_poke(root)
    end
  end, last.body)
end

function M.toggle_resolved(root, tid)
  store.update(root, function(data)
    local t = store.find(data, tid)
    if t then
      t.status = t.status == "resolved" and "open" or "resolved"
    end
  end)
  -- reopened threads may no longer match the code
  for _, buf in ipairs(api.nvim_list_bufs()) do
    if api.nvim_buf_is_loaded(buf) and buf_info(buf) == root then
      M.render(buf, true)
    end
  end
  after_write(root)
end

function M.delete(root, tid)
  if vim.fn.confirm("Delete thread " .. tid .. "?", "&Yes\n&No", 2) ~= 1 then
    return
  end
  store.update(root, function(data)
    local _, i = store.find(data, tid)
    if i then
      table.remove(data.threads, i)
    end
  end)
  after_write(root)
end

-- From a non-file buffer (e.g. the quickfix list itself), use the previous
-- window's file before falling back to the cwd.
local function current_root()
  local root = buf_info(api.nvim_get_current_buf())
  if not root then
    local prev = vim.fn.win_getid(vim.fn.winnr("#"))
    if prev ~= 0 then
      root = buf_info(api.nvim_win_get_buf(prev))
    end
  end
  return root or store.find_root()
end

function M.list(all)
  local root = current_root()
  local data = safe_read(root)
  if not data then
    return
  end
  local threads = vim.deepcopy(data.threads)
  table.sort(threads, function(a, b)
    if a.file ~= b.file then
      return a.file < b.file
    end
    return a.range.start < b.range.start
  end)
  local items = {}
  for _, t in ipairs(threads) do
    if all or t.status ~= "resolved" then
      local last = t.messages[#t.messages]
      items[#items + 1] = {
        filename = session.thread_path(root, t),
        lnum = t.range.start,
        end_lnum = t.range["end"],
        text = string.format(
          "[%s · needs %s%s] %s: %s",
          t.status,
          t.needs,
          t.side == "old" and " · old side" or "",
          last.author,
          first_line(last.body)
        ),
        user_data = t.id,
      }
    end
  end
  vim.fn.setqflist({}, " ", { title = "Code review", items = items })
  if #items == 0 then
    return notify("no threads")
  end
  vim.cmd.copen()
end

---Jump to the next (dir = 1) or previous (dir = -1) thread in the current
---buffer, wrapping around. Only visible threads count (resolved ones are
---skipped unless show_resolved is on).
function M.jump(dir, count)
  local buf = api.nvim_get_current_buf()
  local rows, seen_rows = {}, {}
  for _, m in ipairs(api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })) do
    if marks[buf] and marks[buf][m[1]] and not m[4].invalid and not seen_rows[m[2]] then
      seen_rows[m[2]] = true
      rows[#rows + 1] = m[2]
    end
  end
  if #rows == 0 then
    return notify("no comments in this buffer")
  end
  table.sort(rows)
  local cur = api.nvim_win_get_cursor(0)[1] - 1
  local target = cur
  for _ = 1, math.max(1, count or 1) do
    local nxt
    if dir > 0 then
      for _, r in ipairs(rows) do
        if r > target then
          nxt = r
          break
        end
      end
      nxt = nxt or rows[1]
    else
      for i = #rows, 1, -1 do
        if rows[i] < target then
          nxt = rows[i]
          break
        end
      end
      nxt = nxt or rows[#rows]
    end
    target = nxt
  end
  vim.cmd("normal! m'") -- add to jumplist
  api.nvim_win_set_cursor(0, { target + 1, 0 })
  vim.cmd("normal! ^")
  M.flash()
end

M.prompt = [[I left review comments on the code for you. Run `code-review list --needs agent` to see them (`code-review skill` explains the workflow). Reply in each thread with `code-review reply <id> "..."`, make any changes requested, and only resolve a thread with `code-review resolve <id>` once the change is done.]]

---The prompt for the agent; in a PR review every command needs `--pr`.
function M.prompt_for(root)
  local s = root and session.load(root)
  if not (s and s.kind == "pr") then
    return M.prompt
  end
  local ref = string.format("%s/%s#%d", s.owner, s.repo, s.number)
  return string.format(
    [[I am reviewing PR %s in Neovim (no checkout) and left comments for you. Run `code-review --pr %s list --needs agent` to see them and `code-review --pr %s diff` for the changed files and where their base/head snapshots live (`code-review skill` explains the workflow). Read code from those snapshot paths; for any other file run `code-review --pr %s file <path>` and read the path it prints. Reply in each thread with `code-review --pr %s reply <id> "..."`, and only resolve a thread with `resolve` once the requested change is settled. You cannot change the PR itself, so answer with explanations or suggested code.]],
    ref, ref, ref, ref, ref
  )
end

function M.copy_prompt()
  local prompt = M.prompt_for(current_root())
  vim.fn.setreg('"', prompt)
  pcall(vim.fn.setreg, "+", prompt)
  notify("agent prompt copied")
end

---Jump to the next (dir = 1) or previous (-1) thread waiting for you, i.e. the
---agent replied. Stops at the ends; opens the thread.
function M.jump_yours(dir)
  local root, rel = buf_info(api.nvim_get_current_buf())
  root = root or current_root()
  local list = vim.tbl_filter(function(t)
    return t.needs == "user" and t.status ~= "resolved"
  end, project_threads(root))
  if #list == 0 then
    return notify("no thread is waiting for you")
  end
  local line = api.nvim_win_get_cursor(0)[1]
  -- from inside a thread window, continue from that thread
  if float and float.win == api.nvim_get_current_win() then
    local data = safe_read(root)
    local t = data and store.find(data, float.tid)
    if t then
      rel, line = t.file, t.range.start
    end
  end
  local function after(t)
    return t.file > (rel or "") or (t.file == rel and t.range.start > line)
  end
  local function before(t)
    return t.file < (rel or "~") or (t.file == rel and t.range.start < line)
  end
  local target
  if dir > 0 then
    for _, t in ipairs(list) do
      if after(t) then
        target = t
        break
      end
    end
  else
    for i = #list, 1, -1 do
      if before(list[i]) then
        target = list[i]
        break
      end
    end
  end
  if not target then
    return notify(string.format("no more threads waiting for you %s (%d in total)", dir > 0 and "below" or "above", #list))
  end
  local pr = session.load(root)
  if pr and pr.kind == "pr" then
    require("code-review.diff").show_file(root, target.file, target.side or "new", target.range.start)
  else
    vim.cmd.edit(vim.fn.fnameescape(root .. "/" .. target.file))
    pcall(api.nvim_win_set_cursor, 0, { target.range.start, 0 })
    M.flash()
  end
  M.open_thread(root, target.id)
end

-- Command / setup ---------------------------------------------------------------

local subcommands = {
  add = function(o)
    M.add(o.line1, o.line2)
  end,
  open = function()
    local root, tid = M.thread_at_cursor()
    if not tid then
      return notify("no thread under cursor", vim.log.levels.WARN)
    end
    M.open_thread(root, tid)
  end,
  inline = function()
    M.toggle_inline()
  end,
  help = function()
    M.help()
  end,
  reload = function()
    local diff = require("code-review.diff")
    local root = diff.where() or current_root()
    diff.reload(root)
  end,
  since = function()
    local diff = require("code-review.diff")
    local root = diff.where() or current_root()
    diff.toggle_since(root)
  end,
  recent = function()
    require("code-review.diff").recent()
  end,
  panel = function()
    M.toggle_conversation()
  end,
  layout = function(o)
    local diff = require("code-review.diff")
    local root = diff.where() or current_root()
    diff.set_layout(root, o and o.fargs and o.fargs[2])
  end,
  find = function()
    local root = require("code-review.diff").where() or current_root()
    require("code-review.picker").files(root)
  end,
  threads = function(o)
    local root = require("code-review.diff").where() or current_root()
    require("code-review.picker").threads(root, o and o.fargs and o.fargs[2] == "all")
  end,
  nextyours = function()
    M.jump_yours(1)
  end,
  prevyours = function()
    M.jump_yours(-1)
  end,
  output = function()
    require("code-review.progress").toggle_output(session.infer(api.nvim_buf_get_name(0)) or current_root())
  end,
  stop = function()
    require("code-review.progress").stop()
  end,
  poke = function(o)
    local root = session.infer(api.nvim_buf_get_name(0)) or current_root()
    M.poke(root, { pick = o and o.fargs and o.fargs[2] == "pick" })
  end,
  edit = function()
    local root, tid = M.thread_at_cursor()
    if not tid then
      return notify("no thread under cursor", vim.log.levels.WARN)
    end
    M.edit(root, tid)
  end,
  resolve = function()
    local root, tid = M.thread_at_cursor()
    if not tid then
      return notify("no thread under cursor", vim.log.levels.WARN)
    end
    M.toggle_resolved(root, tid)
  end,
  delete = function()
    local root, tid = M.thread_at_cursor()
    if tid then
      M.delete(root, tid)
    end
  end,
  list = function(o)
    M.list(o.fargs[2] == "all")
  end,
  next = function()
    M.jump(1)
  end,
  prev = function()
    M.jump(-1)
  end,
  copy = M.copy_prompt,
  pr = function(o)
    local ref = o.fargs[2]
    if not ref then
      return notify("usage: :CodeReview pr <PR URL | owner/repo#n>", vim.log.levels.WARN)
    end
    require("code-review.diff").open(ref)
  end,
  files = function(o)
    local diff = require("code-review.diff")
    local root = diff.where() or current_root()
    diff.toggle_sidebar(root, o and o.fargs and o.fargs[2])
  end,
  description = function()
    require("code-review.diff").description(session.infer(api.nvim_buf_get_name(0)) or current_root())
  end,
  viewed = function()
    local root = require("code-review.diff").where()
    if not root then
      return notify("not in a PR review", vim.log.levels.WARN)
    end
    require("code-review.diff").toggle_viewed(root)
  end,
  nextfile = function()
    require("code-review.diff").step(1)
  end,
  prevfile = function()
    require("code-review.diff").step(-1)
  end,
  refresh = function()
    for _, buf in ipairs(api.nvim_list_bufs()) do
      if api.nvim_buf_is_loaded(buf) then
        M.render(buf, true)
      end
    end
  end,
}

function M.command(o)
  M.setup_once()
  local name = o.fargs[1] or "list"
  local fn = subcommands[name]
  if not fn then
    return notify("unknown subcommand " .. name, vim.log.levels.ERROR)
  end
  fn(o)
end

function M.complete(arglead)
  return vim.tbl_filter(function(c)
    return c:find(arglead, 1, true) == 1
  end, vim.tbl_keys(subcommands))
end

local function highlights()
  local set = function(name, link)
    api.nvim_set_hl(0, name, { link = link, default = true })
  end
  set("CodeReviewNeedsAgent", "DiagnosticInfo")
  set("CodeReviewNeedsUser", "DiagnosticWarn")
  set("CodeReviewAgent", "DiagnosticHint")
  set("CodeReviewVirt", "Comment")
  set("CodeReviewDim", "NonText")
  set("CodeReviewFlash", "IncSearch")
  api.nvim_set_hl(0, "CodeReviewOutdated", { strikethrough = true, link = nil, default = true, fg = (api.nvim_get_hl(0, { name = "Comment", link = false }) or {}).fg })
  set("CodeReviewAuthorYou", "DiagnosticInfo") -- the same colors everywhere: thread window, inline, summary
  set("CodeReviewAuthorAgent", "DiagnosticHint")
  require("code-review.diff").highlights()
end

function M.setup(opts)
  M.config = vim.tbl_deep_extend("force", M.config, opts or {})
  did_setup = true
  highlights()
  api.nvim_clear_autocmds({ group = group })
  api.nvim_create_autocmd("ColorScheme", { group = group, callback = highlights })
  api.nvim_create_autocmd("BufReadPost", {
    group = group,
    callback = function(ev)
      M.render(ev.buf, true)
    end,
  })
  api.nvim_create_autocmd("BufWritePost", {
    group = group,
    callback = function(ev)
      M.sync_from_marks(ev.buf)
      M.render(ev.buf)
    end,
  })
  -- Has the PR got new commits? Checked now and then (throttled) while reviewing.
  api.nvim_create_autocmd({ "FocusGained", "BufEnter" }, {
    group = group,
    callback = function(ev)
      local r = review_root(ev.buf)
      if r then
        require("code-review.diff").check_updates(r)
      end
    end,
  })
  -- The winbar shows the function around the cursor: keep it current in review panes.
  api.nvim_create_autocmd("CursorMoved", {
    group = group,
    callback = function(ev)
      if vim.b[ev.buf].code_review_unified or session.infer(api.nvim_buf_get_name(ev.buf)) then
        vim.cmd("redrawstatus")
      end
    end,
  })
  -- A diff pane keeps its window-local winbar when another file is opened in it.
  api.nvim_create_autocmd("BufWinEnter", {
    group = group,
    callback = function(ev)
      local win = api.nvim_get_current_win()
      if (vim.wo[win].winbar or ""):find("code-review.diff", 1, true) and not session.infer(api.nvim_buf_get_name(ev.buf))
        and not vim.b[ev.buf].code_review_unified then
        vim.wo[win].winbar = ""
        vim.wo[win].foldtext = vim.go.foldtext
        vim.wo[win].fillchars = vim.go.fillchars
        vim.wo[win].statuscolumn = ""
      end
    end,
  })
  api.nvim_create_autocmd({ "BufEnter", "FocusGained" }, {
    group = group,
    callback = function(ev)
      M.render(ev.buf)
    end,
  })

  local km = M.config.keymaps or {}
  if km.add then
    vim.keymap.set("n", km.add, function()
      local l = api.nvim_win_get_cursor(0)[1]
      M.add(l, l)
    end, { desc = "Code review: add comment" })
    vim.keymap.set("x", km.add, function()
      local a, b = vim.fn.line("v"), vim.fn.line(".")
      if a > b then
        a, b = b, a
      end
      api.nvim_feedkeys(api.nvim_replace_termcodes("<Esc>", true, false, true), "nx", false)
      M.add(a, b)
    end, { desc = "Code review: comment on selection" })
  end
  if km.open then
    vim.keymap.set("n", km.open, subcommands.open, { desc = "Code review: open thread" })
  end
  if km.panel then
    vim.keymap.set("n", km.panel, function() M.toggle_conversation() end, { desc = "Code review: threads in float / panel" })
  end
  if km.recent then
    vim.keymap.set("n", km.recent, function() subcommands.recent() end, { desc = "Code review: recent reviews" })
  end
  if km.layout then
    vim.keymap.set("n", km.layout, function() subcommands.layout() end, { desc = "Code review: split / unified diff" })
  end
  if km.find_file then
    vim.keymap.set("n", km.find_file, function() subcommands.find() end, { desc = "Code review: pick a PR file" })
  end
  if km.find_thread then
    vim.keymap.set("n", km.find_thread, function() subcommands.threads() end, { desc = "Code review: pick a thread" })
  end
  if km.help then
    vim.keymap.set("n", km.help, function() M.help() end, { desc = "Code review: keys" })
  end
  if km.inline then
    vim.keymap.set("n", km.inline, M.toggle_inline, { desc = "Code review: inline conversations" })
  end
  if km.next_yours then
    vim.keymap.set("n", km.next_yours, function() M.jump_yours(1) end, { desc = "Code review: next thread waiting for you" })
  end
  if km.prev_yours then
    vim.keymap.set("n", km.prev_yours, function() M.jump_yours(-1) end, { desc = "Code review: previous thread waiting for you" })
  end
  if km.output then
    vim.keymap.set("n", km.output, function() subcommands.output() end, { desc = "Code review: live agent output" })
  end
  if km.poke then
    vim.keymap.set("n", km.poke, function() subcommands.poke() end, { desc = "Code review: poke the agent" })
  end
  if km.edit then
    vim.keymap.set("n", km.edit, subcommands.edit, { desc = "Code review: edit my comment" })
  end
  if km.resolve then
    vim.keymap.set("n", km.resolve, subcommands.resolve, { desc = "Code review: resolve/reopen thread" })
  end
  if km.list then
    vim.keymap.set("n", km.list, function() M.list(false) end, { desc = "Code review: list open threads" })
  end
  if km.list_all then
    vim.keymap.set("n", km.list_all, function() M.list(true) end, { desc = "Code review: list all threads" })
  end
  if km.next then
    vim.keymap.set("n", km.next, function() M.jump(1, vim.v.count1) end, { desc = "Code review: next thread" })
  end
  if km.prev then
    vim.keymap.set("n", km.prev, function() M.jump(-1, vim.v.count1) end, { desc = "Code review: previous thread" })
  end

  require("code-review.diff").attach_quickfix(group)
  if km.viewed then
    vim.keymap.set("n", km.viewed, subcommands.viewed, { desc = "Code review: toggle file viewed" })
  end
  if km.description then
    vim.keymap.set("n", km.description, subcommands.description, { desc = "Code review: PR description" })
  end

  if M.config.add_bin_to_path then
    local here = debug.getinfo(1, "S").source:sub(2)
    local bin = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(here))) .. "/bin"
    if not (vim.env.PATH or ""):find(bin, 1, true) then
      vim.env.PATH = bin .. ":" .. (vim.env.PATH or "")
    end
  end

  for _, buf in ipairs(api.nvim_list_bufs()) do
    if api.nvim_buf_is_loaded(buf) then
      M.render(buf, true)
    end
  end
end

function M.setup_once()
  if not did_setup then
    M.setup()
  end
end

return M
