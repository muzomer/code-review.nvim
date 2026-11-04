-- PR review sidebar: the changed files as a folder tree beside (or below) the
-- diff, with viewed marks, change counts and comment threads per file.
--
--    acme/api#12 · 3/35 viewed
--   ▾ src/auth/
--   ▶✓ M jwt.py        +40 -12  ✎2
--      A keys.py        +3       ✎1!
--
-- Rows are not file indexes (folders take rows too), so every rendered row is
-- recorded in `rows[buf]`.
local session = require("code-review.session")
local store = require("code-review.store")

local api = vim.api
local M = {}

---Sidebar width: config.sidebar_width, else a quarter of the screen (24..42 columns).
function M.width()
  local w = require("code-review").config.sidebar_width
  return w or math.max(24, math.min(42, math.floor(vim.o.columns * 0.25)))
end

---Panel height when at the top or bottom: config.sidebar_height, else 30% of the screen (6..15 lines).
function M.height()
  local h = require("code-review").config.sidebar_height
  return h or math.max(6, math.min(15, math.floor(vim.o.lines * 0.3)))
end

M.POSITIONS = { left = true, right = true, bottom = true, top = true }

---Where the file list goes: config.sidebar_position = "left" | "right" | "bottom" | "top".
function M.position()
  local p = require("code-review").config.sidebar_position
  return M.POSITIONS[p or ""] and p or "left"
end

---Is the file list a column (left/right) rather than a panel (top/bottom)?
function M.vertical()
  local p = M.position()
  return p == "left" or p == "right"
end

---Where a new diff window goes so it never splits the file list: the far
---opposite edge of the tab.
function M.opposite()
  return ({ left = "right", right = "left", bottom = "above", top = "below" })[M.position()]
end

local ns = api.nvim_create_namespace("code-review-sidebar")
local rows = {} -- buf -> { [row] = { kind = "file", path = ... } | { kind = "dir", dir = ... } }
local collapsed = {} -- root -> { [dir] = true }
local current = {} -- root -> path shown in the diff
local filters = {} -- root -> one of M.FILTERS (nil = "all")

M.FILTERS = { "all", "unviewed", "threads", "yours", "since" }
local FILTER_LABEL = { unviewed = "unviewed", threads = "with threads", yours = "waiting for you", since = "changed since your last review" }

---The filter of the file list of `root`.
function M.filter(root)
  return filters[root] or "all"
end

---Show only some files: "all", "unviewed", "threads" (open threads) or "yours"
---(threads waiting for you). Without `mode`, go to the next one.
function M.set_filter(root, mode)
  if not mode then
    local cur = M.filter(root)
    for i, m in ipairs(M.FILTERS) do
      if m == cur then
        mode = M.FILTERS[i % #M.FILTERS + 1]
      end
    end
    if mode == "since" and not require("code-review.diff").since(root) then
      mode = "all" -- no earlier version to compare with
    end
  end
  filters[root] = mode ~= "all" and mode or nil
  M.render(root)
end

local STATUS = {
  added = { "A", "CodeReviewStatusAdded" },
  removed = { "D", "CodeReviewStatusRemoved" },
  modified = { "M", "CodeReviewStatusModified" },
  renamed = { "R", "CodeReviewStatusRenamed" },
}

---File-type icon and its highlight, or nil (no icons configured / available).
---Replaceable in tests.
function M.icon(name)
  local mode = require("code-review").config.icons
  if mode == false then
    return nil
  end
  local ok, devicons = pcall(require, "nvim-web-devicons")
  if not ok then
    return nil
  end
  local icon, hl = devicons.get_icon(name, name:match("%.([^.]+)$"), { default = true })
  return icon, hl
end

local function notify(msg, level)
  vim.notify("code-review: " .. msg, level or vim.log.levels.INFO)
end

-- Data ------------------------------------------------------------------------

---Changed files in review order: by path, like GitHub.
function M.ordered(s)
  local files = vim.deepcopy(s.files or {})
  table.sort(files, function(a, b)
    return a.path < b.path
  end)
  return files
end

---Open threads per file: total and how many wait on the user (agent replied).
local function thread_counts(root)
  local ok, data = pcall(store.read, root)
  local res = {}
  for _, t in ipairs(ok and data.threads or {}) do
    if t.status ~= "resolved" then
      local c = res[t.file] or { open = 0, yours = 0 }
      c.open = c.open + 1
      if t.needs == "user" then
        c.yours = c.yours + 1
      end
      res[t.file] = c
    end
  end
  return res
end

---Group files by directory; a chain of single-child folders shows as one row.
local function tree(files)
  local groups, order = {}, {}
  for _, f in ipairs(files) do
    local dir = f.path:match("^(.*)/[^/]+$") or ""
    if not groups[dir] then
      groups[dir] = {}
      order[#order + 1] = dir
    end
    table.insert(groups[dir], f)
  end
  return groups, order
end

-- Window + buffer ------------------------------------------------------------------

local function find_win(tabpage)
  for _, w in ipairs(api.nvim_tabpage_list_wins(tabpage or 0)) do
    local b = api.nvim_win_get_buf(w)
    if vim.b[b].code_review_sidebar then
      return w, b
    end
  end
end

M.find_win = find_win

---Is `win` the sidebar?
function M.is_sidebar(win)
  return vim.b[api.nvim_win_get_buf(win)].code_review_sidebar ~= nil
end

local function map_keys(buf)
  local o = function(desc)
    return { buffer = buf, nowait = true, desc = "Code review sidebar: " .. desc }
  end
  local diff = function()
    return require("code-review.diff")
  end
  vim.keymap.set("n", "<CR>", function() M.activate() end, o("open file / fold folder"))
  vim.keymap.set("n", "o", function() M.activate() end, o("open file / fold folder"))
  vim.keymap.set("n", "<Tab>", function() M.toggle_dir() end, o("fold folder"))
  vim.keymap.set("n", "za", function() M.toggle_dir() end, o("fold folder"))
  vim.keymap.set("n", "v", function() M.toggle_viewed_row() end, o("toggle viewed"))
  vim.keymap.set("n", "R", function() M.refresh_all() end, o("refresh"))
  if require("code-review").config.mouse ~= false then
    -- the click moves the cursor to the row; act on release
    vim.keymap.set("n", "<LeftRelease>", function() M.activate() end, o("open the clicked file / fold the folder"))
  end
  vim.keymap.set("n", "f", function() M.set_filter(vim.b[buf].code_review_sidebar) end, o("filter: all / unviewed / with threads / waiting for you"))
  vim.keymap.set("n", "U", function() diff().reload(vim.b[buf].code_review_sidebar) end, o("reload the PR (new commits)"))
  vim.keymap.set("n", "S", function() diff().toggle_since(vim.b[buf].code_review_sidebar) end, o("changes since your last review"))
  vim.keymap.set("n", "q", function() M.close() end, o("close"))
  local km = require("code-review").config.keymaps or {}
  vim.keymap.set("n", km.next_file or "]f", function() diff().step(1) end, o("next unreviewed file"))
  vim.keymap.set("n", km.prev_file or "[f", function() diff().step(-1) end, o("previous unreviewed file"))
  vim.keymap.set("n", "d", function()
    diff().description(vim.b[buf].code_review_sidebar)
  end, o("PR description"))
  for _, key in ipairs({ "?", "g?" }) do
    vim.keymap.set("n", key, function() require("code-review").help("sidebar") end, o("help"))
  end
end

local function new_buf(root)
  local buf = api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].filetype = "codereview-files"
  vim.b[buf].code_review_sidebar = root
  pcall(api.nvim_buf_set_name, buf, "code-review://files/" .. root:match("[^/]+/[^/]+/pr%-%d+$") or root)
  map_keys(buf)
  return buf
end

---Open the sidebar in the current tab (or reuse it). Does not move the focus.
---@return integer win
function M.open(root)
  local win, buf = find_win()
  if win and vim.b[buf].code_review_sidebar ~= root then
    vim.b[buf].code_review_sidebar = root
  end
  if not win then
    local here = api.nvim_get_current_win()
    buf = new_buf(root)
    local pos = M.position()
    local cfg = { split = ({ left = "left", right = "right", bottom = "below", top = "above" })[pos], win = -1 }
    if M.vertical() then
      cfg.width = M.width()
    else
      cfg.height = M.height()
    end
    win = api.nvim_open_win(buf, false, cfg) -- win = -1: along the whole edge of the tab
    for opt, val in pairs({
      number = false, relativenumber = false, signcolumn = "no", foldcolumn = "0",
      wrap = false, cursorline = true, spell = false, list = false,
      winfixwidth = M.vertical(), winfixheight = not M.vertical(),
    }) do
      vim.wo[win][opt] = val
    end
    if api.nvim_win_is_valid(here) then
      api.nvim_set_current_win(here)
    end
  end
  M.render(root)
  return win
end

---Give the file list its configured size again (after the layout was rebuilt
---around it). Not done on every file switch, so a manual resize is kept.
function M.restore_size()
  local win = find_win()
  if not win then
    return
  end
  if M.vertical() then
    api.nvim_win_set_width(win, M.width())
  else
    api.nvim_win_set_height(win, M.height())
  end
end

function M.close()
  local win = find_win()
  if win and #api.nvim_tabpage_list_wins(0) > 1 then
    api.nvim_win_close(win, true)
  end
end

---Show the sidebar if hidden, hide it if shown.
function M.toggle(root)
  if find_win() then
    return M.close()
  end
  M.open(root)
end

-- Rendering ---------------------------------------------------------------------------

---Redraw the sidebar of `root` (when it is open in this tab).
---@param shown? string the file now shown in the diff
function M.render(root, shown)
  if shown then
    current[root] = shown
  end
  local win, buf = find_win()
  if not win or vim.b[buf].code_review_sidebar ~= root then
    return
  end
  local s = session.load(root)
  if not s then
    return
  end
  local all_files = M.ordered(s)
  local viewed = require("code-review.diff").viewed(root)
  local counts = thread_counts(root)
  local n_viewed = 0
  for _, f in ipairs(all_files) do
    if viewed[f.path] then
      n_viewed = n_viewed + 1
    end
  end
  local mode = M.filter(root)
  local files = vim.tbl_filter(function(f)
    local c = counts[f.path]
    if mode == "unviewed" then
      return not viewed[f.path]
    elseif mode == "threads" then
      return c ~= nil
    elseif mode == "yours" then
      return c ~= nil and c.yours > 0
    elseif mode == "since" then
      return (require("code-review.diff").since(root) or {})[f.path] == true
    end
    return true
  end, all_files)
  local diffmod = require("code-review.diff")
  local is_loading = diffmod.loading(root)

  -- widths so the counts line up
  local w_name, w_add, w_del = 0, 1, 1
  for _, f in ipairs(files) do
    w_name = math.max(w_name, vim.fn.strdisplaywidth(f.path:match("[^/]+$")))
    w_add = math.max(w_add, #tostring(f.additions or 0) + 1)
    w_del = math.max(w_del, #tostring(f.deletions or 0) + 1)
  end

  -- The name column takes what is left of the window after the fixed columns
  -- (indent, marks, status, counts, threads); longer names are shortened.
  local w_threads, has_dirs = 0, false
  for _, f in ipairs(files) do
    local c = counts[f.path]
    if c then
      w_threads = math.max(w_threads, #("  ✎" .. c.open) - 2 + (c.yours > 0 and 1 or 0)) -- ✎ is 3 bytes, 1 cell
    end
    has_dirs = has_dirs or f.path:find("/", 1, true) ~= nil
  end
  -- icons get a fixed slot of 2 cells + space: Nerd Font glyphs often draw wider than they count
  local use_icons = M.icon("x.lua") ~= nil
  local reserved = (has_dirs and 2 or 0) + 2 + 3 + (use_icons and 3 or 0) + (1 + w_add) + (1 + w_del) + w_threads
  w_name = math.max(8, math.min(w_name, api.nvim_win_get_width(win) - reserved))
  local function shorten(name)
    if vim.fn.strdisplaywidth(name) <= w_name then
      return name
    end
    return vim.fn.strcharpart(name, 0, w_name - 1) .. "…"
  end

  local lines, marks, map = {}, {}, {}
  local function add(pieces, entry)
    local text, col = "", 0
    for _, p in ipairs(pieces) do
      if p[2] and #p[1] > 0 then
        marks[#marks + 1] = { #lines, col, col + #p[1], p[2] }
      end
      text = text .. p[1]
      col = col + #p[1]
    end
    lines[#lines + 1] = text
    map[#lines] = entry
  end
  local function pad(text, w)
    return text .. string.rep(" ", math.max(0, w - vim.fn.strdisplaywidth(text)))
  end

  local header = {
    { " " .. string.format("%s/%s#%d", s.owner, s.repo, s.number), "Title" },
    { string.format(" · %d/%d viewed", n_viewed, #all_files), "Comment" },
  }
  if mode ~= "all" then
    header[#header + 1] = { string.format(" · %s: %d", FILTER_LABEL[mode], #files), "WarningMsg" }
  end
  add(header)
  local upd = diffmod.update_available(root)
  if upd then
    add({ { string.format(" ⟳ PR updated%s · U to reload", upd.commits and string.format(" · %d new commit%s", upd.commits, upd.commits == 1 and "" or "s") or ""), "WarningMsg" } })
  elseif diffmod.since(root) and next(diffmod.since(root)) then
    local n = vim.tbl_count(diffmod.since(root))
    add({ { string.format(" ↻ %d file%s changed since your last review · S", n, n == 1 and "" or "s"), "Comment" } })
  end
  if #files == 0 then
    add({ { "   no files match (f: next filter)", "Comment" } })
  end
  local groups, order = tree(files)
  local fold = collapsed[root] or {}
  for _, dir in ipairs(order) do
    if dir ~= "" then
      add({ { (fold[dir] and " ▸ " or " ▾ ") .. dir .. "/", "Directory" } }, { kind = "dir", dir = dir })
    end
    if not fold[dir] then
      for _, f in ipairs(groups[dir]) do
        local st = STATUS[f.status] or { "?", "Comment" }
        local name = f.path:match("[^/]+$")
        local is_viewed = viewed[f.path]
        local c = counts[f.path]
        local pieces = {
          { dir ~= "" and "  " or "", nil },
          { current[root] == f.path and "▶" or " ", "CodeReviewQfMarker" },
          { is_viewed and "✓" or (is_loading and not (vim.uv.fs_stat(session.snapshot_path(root, f.path, f.status == "removed" and "old" or "new"))) and "…" or " "), "CodeReviewQfCheck" },
          { " " .. st[1] .. " ", st[2] },
        }
        if use_icons then
          local icon, icon_hl = M.icon(name)
          pieces[#pieces + 1] = { pad(icon or " ", 2) .. " ", icon_hl }
        end
        vim.list_extend(pieces, {
          { pad(shorten(name), w_name), is_viewed and "CodeReviewQfViewed" or nil },
          { " " .. pad((f.additions or 0) > 0 and ("+" .. f.additions) or "", w_add), "CodeReviewStatAdd" },
          { " " .. pad((f.deletions or 0) > 0 and ("-" .. f.deletions) or "", w_del), "CodeReviewStatDel" },
        })
        if c then
          pieces[#pieces + 1] = { "  ✎" .. c.open, c.yours > 0 and "CodeReviewNeedsUser" or "CodeReviewNeedsAgent" }
          if c.yours > 0 then
            pieces[#pieces + 1] = { "!", "CodeReviewNeedsUser" }
          end
        end
        add(pieces, { kind = "file", path = f.path })
      end
    end
  end

  vim.bo[buf].modifiable = true
  api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  for _, m in ipairs(marks) do
    api.nvim_buf_set_extmark(buf, ns, m[1], m[2], { end_col = m[3], hl_group = m[4] })
  end
  rows[buf] = map
  -- the file in the diff gets a highlighted row, and the cursor when outside the sidebar
  for row, e in pairs(map) do
    if e.kind == "file" and e.path == current[root] then
      api.nvim_buf_set_extmark(buf, ns, row - 1, 0, { line_hl_group = "CodeReviewQfCurrent", priority = 5 })
      if api.nvim_get_current_win() ~= win then
        pcall(api.nvim_win_set_cursor, win, { row, 0 })
      end
    end
  end
end

---Redraw every open sidebar (e.g. after an agent replied).
function M.refresh_all()
  for _, tp in ipairs(api.nvim_list_tabpages()) do
    local win, buf = find_win(tp)
    if win then
      api.nvim_win_call(win, function()
        M.render(vim.b[buf].code_review_sidebar)
      end)
    end
  end
end

-- Actions -------------------------------------------------------------------------------

---What is on the cursor row of the sidebar: root and the row entry.
function M.at_cursor()
  local buf = api.nvim_get_current_buf()
  local root = vim.b[buf].code_review_sidebar
  if not root then
    return nil
  end
  return root, (rows[buf] or {})[api.nvim_win_get_cursor(0)[1]]
end

function M.toggle_dir()
  local root, e = M.at_cursor()
  if not (e and e.kind == "dir") then
    return
  end
  collapsed[root] = collapsed[root] or {}
  collapsed[root][e.dir] = not collapsed[root][e.dir] or nil
  M.render(root)
end

---<CR>: open the file under the cursor in the diff, or fold a folder.
function M.activate()
  local root, e = M.at_cursor()
  if not e then
    return
  end
  if e.kind == "dir" then
    return M.toggle_dir()
  end
  require("code-review.diff").show_file(root, e.path)
end

---v: mark the file under the cursor viewed (or not) and move to the next unreviewed row.
function M.toggle_viewed_row()
  local root, e = M.at_cursor()
  if not (e and e.kind == "file") then
    return
  end
  local now = not require("code-review.diff").viewed(root)[e.path]
  session.set_viewed(root, e.path, now)
  require("code-review.diff").refresh_cache(root)
  M.render(root)
  vim.cmd("redrawstatus!")
  require("code-review.diff").maybe_summary(root)
  if now then
    local buf = api.nvim_get_current_buf()
    local here = api.nvim_win_get_cursor(0)[1]
    local viewed = require("code-review.diff").viewed(root)
    for row = here + 1, api.nvim_buf_line_count(buf) do
      local r = rows[buf][row]
      if r and r.kind == "file" and not viewed[r.path] then
        return api.nvim_win_set_cursor(0, { row, 0 })
      end
    end
  end
end

return M
