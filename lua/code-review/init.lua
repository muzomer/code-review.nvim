-- Neovim UI: signs + virtual text, thread float, reply input, quickfix list,
-- live refresh when an agent writes the store.
local store = require("code-review.store")
local anchor = require("code-review.anchor")
local session = require("code-review.session")

local uv = vim.uv or vim.loop
local api = vim.api

local keys = require("code-review.keys")

local M = {}

M.config = {
  -- Every binding is a key, a list of keys ({ "<C-l>", "<leader>cl" }), or false for none.
  keymaps = {
    add = "<leader>ca", -- normal: current line, visual: the selected text (v) or lines (V)
    open = "<leader>cr", -- open thread under cursor (reply from there)
    edit = "<leader>ce", -- edit your last comment of the thread under the cursor
    poke = "<leader>cp", -- poke the agent to check your comments
    auto_poke = "<leader>cA", -- toggle: <C-s> in the comment box also pokes the agent
    output = "<leader>cP", -- show / hide the live output of the agent you poked
    resolve = "<leader>cx", -- toggle resolved
    approve = "<leader>cy", -- local review: let the agent change the code for this thread (again: withdraw)
    list = { "<C-l>", "<leader>cl" }, -- toggle the open threads of the project (quickfix)
    list_all = { "<C-S-l>", "<leader>cL" }, -- toggle all threads, resolved too (Ctrl+Shift+L needs a terminal that reports it, e.g. kitty)
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
    next_commit = "]C", -- commits review: next commit (]c / [c are Neovim's next / previous change)
    prev_commit = "[C", -- commits review: previous commit
    find_commit = "<leader>cC", -- commits review: pick a commit
    commits = "<leader>co", -- start (or resume) reviewing the commits of the current branch, one at a time
    -- on a thread: in the thread window, the thread list (quickfix) and the conversation panel
    thread = {
      reply = { "r", "i" },
      edit = "e", -- your last message, until the agent answers
      send = "s", -- poke the agent
      resolve = "x", -- resolve / reopen
      approve = "a", -- let the agent change the code for it / withdraw that
      delete = "d",
      next = "n", -- next / previous thread in the file (also keymaps.next / prev)
      prev = "p",
      next_file = "N", -- next / previous thread across files
      prev_file = "P",
      help = { "?", "g?" },
      close = { "q", "<Esc>" },
    },
    -- the comment box and the panel's input
    input = {
      submit = "<C-s>", -- normal and insert mode: save (and send, with auto_poke)
      submit_alt = "<M-s>", -- the other one: save and send (only save, with auto_poke)
      submit_normal = "<CR>", -- normal mode: same as submit
      cancel = "q", -- normal mode; <Esc> only closes an empty box
    },
    sidebar = {
      open = { "<CR>", "o" }, -- open the file / fold the folder
      fold = { "<Tab>", "za" },
      viewed = "v",
      filter = "f",
      reload = "U", -- the PR got new commits
      since = "S", -- changes since your last review / the whole PR
      description = "d",
      refresh = "R",
      help = { "?", "g?" },
      close = "q",
    },
  },
  show_resolved = false,
  inline_threads = false, -- show whole conversations under the commented lines (toggle: keymaps.inline)
  inline_max_lines = 12, -- longest inline conversation before it is cut ("open the thread for more")
  notify = true, -- notify when an agent replies
  conversation = "float", -- open threads in a "float" (default) or a docked chat "panel" with an input box
  panel_width = nil, -- width of the conversation panel (default: ~35% of the screen, 40..70)
  mouse = true, -- click a thread's sign or its line in the thread list to open it; click a file in the file list to open it
  notify_group_ms = 1500, -- replies arriving within this window become one notification
  flash_ms = 350, -- briefly highlight where a jump lands (0 / false: off)
  progress = true, -- after a poke, show the agent's state (working / done / waiting)
  progress_float = true, -- where: true = floating window, false = winbar/statusline only, "auto" = winbar in a PR review, else float
  progress_output = false, -- ... and also open the live output window right away
  auto_poke = false, -- <C-s> in the comment box also pokes the agent (then <M-s> only saves); toggle: keymaps.auto_poke
  -- local reviews: "discuss" = the agent answers and proposes changes, and changes
  -- the code only for threads you approve (keymaps.approve); "auto" = it changes
  -- the code whenever a comment asks for it
  agent_changes = "discuss",
  open_after_send = true, -- after <M-s> on a new comment, open its thread to watch the reply come in
  agent = "auto", -- who gets poked: "auto" (a herdr agent you pick, else the background agent), "herdr", "headless"
  isolate = "fork", -- keep the work out of a herdr agent's session: "fork" (a throwaway copy of it answers in the
  -- background; falls back to "subagent"), "subagent" (typed in, the agent delegates to a subagent), false (typed in as is)
  headless = { -- the background agent: one resumable conversation per review
    agent = "claude", -- "claude", "codex", "opencode" or "gemini"
    cmd = nil, -- its executable (default: the agent's own: claude, codex, opencode, gemini)
    allowed_tools = nil, -- claude: default code-review CLI + Read/Grep/Glob, plus Edit/Write inside the project in a local review (not a PR)
    permission_mode = nil, -- claude: --permission-mode (e.g. "acceptEdits"); codex: --sandbox (default "workspace-write");
    -- gemini: --approval-mode (e.g. "yolo" to let it run the CLI); opencode: "auto" = --auto
    args = {}, -- extra arguments for every run
  },
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
---Cut a message to one screen line: a longer one makes Neovim stop at
---"Press ENTER" (the whole reply is in the thread anyway).
function M.one_line(msg)
  local max = vim.o.columns - 15 -- room for the ruler / showcmd
  if vim.fn.strdisplaywidth(msg) <= max then
    return msg
  end
  local out = msg
  while vim.fn.strdisplaywidth(out) > max - 1 do
    out = vim.fn.strcharpart(out, 0, vim.fn.strchars(out) - 1)
  end
  return out .. "…"
end

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
    return vim.notify(M.one_line(string.format("code-review: %s on %s:%d: %s", n.author, n.file, n.line, n.text)))
  end
  local authors, where = {}, {}
  for _, n in ipairs(notes) do
    authors[n.author] = true
    where[#where + 1] = string.format("%s:%d", n.file:match("[^/]+$"), n.line)
  end
  local who = vim.tbl_keys(authors)
  table.sort(who)
  vim.notify(M.one_line(string.format("code-review: %s replied to %d threads: %s", table.concat(who, ", "), #notes, table.concat(where, ", "))))
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
local marks = {} -- buf -> { [extmark id] = thread id } (the lines of each thread)
local span_marks = {} -- buf -> { [extmark id] = thread id } (the selected text, for threads that have one)
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
    return u.root, u.file, "both", true, u.commit
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
  local sroot, sfile, sside, scommit = session.infer(name)
  if sroot then
    return sroot, sfile, sside, true, scommit
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

---@param commit? string a commit of a commits review: only its threads
local function threads_for(data, rel, side, commit)
  local res = {}
  for _, t in ipairs(data.threads) do
    if t.file == rel and (side == "both" or (t.side or "new") == (side or "new")) and (not commit or t.commit == commit) then
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

---store.update that reports a failure instead of raising it.
---@return boolean ok
---@return any result of fn
local function try_update(root, fn)
  local ok, res = pcall(store.update, root, fn)
  if not ok then
    notify(res, vim.log.levels.ERROR)
    return false
  end
  return true, res
end

---Where the extmarks say each tracked thread is now, or false when its code was
---deleted: { first, last } lines (1-based), plus { ..., start_col, end_col }
---while its selected text is still there (then its lines are that text's).
---Reflects unsaved edits.
local function live_positions(buf)
  local pos = {}
  for _, tid in pairs(marks[buf] or {}) do
    pos[tid] = false -- a mark that vanished counts as deleted code
  end
  local spans = {}
  for _, m in ipairs(api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })) do
    local tid = marks[buf] and marks[buf][m[1]]
    local stid = span_marks[buf] and span_marks[buf][m[1]]
    if tid and not m[4].invalid then
      pos[tid] = { m[2] + 1, m[4].end_row + 1 }
    elseif stid and not m[4].invalid and (m[4].end_row > m[2] or m[4].end_col > m[3]) then
      spans[stid] = { m[2] + 1, m[4].end_row + 1, m[3] + 1, m[4].end_col }
    end
  end
  for tid, sp in pairs(spans) do
    if pos[tid] then -- text left, lines left too
      pos[tid] = sp
    end
  end
  for tid in pairs(lost[buf] or {}) do
    pos[tid] = false
  end
  return pos
end

---The threads on row `row` (0-based) of `buf`, in order, and of those the ones
---whose selected text holds column `col` (0-based), smallest first.
---@return string[] on_row, string[] inside
local function threads_at(buf, row, col)
  local on_row, inside, seen = {}, {}, {}
  for _, m in ipairs(api.nvim_buf_get_extmarks(buf, ns, { row, 0 }, { row, -1 }, { details = true, overlap = true })) do
    local d = m[4]
    local tid = marks[buf] and marks[buf][m[1]]
    local stid = span_marks[buf] and span_marks[buf][m[1]]
    if d.invalid then -- the code was deleted (not saved yet)
    elseif tid and not seen[tid] then
      seen[tid] = true
      on_row[#on_row + 1] = tid
    elseif stid and col then
      local after_start = row > m[2] or col >= m[3]
      local before_end = row < d.end_row or col < d.end_col
      if after_start and before_end then
        inside[#inside + 1] = { tid = stid, size = (d.end_row - m[2]) * 1e9 + d.end_col - m[3] }
      end
    end
  end
  table.sort(inside, function(a, b) return a.size < b.size end)
  return on_row, vim.tbl_map(function(x) return x.tid end, inside)
end

-- Which sign color wins when several threads start on one line.
local URGENCY = { CodeReviewNeedsUser = 4, CodeReviewNeedsAgent = 3, CodeReviewAgent = 2, CodeReviewDim = 1 }

---@param reanchor? boolean relocate threads against buffer text first
function M.render(buf, reanchor)
  local root, rel, side, snapshot, commit = buf_info(buf)
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
          keys.set("n", lhs, function() require("code-review.diff").step(dir) end, { buffer = buf, desc = desc })
        end
      end
      map(km.next_file, 1, "Code review: next PR file")
      map(km.prev_file, -1, "Code review: previous PR file")
      if commit then
        for lhs, dir in pairs({ next_commit = 1, prev_commit = -1 }) do
          if km[lhs] then
            keys.set("n", km[lhs], function() require("code-review.commits").step(root, dir) end,
              { buffer = buf, desc = dir > 0 and "Code review: next commit" or "Code review: previous commit" })
          end
        end
      end
    end
  end
  M.watch(root)
  local data = safe_read(root)
  if not data then
    return
  end
  local threads = threads_for(data, rel, side, commit)
  if side == "both" and require("code-review.unified").is_since(buf) then
    -- the old column is your last review, not the PR base: base-side threads do not belong
    threads = vim.tbl_filter(function(t) return t.side ~= "old" end, threads)
  end
  if reanchor and side ~= "both" and #threads > 0 then
    local lines = api.nvim_buf_get_lines(buf, 0, -1, false)
    if anchor.reanchor_threads(vim.deepcopy(threads), lines) then
      try_update(root, function(d)
        if not anchor.reanchor_threads(threads_for(d, rel, side, commit), lines) then
          return store.UNCHANGED
        end
      end)
      data = safe_read(root) or data
      threads = threads_for(data, rel, side, commit)
    end
  end

  -- With unsaved edits the stored ranges are stale; keep where the marks went.
  local live = (not reanchor and vim.bo[buf].modified) and live_positions(buf) or {}
  api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  marks[buf], span_marks[buf], lost[buf] = {}, {}, {}
  local n = api.nvim_buf_line_count(buf)
  local shown, on_row, row_hl = {}, {}, {} -- per row: how many threads start there, the most urgent color
  for _, t in ipairs(threads) do
    local p = live[t.id]
    if p == false then
      lost[buf][t.id] = true
    elseif t.status ~= "resolved" or M.config.show_resolved then
      local r = p or { t.range.start, t.range["end"], anchor.cols(t) }
      if side == "both" and not p then -- unified view: the thread's side and line → buffer row
        local u, ts = require("code-review.unified"), t.side or "new"
        local first = u.row_of(buf, ts, t.range.start) or 1
        local last = u.row_of(buf, ts, t.range["end"])
        r = { first, last or first, last and r[3], last and r[4] }
      end
      local s = math.max(1, math.min(r[1], n)) - 1
      local e = math.max(s + 1, math.min(r[2], n)) - 1
      shown[#shown + 1] = { t = t, s = s, e = e, sc = r[3], ec = r[4] }
      on_row[s] = (on_row[s] or 0) + 1
      local _, hl = style(t)
      if (URGENCY[hl] or 0) > (URGENCY[row_hl[s]] or 0) then
        row_hl[s] = hl
      end
    end
  end
  local signed = {} -- rows whose sign is set: the first thread there shows the count
  for _, it in ipairs(shown) do
    local t, s, e = it.t, it.s, it.e
    do
      local sign, sign_hl, virt_hl = style(t)
      local gutter = sign
      if signed[s] then
        gutter = nil
      elseif on_row[s] > 1 then
        gutter = on_row[s] > 9 and "9+" or tostring(on_row[s])
        sign_hl = row_hl[s] -- the count takes the color of the thread that needs you most
      end
      signed[s] = true
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
        sign_text = gutter,
        sign_hl_group = gutter and sign_hl or nil,
        virt_text = not inline and chunks or nil,
        virt_text_pos = not inline and "eol" or nil,
        invalidate = true,
        priority = 20,
      })
      marks[buf][id] = t.id
      -- the selected text: only while it still fits the lines (stale columns must not throw)
      local start_line = api.nvim_buf_get_lines(buf, s, s + 1, false)[1] or ""
      local sc, ec = it.sc, it.ec and math.min(it.ec, #end_line)
      if sc and ec and t.status ~= "outdated" and sc <= #start_line and (e > s or ec >= sc) then
        local sid = api.nvim_buf_set_extmark(buf, ns, s, sc - 1, {
          end_row = e,
          end_col = ec,
          hl_group = t.status == "resolved" and "CodeReviewSpanResolved" or "CodeReviewSpan",
          invalidate = true,
          priority = 21,
        })
        span_marks[buf][sid] = t.id
      end
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
  local on_row = threads_at(buf, pos.line - 1)
  if #on_row == 1 then
    return (buf_info(buf)), on_row[1]
  elseif #on_row > 1 then
    return (buf_info(buf)), nil, on_row
  end
end

function M.map_mouse(buf)
  if not M.config.mouse or vim.b[buf].code_review_mouse then
    return
  end
  vim.b[buf].code_review_mouse = true
  vim.keymap.set("n", "<LeftMouse>", function()
    local r, tid, many = M.mouse_thread(vim.fn.getmousepos())
    if tid or many then
      vim.schedule(function()
        if tid then
          M.open_thread(r, tid)
        else
          M.pick_thread(r, many, M.open_thread)
        end
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
          -- p[3], p[4]: where the selected text went (nil: it was deleted, the lines stay)
          local range = { start = p[1], ["end"] = p[2], start_col = p[3], end_col = p[4] }
          local a = anchor.capture(lines, p[1], p[2], p[3], p[4])
          if not vim.deep_equal(range, t.range) or not vim.deep_equal(a, t.anchor) then
            t.range = range
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
  M.refresh_qf(root, data)
  pcall(require("code-review.sidebar").refresh_all) -- thread counts per file
  if float and float.root == root and api.nvim_win_is_valid(float.win) then
    M.open_thread(root, float.tid, true)
  end
  local panel = package.loaded["code-review.panel"]
  if panel and panel.current() == root then
    panel.render()
  end
end

local function unwatch(root)
  local w = watchers[root]
  if w then
    watchers[root] = nil
    pcall(w.handle.stop, w.handle)
    pcall(w.handle.close, w.handle)
    pcall(w.timer.close, w.timer)
  end
end

local watch_failed = false -- warned once that live updates are off
local watch_failed_at = {} -- root -> when watching it last failed: not retried on every render
local WATCH_RETRY_S = 60

function M.watch(root)
  local w = watchers[root]
  if w and not w.dead then
    return
  end
  if watch_failed_at[root] and os.time() - watch_failed_at[root] < WATCH_RETRY_S then
    return
  end
  unwatch(root) -- the directory was deleted: watch the new one
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
  local started, err = false, "out of inotify watches?"
  if handle then
    started, err = handle:start(dir, {}, function(e, fname)
      if e or not uv.fs_stat(dir) then -- (a fast callback: no vim.fn here)
        -- deleted (or the watch broke): the next write watches again
        if watchers[root] then
          watchers[root].dead = true
        end
        return
      end
      if fname and fname ~= store.FILE then
        return
      end
      timer:stop()
      timer:start(80, 0, vim.schedule_wrap(function()
        on_store_changed(root)
      end))
    end)
  end
  if not started then
    if handle then
      pcall(handle.close, handle)
    end
    pcall(timer.close, timer)
    watch_failed_at[root] = os.time()
    if not watch_failed then
      watch_failed = true
      notify("cannot watch " .. dir .. " (" .. tostring(err) .. "); agent replies show after your next action",
        vim.log.levels.WARN)
    end
    return
  end
  watch_failed_at[root] = nil
  watchers[root] = { handle = handle, timer = timer }
end

-- Floats ------------------------------------------------------------------------

---@param on_submit fun(text: string, poke: boolean): boolean? poke = sent with <M-s>: also poke
---the agent. Returning false (not saved) opens the box again with the text.
---@param initial? string text to start from (editing)
---Footer of the comment box: its keys, as configured.
function M.input_footer()
  local ik = keys.group("input")
  local save = table.concat(vim.list_extend(vim.deepcopy(keys.list(ik.submit)), keys.list(ik.submit_normal)), " / ")
  local alt = keys.label(ik.submit_alt) or "-"
  local cancel = keys.label(ik.cancel)
  if M.config.auto_poke then
    return string.format(" %s save + send to agent · %s save only%s ", save, alt, cancel and (" · " .. cancel .. " cancel") or "")
  end
  return string.format(" %s save · %s save + send to agent%s ", save, alt, cancel and (" · " .. cancel .. " cancel") or "")
end

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
  local origin = api.nvim_get_current_win() -- focus goes back there (e.g. the thread list)
  local win = api.nvim_open_win(buf, true, {
    relative = "cursor",
    width = width,
    height = height,
    row = below and 1 or -(height + 2),
    col = 0,
    border = "rounded",
    title = " " .. title .. " ",
    footer = M.input_footer(),
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
    if api.nvim_win_is_valid(origin) then
      api.nvim_set_current_win(origin)
    end
    vim.cmd.stopinsert()
  end
  ---@param alt? boolean <M-s>: the opposite of what <C-s> does
  local function submit(alt)
    local text = vim.trim(table.concat(api.nvim_buf_get_lines(buf, 0, -1, false), "\n"))
    close()
    if text ~= "" and on_submit(text, (alt == true) ~= (M.config.auto_poke == true)) == false then
      input(title, on_submit, text) -- not saved: keep what was typed
    end
  end
  local o = { buffer = buf, nowait = true }
  local ik = keys.group("input")
  keys.set({ "n", "i" }, ik.submit, submit, o)
  keys.set({ "n", "i" }, ik.submit_alt, function() submit(true) end, o)
  keys.set("n", ik.submit_normal, submit, o)
  keys.set("n", ik.cancel, close, o)
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
  local quote = M.quote(t, 60)
  local lines = {
    string.format("`%s:%s`%s · %s · needs %s%s", t.file, loc, quote and (" on " .. quote) or "", t.status, t.needs,
      t.approved and " · change approved" or ""),
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
---Footer of the thread window: its keys, as configured, as many as fit in
---`width` (the most useful first; `?` lists them all).
function M.thread_footer(width)
  local tk = keys.group("thread")
  local function pair(a, b, what)
    local la, lb = keys.label(tk[a]), keys.label(tk[b])
    return (la and lb) and (la .. "/" .. lb .. " " .. what) or nil
  end
  local function one(name, what)
    local k = keys.list(tk[name])[1]
    return k and (k .. " " .. what) or nil
  end
  -- { text, priority }, in display order
  local items = {
    { pair("next", "prev", "next/prev"), 6 },
    { pair("next_file", "prev_file", "across files"), 8 },
    { one("reply", "reply"), 1 },
    { one("edit", "edit"), 7 },
    { one("send", "send"), 2 },
    { one("resolve", "resolve"), 3 },
    { M.config.agent_changes ~= "auto" and one("approve", "approve change") or nil, 10 },
    { one("delete", "delete"), 9 },
    { one("help", "keys"), 4 },
    { one("close", "close"), 5 },
  }
  local order = {}
  for i, it in ipairs(items) do
    if it[1] then
      order[#order + 1] = i
    end
  end
  table.sort(order, function(a, b) return items[a][2] < items[b][2] end)
  local keep, used = {}, 2
  for _, i in ipairs(order) do
    local w = vim.fn.strdisplaywidth(items[i][1]) + 3
    if not width or used + w <= width - 2 then
      keep[i], used = true, used + w
    end
  end
  local parts = {}
  for i, it in ipairs(items) do
    if keep[i] then
      parts[#parts + 1] = it[1]
    end
  end
  return " " .. table.concat(parts, " · ") .. " "
end

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
      footer = M.thread_footer(width),
      footer_pos = "right",
      style = "minimal",
    })
    vim.wo[win].wrap = true
    vim.wo[win].linebreak = true
    vim.wo[win].conceallevel = 2 -- hide ** and ` without render-markdown too
    vim.wo[win].concealcursor = "n"
    float ={ buf = buf, win = win, root = root, tid = tid }
    local o = { buffer = buf, nowait = true }
    local tk = keys.group("thread")
    keys.set("n", tk.close, function() api.nvim_win_close(win, true) end, o)
    keys.set("n", tk.reply, function() M.reply(root, tid) end, o)
    keys.set("n", tk.edit, function() M.edit(root, tid) end, o)
    keys.set("n", tk.send, function() M.poke(root) end, o)
    keys.set("n", tk.help, function() M.help("thread") end, o)
    keys.set("n", tk.resolve, function() M.toggle_resolved(root, tid) end, o)
    keys.set("n", tk.approve, function() M.toggle_approved(root, tid) end, o)
    keys.set("n", tk.delete, function() M.delete(root, tid) end, o)
    -- Step to the neighbouring thread in the source buffer without closing.
    local function step(dir)
      if not api.nvim_win_is_valid(src_win) then
        return
      end
      local count = vim.v.count1
      api.nvim_set_current_win(src_win)
      M.jump(dir, count)
      local r2, t2, many = M.thread_at_cursor()
      t2 = t2 or (many and many[1])
      if t2 then
        M.open_thread(r2, t2)
      end
    end
    local km = M.config.keymaps or {}
    keys.set("n", tk.next, function() step(1) end, o)
    keys.set("n", km.next, function() step(1) end, o)
    keys.set("n", tk.prev, function() step(-1) end, o)
    keys.set("n", km.prev, function() step(-1) end, o)
    keys.set("n", tk.next_file, function() M.step_project(src_win, root, tid, 1, vim.v.count1) end, o)
    keys.set("n", tk.prev_file, function() M.step_project(src_win, root, tid, -1, vim.v.count1) end, o)
  end
  vim.bo[buf].modifiable = true
  api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  M.color_authors(buf, lines)
  if refresh then
    api.nvim_win_set_height(win, math.min(#lines, math.floor(vim.o.lines / 2)))
  end
end

---Close the thread window for a while (e.g. while a picker is up, so the two
---floats do not overlap). Returns a function that brings it back.
---@return fun()
function M.suspend_thread()
  if not (float and api.nvim_win_is_valid(float.win)) then
    return function() end
  end
  local f = float
  api.nvim_win_close(f.win, true)
  return function()
    -- scheduled: the picker may still be closing when it calls back
    vim.schedule(function()
      if not (float and api.nvim_win_is_valid(float.win)) then
        M.open_thread(f.root, f.tid)
      end
    end)
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
  M.goto_thread(src_win, root, t)
end

---Show thread `t` in `win` (the PR diff, or the file), cursor on its line, and
---open its conversation.
function M.goto_thread(win, root, t)
  api.nvim_set_current_win(win)
  local path = session.thread_path(root, t)
  local pr = session.load(root)
  if session.is_snapshots(pr) then
    require("code-review.commits").ensure_current(root, t)
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
  local line = math.max(1, math.min(thread_line(buf, t), api.nvim_buf_line_count(buf)))
  api.nvim_win_set_cursor(0, { line, 0 })
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
  { "approve", "let the agent change the code for this thread (again: withdraw)" },
  { "next", "next thread in this file" },
  { "prev", "previous thread in this file" },
  { "next_yours", "next thread waiting for you" },
  { "prev_yours", "previous thread waiting for you" },
  { "inline", "show / hide conversations under the code" },
  { "find_thread", "pick a thread (with preview)" },
  { "find_file", "PR: pick a file (with preview)" },
  { "commits", "review this branch's commits one at a time" },
  { "find_commit", "commits: pick a commit" },
  { "list", "open threads → quickfix (waiting for you first)" },
  { "list_all", "all threads, resolved too → quickfix" },
  { "poke", "poke the agent (herdr, else background claude)" },
  { "output", "show / hide the agent's live output" },
  { "auto_poke", "toggle: <C-s> also sends to the agent" },
  { "next_file", "PR: next unreviewed file" },
  { "prev_file", "PR: previous unreviewed file" },
  { "next_commit", "commits: next commit" },
  { "prev_commit", "commits: previous commit" },
  { "viewed", "PR: mark the file viewed and move on" },
  { "layout", "PR: split / unified diff" },
  { "recent", "resume a recent PR review" },
  { "panel", "threads: float / docked conversation panel" },
  { "description", "PR: title and description" },
  { "help", "this help" },
}

-- Keys of each window: { group, binding (or a literal key in brackets), what it does }.
local HELP_CONTEXT = {
  panel = {
    title = "Conversation panel",
    keys = {
      { "thread", "reply", "write a reply (input box)" },
      { "input", "submit", "send (in the input box; <CR> too in normal mode)" },
      { "input", "submit_alt", "send and poke the agent" },
      { "thread", "edit", "edit your last message" },
      { "thread", "resolve", "resolve / reopen" },
      { "thread", "approve", "approve / withdraw a code change" },
      { "thread", "delete", "delete the thread" },
      { "thread", "send", "poke the agent" },
      { "thread", "close", "close the panel" },
    },
  },
  thread = {
    title = "Thread window",
    keys = {
      { "thread", "next", "next thread in the file" },
      { "thread", "prev", "previous thread in the file" },
      { "thread", "next_file", "next thread across files" },
      { "thread", "prev_file", "previous thread across files" },
      { "thread", "reply", "reply (in the box: submit saves, submit_alt saves + sends to the agent)" },
      { "thread", "edit", "edit your last message" },
      { "thread", "send", "send to the agent (poke)" },
      { "thread", "resolve", "resolve / reopen" },
      { "thread", "approve", "approve / withdraw a code change" },
      { "thread", "delete", "delete the thread" },
      { "thread", "close", "close" },
    },
  },
  list = {
    title = "Thread list (quickfix)",
    keys = {
      { nil, "<CR> / click", "jump to the thread and open it" },
      { "thread", "reply", "reply (in the box: submit saves, submit_alt saves + sends to the agent)" },
      { "thread", "edit", "edit your last message" },
      { "thread", "resolve", "resolve / reopen" },
      { "thread", "approve", "approve / withdraw a code change" },
      { "thread", "delete", "delete the thread" },
      { "thread", "send", "send to the agent (poke)" },
      { "thread", "close", "close the list" },
    },
  },
  sidebar = {
    title = "Sidebar",
    keys = {
      { "sidebar", "open", "open the file / fold a folder" },
      { "sidebar", "fold", "fold a folder" },
      { "sidebar", "viewed", "mark viewed (or not) and go to the next" },
      { "sidebar", "filter", "filter: all / unviewed / with threads / waiting for you / changed since last review" },
      { "sidebar", "reload", "reload the PR (new commits)" },
      { "sidebar", "since", "changes since your last review / whole PR" },
      { nil, "next_file", "next unreviewed file" },
      { nil, "prev_file", "previous unreviewed file" },
      { "sidebar", "description", "PR description" },
      { "sidebar", "refresh", "refresh" },
      { "sidebar", "close", "close the sidebar (:CodeReview files reopens)" },
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
    local km, rows = M.config.keymaps or {}, {}
    for _, k in ipairs(ctx.keys) do
      -- a binding of the group, a global binding (no group), or a literal ("<CR> / click")
      local label
      if k[1] then
        label = keys.label(keys.group(k[1])[k[2]])
      elseif km[k[2]] ~= nil then
        label = keys.label(km[k[2]])
      else
        label = k[2]
      end
      if label then
        rows[#rows + 1] = { label, k[3] }
      end
    end
    section(ctx.title, rows)
  end
  local km, rows = M.config.keymaps or {}, {}
  for _, item in ipairs(HELP_GLOBAL) do
    local label = keys.label(km[item[1]]) -- unmapped (false/nil) keys are left out
    if label then
      rows[#rows + 1] = { label, item[2] }
    end
  end
  section("Anywhere", rows)
  vim.list_extend(lines, {
    "Commands: :CodeReview pr <url> · recent · reload · since · files [left|right|bottom|top]",
    "          · commits [range|next|prev|pick] · layout [split|unified] · panel · find · threads [all] · list [all|yours] · poke [pick] · autopoke · chat · inline · stop",
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
  width = math.max(1, math.min(width + 2, vim.o.columns - 4))
  local height = math.max(1, math.min(#lines, vim.o.lines - 4)) -- a tiny screen still gets a window
  local buf = api.nvim_create_buf(false, true)
  api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].bufhidden = "wipe"
  help_win = api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width,
    height = height,
    row = math.max(0, math.floor((vim.o.lines - height) / 2) - 1),
    col = math.max(0, math.floor((vim.o.columns - width) / 2)),
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
    local parts = { s.kind == "commits" and require("code-review.diff").label(s) or string.format("%s/%s#%s", s.owner or "?", s.repo or "?", s.number or "?") }
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
  require("code-review.poke").send(root, opts)
end

---Poke after a comment was saved, when it was sent to the agent (`now`: <M-s>,
---or <C-s> with config.auto_poke).
local function maybe_poke(root, now)
  if now then
    M.poke(root)
  end
end

---Turn automatic poking on <C-s> on or off.
function M.toggle_auto_poke()
  M.config.auto_poke = not M.config.auto_poke
  notify(M.config.auto_poke and "<C-s> now saves and sends to the agent (<M-s>: save only)"
    or "<C-s> now only saves (<M-s>: save and send to the agent)")
  local panel = require("code-review.panel")
  if panel.is_open() then
    panel.render() -- its key hints follow the setting
  end
end

local last_jump -- { buf, row, col, tid }: the thread ]r / [r landed on

---The thread under the cursor: the one ]r / [r just landed on, else the
---smallest selected text the cursor is in, else the only thread on the line.
---When the line has several, `tid` is nil and `many` lists them.
---@return string? root, string? tid, string[]? many
function M.thread_at_cursor()
  local buf = api.nvim_get_current_buf()
  local root = buf_info(buf)
  local cur = api.nvim_win_get_cursor(0)
  local row, col = cur[1] - 1, cur[2]
  local on_row, inside = threads_at(buf, row, col)
  local j = last_jump
  if j and j.buf == buf and j.row == row and j.col == col and vim.tbl_contains(on_row, j.tid) then
    return root, j.tid
  end
  if inside[1] then
    return root, inside[1]
  end
  if #on_row == 1 then
    return root, on_row[1]
  end
  if #on_row > 1 then
    return root, nil, on_row
  end
end

---Let the user pick one of the threads `tids` (all on one line), then fn(root, tid).
function M.pick_thread(root, tids, fn)
  local data = safe_read(root)
  local items = {}
  for _, tid in ipairs(tids) do
    local t = data and store.find(data, tid)
    if t then
      items[#items + 1] = t
    end
  end
  if #items == 0 then
    return
  end
  local width = 0
  local whats = {}
  for i, t in ipairs(items) do
    local r = t.range
    whats[i] = M.quote(t, 30) or (r.start == r["end"] and "whole line" or string.format("whole lines %d–%d", r.start, r["end"]))
    width = math.max(width, vim.fn.strdisplaywidth(whats[i]))
  end
  local index = {}
  for i, t in ipairs(items) do
    index[t] = i
  end
  vim.ui.select(items, {
    prompt = string.format("%d threads on this line:", #items),
    format_item = function(t)
      local what = whats[index[t]]
      local last = t.messages[#t.messages]
      local who = last.author == "user" and "you" or last.author
      return string.format("%s%s   %s: %s", what, string.rep(" ", width - vim.fn.strdisplaywidth(what)), who, first_line(last.body))
    end,
  }, function(t)
    if t then
      fn(root, t.id)
    end
  end)
end

---Run fn(root, tid) on the thread under the cursor, asking which one when the
---line has several.
function M.with_thread_at_cursor(fn)
  local root, tid, many = M.thread_at_cursor()
  if tid then
    return fn(root, tid)
  end
  if not many then
    return notify("no thread under cursor", vim.log.levels.WARN)
  end
  M.pick_thread(root, many, fn)
end

---Columns of a character selection from (line1, c1) to (line2, c2) (1-based,
---as getpos() gives them), fitted to `lines`: the end goes to the last byte of
---its character; past the end of a line ($) means its end. nil when the
---selection is better kept as whole lines (empty, or every column of them).
---@return integer? start_col, integer? end_col
function M.selection_cols(lines, line1, line2, c1, c2)
  local first, last = lines[line1] or "", lines[line2] or ""
  if #first == 0 or #last == 0 then
    return nil
  end
  local sc = math.max(1, math.min(c1, #first))
  local ec = math.min(c2, #last)
  if vim.o.selection == "exclusive" and c2 <= #last then
    ec = ec - 1
  end
  if ec < 1 then
    return nil
  end
  ec = ec + vim.str_utf_end(last, ec) -- a multibyte character is selected whole
  sc = sc + vim.str_utf_start(first, sc)
  if (line1 == line2 and ec < sc) or (sc == 1 and ec == #last) then
    return nil
  end
  return sc, ec
end

---Short quote of a thread's selected text, for titles: `"retry_delay_ms * …"`.
function M.quote(t, max)
  local span = anchor.cols(t) and (t.anchor or {}).span
  if not span then
    return nil
  end
  span = vim.trim(span:gsub("%s+", " "))
  max = max or 40
  if vim.fn.strchars(span) > max then
    span = vim.fn.strcharpart(span, 0, max - 1) .. "…"
  end
  return '"' .. span .. '"'
end

---Comment on lines line1..line2, or on the selected text in them when `cols`
---({ c1, c2 }, from getpos()) is given.
function M.add(line1, line2, cols)
  local buf = api.nvim_get_current_buf()
  local root, rel, side, _, commit = buf_info(buf)
  if not root then
    return notify("buffer is not a file inside a project", vim.log.levels.WARN)
  end
  if vim.bo[buf].modified then
    notify("buffer has unsaved changes; save it so agents see the same code", vim.log.levels.WARN)
  end
  if side == "both" then -- unified view: rows → the side and lines they show
    local why
    local rows = line2 - line1
    side, line1, line2 = require("code-review.unified").translate(buf, line1, line2)
    if side and line2 - line1 ~= rows then
      cols = nil -- the selection crossed removed and added rows: keep the lines
    end
    if not side then
      why = line1 -- translate's reason, when it has one
      return notify(type(why) == "string" and why or "this line only existed in your last review; comment on the current code",
        vim.log.levels.WARN)
    end
  end
  -- the anchor is taken from the text of that side (a unified buffer mixes both)
  local lines = vim.b[buf].code_review_unified and (session.lines(root, rel, { side = side }) or {})
    or api.nvim_buf_get_lines(buf, 0, -1, false)
  local pr = session.load(root)
  local base = side == "old" and pr and pr.base_sha or nil
  local where = side == "old" and " (old side)" or ""
  local sc, ec
  if cols then
    sc, ec = M.selection_cols(lines, line1, line2, cols[1], cols[2])
  end
  local a = anchor.capture(lines, line1, line2, sc, ec)
  local quote = M.quote({ range = { start_col = sc, end_col = ec }, anchor = a })
  input(string.format("Comment on %s:%d-%d%s%s", rel, line1, line2, where, quote and (" " .. quote) or ""), function(body, now)
    local saved, tid = try_update(root, function(data)
      return store.add_thread(data, {
        file = rel,
        side = side,
        base = base,
        start = line1,
        ["end"] = line2,
        start_col = sc,
        end_col = ec,
        anchor = a,
        author = "user",
        body = body,
        commit = commit,
      })
    end)
    if not saved then
      return false
    end
    after_write(root)
    -- open the thread first: a poke that asks which agent hides it while the
    -- picker is up, and brings it back afterwards
    if now and M.config.open_after_send and tid then
      M.open_thread(root, tid)
    end
    if now then
      M.poke(root) -- asks which agent itself when none is chosen
    else
      require("code-review.poke").choose_if_unset(root)
    end
  end)
end

function M.reply(root, tid)
  input("Reply to " .. tid, function(body, now)
    local gone
    local saved = try_update(root, function(data)
      local t = store.find(data, tid)
      if not t then
        gone = true -- deleted meanwhile (by the agent, or in another window)
        return store.UNCHANGED
      end
      store.add_message(t, "user", body)
      if t.status == "resolved" then
        t.status = "open"
      end
    end)
    if not saved then
      return false
    end
    if gone then
      vim.fn.setreg('"', body)
      return notify(tid .. " was deleted; your reply is in the \" register", vim.log.levels.WARN)
    end
    after_write(root)
    maybe_poke(root, now)
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
  input("Edit your comment (" .. tid .. ")", function(body, now)
    local refused
    local saved = try_update(root, function(d)
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
    if not saved then
      return false
    end
    if refused then
      vim.fn.setreg('"', body)
      notify("not saved: " .. refused .. "; your text is in the \" register", vim.log.levels.WARN)
    end
    after_write(root)
    if not refused then
      maybe_poke(root, now)
    end
  end, last.body)
end

function M.toggle_resolved(root, tid)
  if not try_update(root, function(data)
    local t = store.find(data, tid)
    if t then
      t.status = t.status == "resolved" and "open" or "resolved"
    end
  end) then
    return
  end
  -- reopened threads may no longer match the code
  for _, buf in ipairs(api.nvim_list_bufs()) do
    if api.nvim_buf_is_loaded(buf) and buf_info(buf) == root then
      M.render(buf, true)
    end
  end
  after_write(root)
end

---Let the agent change the code for thread `tid` once (with agent_changes =
---"discuss": until its next reply), or withdraw that. Either is a message in the
---thread, sent to the agent straight away.
function M.toggle_approved(root, tid)
  local pr = session.load(root)
  if pr and pr.kind == "pr" then
    return notify("a PR review has no checkout: the agent proposes changes as suggestions", vim.log.levels.WARN)
  end
  if M.config.agent_changes == "auto" then
    return notify("agent_changes = \"auto\": the agent changes the code without approval", vim.log.levels.WARN)
  end
  local on
  if not try_update(root, function(data)
    local t = store.find(data, tid)
    if not t then
      return store.UNCHANGED
    end
    on = not t.approved
    store.set_approved(t, on)
  end) or on == nil then
    return
  end
  after_write(root)
  notify(on and ("change approved for " .. tid) or ("approval withdrawn for " .. tid))
  M.poke(root) -- an approval (or withdrawing it) is meant for the agent now, not on the next send
end

function M.delete(root, tid)
  if vim.fn.confirm("Delete thread " .. tid .. "?", "&Yes\n&No", 2) ~= 1 then
    return
  end
  if not try_update(root, function(data)
    local _, i = store.find(data, tid)
    if i then
      table.remove(data.threads, i)
    end
  end) then
    return
  end
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

---Whose turn a thread is, for lists: label, sort rank and quickfix type.
---@return { label: string, rank: integer, type: string, yours: boolean }
function M.waiting(t)
  if t.status == "resolved" then
    return { label = "✓ resolved", rank = 3, type = "", yours = false }
  elseif t.needs == "user" then
    return { label = "● waiting for you", rank = 0, type = "W", yours = true }
  elseif t.needs == "agent" then
    return { label = "○ waiting for agent", rank = 1, type = "I", yours = false }
  end
  return { label = "· open", rank = 2, type = "", yours = false }
end

---Threads for a list, those waiting for you first, then by file and line.
---@param mode? boolean|"all"|"yours" true / "all": resolved too; "yours": only waiting for you
function M.list_threads(threads, mode)
  local all = mode == true or mode == "all"
  local res = {}
  for _, t in ipairs(threads) do
    local w = M.waiting(t)
    if mode == "yours" and w.yours or mode ~= "yours" and (all or t.status ~= "resolved") then
      res[#res + 1] = t
    end
  end
  table.sort(res, function(a, b)
    local ra, rb = M.waiting(a).rank, M.waiting(b).rank
    if ra ~= rb then
      return ra < rb
    end
    if a.file ~= b.file then
      return a.file < b.file
    end
    return a.range.start < b.range.start
  end)
  return res
end

-- Color the turn labels in the quickfix window like the signs.
local function color_qf(win)
  for _, id in ipairs(vim.w[win].code_review_matches or {}) do
    pcall(vim.fn.matchdelete, id, win)
  end
  vim.w[win].code_review_matches = {
    vim.fn.matchadd("CodeReviewNeedsUser", [[● waiting for you]], 20, -1, { window = win }),
    vim.fn.matchadd("CodeReviewNeedsAgent", [[○ waiting for agent]], 20, -1, { window = win }),
    vim.fn.matchadd("CodeReviewDim", [[✓ resolved]], 20, -1, { window = win }),
  }
end

-- Display rows of the thread lists, by quickfix list id: { loc, turn, rest }.
local qf_rows = {}

local function pad(text, width)
  return text .. string.rep(" ", width - vim.fn.strdisplaywidth(text))
end

---quickfixtextfunc of the thread list: aligned columns (location, whose turn,
---message), whatever the file name lengths and labels are.
function M.qf_text(info)
  local rows = qf_rows[info.id]
  if not rows or info.quickfix ~= 1 then
    return {}
  end
  local w_loc, w_turn = 0, 0
  for _, r in ipairs(rows) do -- widths over the whole list, so every line agrees
    w_loc = math.max(w_loc, vim.fn.strdisplaywidth(r.loc))
    w_turn = math.max(w_turn, vim.fn.strdisplaywidth(r.turn))
  end
  local out = {}
  for i = info.start_idx, info.end_idx do
    local r = rows[i]
    out[#out + 1] = r and (pad(r.loc, w_loc) .. "  " .. pad(r.turn, w_turn) .. "  " .. r.rest) or ""
  end
  return out
end

---Threads of the project in the quickfix list.
---@param mode? boolean|"all"|"yours" true / "all": resolved too; "yours": only those waiting for you
---Items, display rows and title of the thread list of `root`.
local function thread_list(root, data, mode)
  local items, rows, yours, agent = {}, {}, 0, 0
  for _, t in ipairs(M.list_threads(data.threads, mode)) do
    local last = t.messages[#t.messages]
    local w = M.waiting(t)
    yours = yours + (w.yours and 1 or 0)
    agent = agent + (w.rank == 1 and 1 or 0)
    local turn = w.label .. (t.status == "outdated" and " · outdated" or "") .. (t.side == "old" and " · old side" or "")
    local rest = string.format("%s: %s", last.author == "user" and "you" or last.author, first_line(last.body))
    rows[#rows + 1] = { loc = string.format("%s:%d", t.file, t.range.start), turn = turn, rest = rest }
    items[#items + 1] = {
      filename = session.thread_path(root, t),
      lnum = t.range.start,
      end_lnum = t.range["end"],
      col = anchor.cols(t), -- the selected text, for threads that have one
      end_col = select(2, anchor.cols(t)),
      type = w.type, -- warning / info: Trouble, fzf-lua etc. color by it
      text = turn .. " · " .. rest, -- what other tools show
      user_data = t.id,
    }
  end
  return items, rows, string.format("Code review · %d waiting for you · %d waiting for agent", yours, agent)
end

function M.list(mode)
  local root = current_root()
  local data = safe_read(root)
  if not data then
    return
  end
  local items, rows, title = thread_list(root, data, mode)
  vim.fn.setqflist({}, " ", {
    title = title,
    items = items,
    quickfixtextfunc = "v:lua.require'code-review'.qf_text",
    context = { code_review_root = root, code_review_mode = mode or false }, -- <CR> / a click opens the thread (see open_qf_item)
  })
  qf_rows[vim.fn.getqflist({ id = 0 }).id] = rows -- per list, so :colder still shows older ones aligned
  if #items == 0 then
    return notify(mode == "yours" and "nothing waits for you" or "no threads")
  end
  vim.cmd.copen()
  local win = api.nvim_get_current_win()
  vim.wo[win].wrap = false -- one thread per line, long messages are cut at the edge
  color_qf(win)
end

---After a change to the store: redraw the thread list of `root` in place (same
---list, cursor kept on the same row as far as it still exists).
function M.refresh_qf(root, data)
  local qf = vim.fn.getqflist({ id = 0, context = 1, winid = 0, idx = 0 })
  local ctx = qf.context
  if not (type(ctx) == "table" and ctx.code_review_root == root) then
    return
  end
  local cursor = qf.winid ~= 0 and api.nvim_win_get_cursor(qf.winid)
  local items, rows, title = thread_list(root, data, ctx.code_review_mode)
  qf_rows[qf.id] = rows
  vim.fn.setqflist({}, "r", { id = qf.id, items = items, title = title, idx = math.max(1, math.min(qf.idx, #items)) })
  if cursor and #items > 0 then
    pcall(api.nvim_win_set_cursor, qf.winid, { math.min(cursor[1], #items), cursor[2] })
  end
end

---The thread under the cursor of the thread list (when in it).
---@return string? root
---@return string? tid
function M.qf_thread()
  local wininfo = vim.fn.getwininfo(api.nvim_get_current_win())[1]
  if not (wininfo and wininfo.quickfix == 1 and wininfo.loclist ~= 1 and M.is_thread_list()) then
    return nil
  end
  local item = vim.fn.getqflist()[vim.fn.line(".")]
  if item and type(item.user_data) == "string" then
    return vim.fn.getqflist({ context = 1 }).context.code_review_root, item.user_data
  end
end

---Close the thread list if it is open in this tab with the same `mode`, else
---open it (replacing any other list shown there).
function M.toggle_list(mode)
  local qf = vim.fn.getqflist({ winid = 0, context = 1 })
  local ctx = qf.context
  if qf.winid ~= 0 and type(ctx) == "table" and ctx.code_review_root and ctx.code_review_mode == (mode or false) then
    return vim.cmd.cclose()
  end
  M.list(mode)
end

---Is the quickfix list a thread list of this plugin?
function M.is_thread_list()
  local ctx = vim.fn.getqflist({ context = 1 }).context
  return type(ctx) == "table" and ctx.code_review_root ~= nil
end

---In the quickfix window: if the item under the cursor is a thread of a thread
---list, jump to it and open its conversation.
---@return boolean handled false for any other list (let the caller do the default)
function M.open_qf_item()
  local wininfo = vim.fn.getwininfo(api.nvim_get_current_win())[1]
  if not wininfo or wininfo.quickfix ~= 1 or wininfo.loclist == 1 then
    return false
  end
  local ctx = vim.fn.getqflist({ context = 1 }).context
  local root = type(ctx) == "table" and ctx.code_review_root
  local item = vim.fn.getqflist()[vim.fn.line(".")]
  if not (root and item and type(item.user_data) == "string") then
    return false
  end
  local data = safe_read(root)
  local t = data and store.find(data, item.user_data)
  if not t then
    notify("that thread no longer exists", vim.log.levels.WARN)
    return true
  end
  vim.fn.setqflist({}, "a", { idx = vim.fn.line(".") }) -- keep :cnext going from here
  -- the window the list belongs to: the previous one, else any normal window
  local target = vim.fn.win_getid(vim.fn.winnr("#"))
  if target == 0 or target == api.nvim_get_current_win() or vim.fn.win_gettype(target) ~= "" then
    target = nil
    for _, w in ipairs(api.nvim_tabpage_list_wins(0)) do
      if vim.fn.win_gettype(w) == "" and vim.bo[api.nvim_win_get_buf(w)].buftype == "" then
        target = w
        break
      end
    end
  end
  if not target then
    vim.cmd("aboveleft split")
    target = api.nvim_get_current_win()
  end
  M.goto_thread(target, root, t)
  return true
end

---Jump to the next (dir = 1) or previous (dir = -1) thread in the current
---buffer, wrapping around. Only visible threads count (resolved ones are
---skipped unless show_resolved is on).
function M.jump(dir, count)
  local buf = api.nvim_get_current_buf()
  -- one stop per thread: its selected text, else its first line
  local by_tid, stops = {}, {}
  for i, m in ipairs(api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })) do
    local tid = marks[buf] and marks[buf][m[1]]
    local stid = span_marks[buf] and span_marks[buf][m[1]]
    if m[4].invalid then
    elseif tid and not by_tid[tid] then
      by_tid[tid] = { tid = tid, row = m[2], i = i }
      stops[#stops + 1] = by_tid[tid]
    elseif stid then
      by_tid[stid] = by_tid[stid] or { tid = stid, i = i }
      by_tid[stid].span = { m[2], m[3] }
    end
  end
  stops = vim.tbl_filter(function(st) return st.row ~= nil end, stops)
  if #stops == 0 then
    return notify("no comments in this buffer")
  end
  for _, st in ipairs(stops) do
    if st.span then
      st.row, st.col = st.span[1], st.span[2]
    end
  end
  -- by row; on a row, threads on whole lines first, then by column
  table.sort(stops, function(a, b)
    if a.row ~= b.row then
      return a.row < b.row
    end
    if (a.col == nil) ~= (b.col == nil) then
      return a.col == nil
    end
    if a.col ~= b.col then
      return a.col < b.col
    end
    return a.i < b.i
  end)
  -- where a stop is from the cursor: a thread on whole lines is compared by row only
  local function cmp(st, row, col)
    if st.row ~= row then
      return st.row < row and -1 or 1
    end
    if st.col == nil then
      return 0
    end
    return st.col < col and -1 or st.col > col and 1 or 0
  end
  local cur = api.nvim_win_get_cursor(0)
  local row, col = cur[1] - 1, cur[2]
  local at -- index of the stop ]r / [r last landed on, when the cursor is still there
  local j = last_jump
  if j and j.buf == buf and j.row == row and j.col == col then
    for k, st in ipairs(stops) do
      if st.tid == j.tid then
        at = k
      end
    end
  end
  local target
  for _ = 1, math.max(1, count or 1) do
    local nxt
    if at then
      nxt = (at - 1 + dir) % #stops + 1
    elseif dir > 0 then
      for k, st in ipairs(stops) do
        if cmp(st, row, col) > 0 then
          nxt = k
          break
        end
      end
      nxt = nxt or 1
    else
      for k = #stops, 1, -1 do
        if cmp(stops[k], row, col) < 0 then
          nxt = k
          break
        end
      end
      nxt = nxt or #stops
    end
    at, target = nxt, stops[nxt]
    row, col = target.row, target.col or 0
  end
  vim.cmd("normal! m'") -- add to jumplist
  api.nvim_win_set_cursor(0, { target.row + 1, target.col or 0 })
  if not target.col then
    vim.cmd("normal! ^")
  end
  local pos = api.nvim_win_get_cursor(0)
  last_jump = { buf = buf, row = pos[1] - 1, col = pos[2], tid = target.tid }
  M.flash()
end

M.prompt = [[I left review comments on the code for you. Run `code-review list --needs agent` to see them (`code-review skill` explains the workflow). Reply in each thread with `code-review reply <id> "..."`, change the code only for threads marked `change approved` (propose other changes as a ```suggestion block), and only resolve a thread with `code-review resolve <id>` once it is settled.]]

---The prompt for the agent; in a PR review every command needs `--pr`.
---The prompt for the agent: every thread waiting on it, in full (for copying).
function M.prompt_for(root)
  if not root then
    return M.prompt
  end
  local prompt = require("code-review.prompt")
  return prompt.build(root, { style = "plain", all = true }) or prompt.generic(root)
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
  if session.is_snapshots(pr) then
    require("code-review.commits").ensure_current(root, target)
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
    M.with_thread_at_cursor(M.open_thread)
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
    local root = session.infer(api.nvim_buf_get_name(0)) or current_root()
    require("code-review.progress").stop()
    if root and require("code-review.headless").stop(root) then
      notify("stopped the background agent")
    end
  end,
  autopoke = function()
    M.toggle_auto_poke()
  end,
  chat = function()
    local root = session.infer(api.nvim_buf_get_name(0)) or require("code-review.diff").where() or current_root()
    require("code-review.headless").chat(root)
  end,
  poke = function(o)
    local root = session.infer(api.nvim_buf_get_name(0)) or current_root()
    M.poke(root, { pick = o and o.fargs and o.fargs[2] == "pick" })
  end,
  edit = function()
    M.with_thread_at_cursor(M.edit)
  end,
  resolve = function()
    M.with_thread_at_cursor(M.toggle_resolved)
  end,
  approve = function()
    M.with_thread_at_cursor(M.toggle_approved)
  end,
  delete = function()
    M.with_thread_at_cursor(M.delete)
  end,
  list = function(o)
    local arg = o.fargs[2]
    M.list(arg == "all" and "all" or arg == "yours" and "yours" or false)
  end,
  next = function()
    M.jump(1)
  end,
  prev = function()
    M.jump(-1)
  end,
  copy = M.copy_prompt,
  commits = function(o)
    local arg = o and o.fargs and o.fargs[2]
    local commits = require("code-review.commits")
    local root = require("code-review.diff").where()
    local s = root and session.load(root)
    local here = s and s.kind == "commits" and root or nil
    if arg == "next" or arg == "prev" or arg == "pick" then
      here = here or session.local_dirs(commits.repo_root(vim.fn.getcwd()) or vim.fn.getcwd())
      if arg == "pick" then
        return commits.pick(here)
      end
      return commits.step(here, arg == "next" and 1 or -1)
    end
    commits.open(arg)
  end,
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
  -- the selected text of a thread: underlined, so it shows on diff colors too
  local function fg(name)
    return (api.nvim_get_hl(0, { name = name, link = false }) or {}).fg
  end
  api.nvim_set_hl(0, "CodeReviewSpan", { underline = true, sp = fg("DiagnosticInfo"), default = true })
  api.nvim_set_hl(0, "CodeReviewSpanResolved", { underdotted = true, sp = fg("NonText"), default = true })
  api.nvim_set_hl(0, "CodeReviewOutdated", { strikethrough = true, link = nil, default = true, fg = (api.nvim_get_hl(0, { name = "Comment", link = false }) or {}).fg })
  set("CodeReviewAuthorYou", "DiagnosticInfo") -- the same colors everywhere: thread window, inline, summary
  set("CodeReviewAuthorAgent", "DiagnosticHint")
  require("code-review.diff").highlights()
end

local DEFAULTS -- M.config before the first setup

-- Options whose value is one of a few, or of more than one type.
local CHOICES = {
  conversation = { "float", "panel" },
  agent_changes = { "discuss", "auto" },
  agent = { "auto", "herdr", "headless" },
  isolate = { "fork", "subagent", false },
  progress_float = { true, false, "auto" },
  icons = { true, false, "auto" },
  diff_layout = { "split", "unified" },
  sidebar_position = { "left", "right", "bottom", "top" },
}
local NUMBERS = { panel_width = true, sidebar_width = true, sidebar_height = true } -- default nil
local NUMBER_OR_FALSE = { flash_ms = true }

---Check the user's options against the defaults: a wrong one is reported and
---dropped (its default is used), instead of failing later somewhere unrelated.
---@return table opts the options to use
---@return string[] problems
local function validate(opts, defaults)
  local out, problems = {}, {}
  local function bad(name, why)
    problems[#problems + 1] = string.format("%s %s; using the default", name, why)
  end
  for k, v in pairs(opts) do
    local d = defaults[k]
    if k == "keymaps" then
      out[k] = v -- checked by keys.validate
    elseif CHOICES[k] then
      if vim.tbl_contains(CHOICES[k], v) then
        out[k] = v
      else
        bad(k, "must be one of " .. table.concat(vim.tbl_map(vim.inspect, CHOICES[k]), ", "))
      end
    elseif NUMBERS[k] then
      if v == nil or type(v) == "number" and v > 0 then
        out[k] = v
      else
        bad(k, "must be a positive number")
      end
    elseif NUMBER_OR_FALSE[k] then
      if v == false or type(v) == "number" then
        out[k] = v
      else
        bad(k, "must be a number or false")
      end
    elseif k == "diff_colors" then
      if type(v) == "boolean" or type(v) == "string" then
        out[k] = v
      else
        bad(k, "must be true, false, \"auto\" or \"github-dark\"")
      end
    elseif d ~= nil and type(v) ~= type(d) then
      bad(k, string.format("must be a %s, not a %s", type(d), type(v)))
    else
      out[k] = v
    end
  end
  local h = type(out.headless) == "table" and out.headless or nil
  if h then
    if h.agent ~= nil and not require("code-review.agents").get(h.agent) then
      bad("headless.agent", string.format("%s is not a known agent (claude, codex, opencode, gemini)", vim.inspect(h.agent)))
      h.agent = nil
    end
    for _, f in ipairs({ "args", "allowed_tools" }) do
      if h[f] ~= nil and not (type(h[f]) == "table" and vim.islist(h[f])) then
        bad("headless." .. f, "must be a list of strings")
        h[f] = nil
      end
    end
  end
  return out, problems
end

function M.setup(opts)
  opts = opts or {}
  -- always from the defaults, so calling setup again (re-sourcing the config) drops old choices
  DEFAULTS = DEFAULTS or vim.deepcopy(M.config)
  local problems
  opts, problems = validate(vim.deepcopy(opts), DEFAULTS)
  local kproblems
  opts.keymaps, kproblems = keys.validate(opts.keymaps, DEFAULTS.keymaps)
  vim.list_extend(problems, kproblems)
  if #problems > 0 then
    vim.schedule(function() -- after startup, so it is seen
      vim.notify("code-review: setup: " .. table.concat(problems, "\n"), vim.log.levels.WARN)
    end)
  end
  local km = keys.merge(DEFAULTS.keymaps, opts.keymaps)
  M.config = vim.tbl_deep_extend("force", vim.deepcopy(DEFAULTS), opts)
  M.config.keymaps = km
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
    keys.set("n", km.add, function()
      local l = api.nvim_win_get_cursor(0)[1]
      M.add(l, l)
    end, { desc = "Code review: add comment" })
    keys.set("x", km.add, function()
      -- v: the selected text; V and <C-v>: whole lines
      local charwise = vim.fn.mode() == "v"
      local p1, p2 = vim.fn.getpos("v"), vim.fn.getpos(".")
      if p1[2] > p2[2] or (p1[2] == p2[2] and p1[3] > p2[3]) then
        p1, p2 = p2, p1
      end
      api.nvim_feedkeys(api.nvim_replace_termcodes("<Esc>", true, false, true), "nx", false)
      M.add(p1[2], p2[2], charwise and { p1[3], p2[3] } or nil)
    end, { desc = "Code review: comment on selection" })
  end
  if km.open then
    keys.set("n", km.open, subcommands.open, { desc = "Code review: open thread" })
  end
  if km.panel then
    keys.set("n", km.panel, function() M.toggle_conversation() end, { desc = "Code review: threads in float / panel" })
  end
  if km.recent then
    keys.set("n", km.recent, function() subcommands.recent() end, { desc = "Code review: recent reviews" })
  end
  if km.layout then
    keys.set("n", km.layout, function() subcommands.layout() end, { desc = "Code review: split / unified diff" })
  end
  if km.find_file then
    keys.set("n", km.find_file, function() subcommands.find() end, { desc = "Code review: pick a PR file" })
  end
  if km.commits then
    keys.set("n", km.commits, function() subcommands.commits() end, { desc = "Code review: review commits one at a time" })
  end
  if km.find_commit then
    keys.set("n", km.find_commit, function() subcommands.commits({ fargs = { "commits", "pick" } }) end,
      { desc = "Code review: pick a commit" })
  end
  if km.find_thread then
    keys.set("n", km.find_thread, function() subcommands.threads() end, { desc = "Code review: pick a thread" })
  end
  if km.help then
    keys.set("n", km.help, function() M.help() end, { desc = "Code review: keys" })
  end
  if km.inline then
    keys.set("n", km.inline, M.toggle_inline, { desc = "Code review: inline conversations" })
  end
  if km.next_yours then
    keys.set("n", km.next_yours, function() M.jump_yours(1) end, { desc = "Code review: next thread waiting for you" })
  end
  if km.prev_yours then
    keys.set("n", km.prev_yours, function() M.jump_yours(-1) end, { desc = "Code review: previous thread waiting for you" })
  end
  if km.output then
    keys.set("n", km.output, function() subcommands.output() end, { desc = "Code review: live agent output" })
  end
  if km.auto_poke then
    keys.set("n", km.auto_poke, M.toggle_auto_poke, { desc = "Code review: toggle sending comments to the agent on <C-s>" })
  end
  if km.poke then
    keys.set("n", km.poke, function() subcommands.poke() end, { desc = "Code review: poke the agent" })
  end
  if km.edit then
    keys.set("n", km.edit, subcommands.edit, { desc = "Code review: edit my comment" })
  end
  if km.resolve then
    keys.set("n", km.resolve, subcommands.resolve, { desc = "Code review: resolve/reopen thread" })
  end
  if km.approve then
    keys.set("n", km.approve, subcommands.approve, { desc = "Code review: approve / withdraw a code change" })
  end
  if km.list then
    keys.set("n", km.list, function() M.toggle_list(false) end, { desc = "Code review: toggle the open threads list" })
  end
  if km.list_all then
    keys.set("n", km.list_all, function() M.toggle_list(true) end, { desc = "Code review: toggle the list of all threads" })
  end
  if km.next then
    keys.set("n", km.next, function() M.jump(1, vim.v.count1) end, { desc = "Code review: next thread" })
  end
  if km.prev then
    keys.set("n", km.prev, function() M.jump(-1, vim.v.count1) end, { desc = "Code review: previous thread" })
  end

  require("code-review.diff").attach_quickfix(group)
  if km.viewed then
    keys.set("n", km.viewed, subcommands.viewed, { desc = "Code review: toggle file viewed" })
  end
  if km.description then
    keys.set("n", km.description, subcommands.description, { desc = "Code review: PR description" })
  end

  if M.config.add_bin_to_path then
    vim.env.PATH = require("code-review.agents").path_with_bin(vim.env.PATH)
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
