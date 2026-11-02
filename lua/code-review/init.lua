-- Neovim UI: signs + virtual text, thread float, reply input, quickfix list,
-- live refresh when an agent writes the store.
local store = require("code-review.store")
local anchor = require("code-review.anchor")

local uv = vim.uv or vim.loop
local api = vim.api

local M = {}

M.config = {
  keymaps = {
    add = "<leader>ca", -- normal: current line, visual: selection
    open = "<leader>cr", -- open thread under cursor (reply from there)
    resolve = "<leader>cx", -- toggle resolved
    list = "<leader>cl", -- open threads in the project -> quickfix
    list_all = "<leader>cL", -- including resolved
    next = "]r", -- next thread in buffer (takes a count)
    prev = "[r", -- previous thread in buffer
  },
  show_resolved = false,
  notify = true, -- notify when an agent replies
  add_bin_to_path = true, -- so agents started from inside Neovim find the CLI
  signs = { user = "▍", agent = "◆", resolved = "✓", outdated = "?" },
}

local ns = api.nvim_create_namespace("code-review")
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
  if not api.nvim_buf_is_valid(buf) or vim.bo[buf].buftype ~= "" then
    return nil
  end
  local name = api.nvim_buf_get_name(buf)
  if name == "" then
    return nil
  end
  name = vim.fs.normalize(vim.fn.fnamemodify(name, ":p"))
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

local function threads_for(data, rel)
  local res = {}
  for _, t in ipairs(data.threads) do
    if t.file == rel then
      res[#res + 1] = t
    end
  end
  return res
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
  local root, rel = buf_info(buf)
  if not root then
    return
  end
  M.watch(root)
  local data = safe_read(root)
  if not data then
    return
  end
  local threads = threads_for(data, rel)
  if reanchor and #threads > 0 then
    local lines = api.nvim_buf_get_lines(buf, 0, -1, false)
    if anchor.reanchor_threads(vim.deepcopy(threads), lines) then
      try_update(root, function(d)
        if not anchor.reanchor_threads(threads_for(d, rel), lines) then
          return store.UNCHANGED
        end
      end)
      data = safe_read(root) or data
      threads = threads_for(data, rel)
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
      local s = math.max(1, math.min(r[1], n)) - 1
      local e = math.max(s + 1, math.min(r[2], n)) - 1
      local sign, sign_hl, virt_hl = style(t)
      local last = t.messages[#t.messages]
      local label = string.format(" %s: %s", last.author, first_line(last.body))
      if #t.messages > 1 then
        label = label .. string.format("  (%d)", #t.messages)
      end
      if t.status == "outdated" then
        label = label .. "  [outdated]"
      end
      local end_line = api.nvim_buf_get_lines(buf, e, e + 1, false)[1] or ""
      local id = api.nvim_buf_set_extmark(buf, ns, s, 0, {
        end_row = e,
        end_col = #end_line,
        sign_text = sign,
        sign_hl_group = sign_hl,
        virt_text = { { "  " .. sign .. label, virt_hl } },
        virt_text_pos = "eol",
        invalidate = true,
        priority = 20,
      })
      marks[buf][id] = t.id
      for row = s + 1, e do
        api.nvim_buf_set_extmark(buf, ns, row, 0, { sign_text = "│", sign_hl_group = sign_hl, priority = 19 })
      end
    end
  end
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
  local root, rel = buf_info(buf)
  local pos = root and live_positions(buf) or {}
  if not next(pos) then
    return
  end
  local lines = api.nvim_buf_get_lines(buf, 0, -1, false)
  try_update(root, function(data)
    local changed = false
    for _, t in ipairs(data.threads) do
      local p = pos[t.id]
      if t.file == rel and p ~= nil and t.status ~= "outdated" then
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
      notify(string.format("%s on %s:%d: %s", last.author, t.file, t.range.start, first_line(last.body)))
    end
  end
  seen[root] = now
  render_root(root)
  if float and float.root == root and api.nvim_win_is_valid(float.win) then
    M.open_thread(root, float.tid, true)
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

local function input(title, on_submit)
  local buf = api.nvim_create_buf(false, true)
  vim.bo[buf].filetype = "markdown"
  vim.bo[buf].bufhidden = "wipe"
  local width = math.min(80, vim.o.columns - 4)
  local win = api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width,
    height = 8,
    row = math.floor((vim.o.lines - 10) / 2),
    col = math.floor((vim.o.columns - width) / 2),
    border = "rounded",
    title = " " .. title .. " ",
    footer = " <C-s> / <CR> submit · q cancel ",
    footer_pos = "right",
  })
  vim.cmd.startinsert()
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
    vim.list_extend(lines, { "", who .. " · " .. m.ts, "" })
    local body = vim.split(m.body, "\n")
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
  return lines
end

---Open (or refresh in place) the thread float.
function M.open_thread(root, tid, refresh)
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
  if refresh and float and api.nvim_win_is_valid(float.win) then
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
      footer = " n/p next/prev · N/P across files · r reply · x resolve · d delete · q close ",
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
  if refresh then
    api.nvim_win_set_height(win, math.min(#lines, math.floor(vim.o.lines / 2)))
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
  local path = root .. "/" .. t.file
  if vim.fs.normalize(api.nvim_buf_get_name(0)) ~= path then
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
  api.nvim_win_set_cursor(src_win, { line, 0 })
  vim.cmd("normal! ^")
  M.open_thread(root, t.id)
end

-- Actions -------------------------------------------------------------------------

local function after_write(root)
  M.watch(root)
  on_store_changed(root)
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
  local root, rel = buf_info(buf)
  if not root then
    return notify("buffer is not a file inside a project", vim.log.levels.WARN)
  end
  if vim.bo[buf].modified then
    notify("buffer has unsaved changes; save it so agents see the same code", vim.log.levels.WARN)
  end
  local lines = api.nvim_buf_get_lines(buf, 0, -1, false)
  input(string.format("Comment on %s:%d-%d", rel, line1, line2), function(body)
    store.update(root, function(data)
      return store.add_thread(data, {
        file = rel,
        start = line1,
        ["end"] = line2,
        anchor = anchor.capture(lines, line1, line2),
        author = "user",
        body = body,
      })
    end)
    after_write(root)
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
  end)
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
        filename = root .. "/" .. t.file,
        lnum = t.range.start,
        end_lnum = t.range["end"],
        text = string.format("[%s · needs %s] %s: %s", t.status, t.needs, last.author, first_line(last.body)),
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
end

M.prompt = [[I left review comments on the code for you. Run `code-review list --needs agent` to see them (`code-review skill` explains the workflow). Reply in each thread with `code-review reply <id> "..."`, make any changes requested, and only resolve a thread with `code-review resolve <id>` once the change is done.]]

function M.copy_prompt()
  vim.fn.setreg('"', M.prompt)
  pcall(vim.fn.setreg, "+", M.prompt)
  notify("agent prompt copied")
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
