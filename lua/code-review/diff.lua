-- PR review UI: changed files in a sidebar, side-by-side native diff.
--
-- The base and head snapshots are ordinary files in the cache directory, so
-- they open as normal buffers; code-review.session.infer recognises them by
-- path and the rest of the plugin (signs, threads, :CodeReview add) treats the
-- left window as the "old" side and the right window as the "new" side.
local github = require("code-review.github")
local session = require("code-review.session")
local sidebar = require("code-review.sidebar")

local api = vim.api
local M = {}

local tab -- the tabpage used for reviewing

-- Session + viewed state per review, for things drawn on every redraw (winbar,
-- sidebar). Refreshed whenever the review changes, never read from disk per redraw.
local cache = {} -- root -> { s = session, viewed = { [path] = bool } }

---Reload the cached state of a review.
function M.refresh_cache(root)
  local s = session.load(root)
  cache[root] = s and { s = s, viewed = session.viewed_map(root), since = M.compute_since(root, s) } or nil
  return cache[root]
end

---Files that changed since the previous version of the review (the PR got new
---commits): { [path] = true }, or nil when there is no previous version.
function M.compute_since(root, s)
  if not (s and s.previous) then
    return nil
  end
  local res = {}
  for _, f in ipairs(s.files or {}) do
    local prev = session.snapshot_path_in(s.cache, f.path, "prev")
    local head = session.snapshot_path_in(s.cache, f.path, "new")
    local a = vim.uv.fs_stat(prev) and vim.fn.readfile(prev) or nil
    local b = vim.uv.fs_stat(head) and vim.fn.readfile(head) or nil
    if not vim.deep_equal(a, b) then
      res[f.path] = true
    end
  end
  return res
end

---What changed since the previous version, or nil (see compute_since).
function M.since(root)
  local c = cache[root] or M.refresh_cache(root)
  return c and c.since
end

local since_mode = {} -- root -> true: show "since your last review" instead of the PR diff

---Show what changed since your last review (previous head → current head), or
---go back to the normal diff.
function M.toggle_since(root)
  local s = session.load(root)
  if not (s and s.previous) then
    return vim.notify("code-review: nothing to compare yet: this review has no earlier version (it appears after the PR gets new commits and you reload)")
  end
  since_mode[root] = not since_mode[root] or nil
  local _, file = M.where()
  if file then
    M.show_file(root, file)
  end
  vim.notify("code-review: " .. (since_mode[root] and "showing changes since your last review" or "showing the whole PR diff"))
end

---Is "since your last review" on?
function M.since_mode(root)
  return since_mode[root] == true
end

local function cached(root)
  return cache[root] or M.refresh_cache(root)
end

---Viewed files of a review (cached): { [path] = true }.
function M.viewed(root)
  local c = cached(root)
  return c and c.viewed or {}
end

---Position of `file` in review order (the sidebar's order) and the total.
local function position(s, file)
  local order = sidebar.ordered(s)
  for i, f in ipairs(order) do
    if f.path == file then
      return i, #order, order
    end
  end
  return nil, #order, order
end

-- Colors ---------------------------------------------------------------------
--
-- Native diff highlights a line that exists only in the left buffer with
-- DiffAdd (green) even though, in a review, it was *removed*. So the two diff
-- windows get their own groups through window-local 'winhighlight': red on the
-- old side, green on the new side. Backgrounds are blended from the
-- colorscheme's own Normal background, so they stay readable in dark and light
-- themes; the global Diff* groups are not touched.

local function channels(n)
  return math.floor(n / 65536) % 256, math.floor(n / 256) % 256, n % 256
end

---Blend `color` over `bg` with opacity `a` (0..1); both are 0xRRGGBB numbers.
local function blend(bg, color, a)
  local br, bgc, bb = channels(bg)
  local cr, cg, cb = channels(color)
  local function mix(x, y)
    return math.floor(x + (y - x) * a + 0.5)
  end
  return mix(br, cr) * 65536 + mix(bgc, cg) * 256 + mix(bb, cb)
end

local function hl_color(name, attr, fallback)
  local ok, hl = pcall(api.nvim_get_hl, 0, { name = name, link = false })
  return ok and hl and hl[attr] or fallback
end

local function luminance(c)
  local function f(x)
    x = x / 255
    return x <= 0.03928 and x / 12.92 or ((x + 0.055) / 1.055) ^ 2.4
  end
  local r, g, b = channels(c)
  return 0.2126 * f(r) + 0.7152 * f(g) + 0.0722 * f(b)
end

local function contrast(a, b)
  local la, lb = luminance(a), luminance(b)
  if la < lb then
    la, lb = lb, la
  end
  return (la + 0.05) / (lb + 0.05)
end

M.MIN_CONTRAST = 4.5

---Tint `bg` with `color`, as strongly as `preferred` (0..1) allows while text in
---`fg` stays readable on it. This is how hunk picks its diff backgrounds.
local function tint(bg, color, preferred, fg)
  for step = math.floor(preferred * 100), 1, -1 do
    local candidate = blend(bg, color, step / 100)
    if contrast(fg, candidate) >= M.MIN_CONTRAST then
      return candidate
    end
  end
  return bg
end

-- Accent colors of the "github-dark" palette (GitHub Dark Default, as in hunk).
local GITHUB_DARK = { bg = 0x0d1117, fg = 0xe6edf3, green = 0x2ea043, red = 0xf85149 }

---Define the CodeReviewDiff* groups. `config.diff_colors`:
---  true / "auto"   derive from the colorscheme (Normal, DiagnosticOk/Error)
---  "github-dark"   GitHub Dark Default accents (green #2ea043, red #f85149)
function M.highlights()
  local mode = require("code-review").config.diff_colors
  local dark = vim.o.background ~= "light"
  local bg = hl_color("Normal", "bg", dark and (mode == "github-dark" and GITHUB_DARK.bg or 0x1e1e1e) or 0xffffff)
  local fg = hl_color("Normal", "fg", dark and (mode == "github-dark" and GITHUB_DARK.fg or 0xd4d4d4) or 0x24292f)
  local green, red
  if mode == "github-dark" then
    green, red = GITHUB_DARK.green, GITHUB_DARK.red
  else
    green = hl_color("DiagnosticOk", "fg", dark and 0x3fb950 or 0x1a7f37)
    red = hl_color("DiagnosticError", "fg", dark and 0xf85149 or 0xcf222e)
  end
  local line, text = dark and 0.30 or 0.26, dark and 0.50 or 0.50
  local function set(name, opts)
    api.nvim_set_hl(0, name, vim.tbl_extend("keep", opts, { default = true }))
  end
  set("CodeReviewDiffAdded", { bg = tint(bg, green, line, fg) })
  set("CodeReviewDiffAddedText", { bg = tint(bg, green, text, fg), bold = true })
  set("CodeReviewDiffRemoved", { bg = tint(bg, red, line, fg) })
  set("CodeReviewDiffRemovedText", { bg = tint(bg, red, text, fg), bold = true })
  -- filler lines (the empty space opposite an added/removed block)
  -- parts of a line in the PR file list
  local function link(name, target)
    api.nvim_set_hl(0, name, { link = target, default = true })
  end
  link("CodeReviewStatusAdded", "DiagnosticOk")
  link("CodeReviewStatusRemoved", "DiagnosticError")
  link("CodeReviewStatusModified", "DiagnosticWarn")
  link("CodeReviewStatusRenamed", "DiagnosticInfo")
  link("CodeReviewStatAdd", "DiagnosticOk")
  link("CodeReviewStatDel", "DiagnosticError")
  link("CodeReviewQfDir", "Comment")
  link("CodeReviewQfViewed", "Comment")
  link("CodeReviewQfCheck", "DiagnosticOk")
  link("CodeReviewQfMarker", "DiagnosticInfo")
  -- winbar of the diff panes
  link("CodeReviewWinbarOld", "DiagnosticError")
  link("CodeReviewWinbarNew", "DiagnosticOk")
  link("CodeReviewWinbarDim", "Comment")
  link("CodeReviewFold", "Comment") -- "⋯ 42 unchanged lines"
  link("CodeReviewWinbarCtx", "Function") -- the function around the cursor
  -- the current file in the PR file list
  set("CodeReviewQfCurrent", { bg = tint(bg, hl_color("DiagnosticInfo", "fg", 0x2f81f7), 0.30, fg), bold = true })
  set("CodeReviewDiffFiller", { fg = blend(bg, hl_color("NonText", "fg", dark and 0x6e7681 or 0x8c959f), 0.6), bg = blend(bg, dark and 0xffffff or 0x000000, 0.04) })
end

local WINHL = {
  old = "DiffAdd:CodeReviewDiffRemoved,DiffChange:CodeReviewDiffRemoved,DiffText:CodeReviewDiffRemovedText,DiffDelete:CodeReviewDiffFiller",
  new = "DiffAdd:CodeReviewDiffAdded,DiffChange:CodeReviewDiffAdded,DiffText:CodeReviewDiffAddedText,DiffDelete:CodeReviewDiffFiller",
}

---Color the diff windows: `old_win` red, `new_win` green, hatched filler lines.
local function style_windows(old_win, new_win)
  if not require("code-review").config.diff_colors then
    return
  end
  M.highlights()
  for win, which in pairs({ [old_win] = "old", [new_win] = "new" }) do
    vim.wo[win].winhighlight = WINHL[which]
    vim.wo[win].fillchars = "diff:╱"
  end
end

local function notify(msg, level)
  vim.notify("code-review: " .. msg, level or vim.log.levels.INFO)
end

local function entry(s, file)
  for i, f in ipairs(s.files or {}) do
    if f.path == file then
      return f, i
    end
  end
end

local function label(s)
  return string.format("%s/%s#%d", s.owner, s.repo, s.number)
end

---Show the PR's changed files in the sidebar (and open it unless `open` is false).
---@param current? string the file shown in the diff
function M.files(root, open, current)
  local s = session.load(root)
  if not s or s.kind ~= "pr" then
    return notify("not in a PR review", vim.log.levels.WARN)
  end
  if open ~= false then
    sidebar.open(root)
  end
  sidebar.render(root, current)
end

local WINBAR = "%{%v:lua.require'code-review.diff'.winbar()%}"

local ctx_cache = {} -- win -> { buf, row, text }

---Where the cursor of `win` is in the code: the enclosing functions / classes,
---outermost first ("Parser › parse"), from treesitter. "" without a parser.
function M.context(win)
  local buf = api.nvim_win_get_buf(win)
  local row = api.nvim_win_get_cursor(win)[1]
  local c = ctx_cache[win]
  if c and c.buf == buf and c.row == row then
    return c.text
  end
  local text = ""
  pcall(function()
    local parser = vim.treesitter.get_parser(buf, nil, { error = false })
    if not parser then
      return
    end
    parser:parse()
    local line = api.nvim_buf_get_lines(buf, row - 1, row, false)[1] or ""
    local node = vim.treesitter.get_node({ bufnr = buf, pos = { row - 1, #(line:match("^%s*") or "") }, ignore_injections = true })
    local names = {}
    while node do
      local t = node:type()
      if t:find("function") or t:find("method") or t:find("class") or t:find("struct") or t:find("impl") then
        local name = node:field("name")[1]
        if name then
          table.insert(names, 1, (vim.treesitter.get_node_text(name, buf):gsub("%s+", " ")))
        end
      end
      node = node:parent()
    end
    text = table.concat(names, " › ")
  end)
  ctx_cache[win] = { buf = buf, row = row, text = text }
  return text
end
local FOLDTEXT = "v:lua.require'code-review.diff'.foldtext()"

---Text of a closed fold in a diff pane (unchanged code), as highlight chunks.
function M.foldtext()
  local n = vim.v.foldend - vim.v.foldstart + 1
  return { { string.format("  ⋯  %d unchanged line%s", n, n == 1 and "" or "s"), "CodeReviewFold" } }
end

---Width the winbar of a diff pane fits into (replaceable in tests).
function M.pane_width(win)
  return api.nvim_win_get_width(win)
end

---Winbar of a PR diff pane: which side, which commit, where in the PR.
---(Evaluated by Neovim on redraw for the window being drawn.)
function M.winbar()
  local win = vim.g.statusline_winid or api.nvim_get_current_win()
  if not api.nvim_win_is_valid(win) then
    return ""
  end
  local wbuf = api.nvim_win_get_buf(win)
  local root, file, side = session.infer(api.nvim_buf_get_name(wbuf))
  local u = vim.b[wbuf].code_review_unified
  if u then
    root, file, side = u.root, u.file, "both"
  end
  local c = root and cached(root)
  if not c then
    return ""
  end
  local s = c.s
  local i, n = position(s, file)
  local function esc(x)
    return (tostring(x or "?"):gsub("%%", "%%%%"))
  end
  -- a long branch name keeps its start (where the meaning is); the pane may still cut it
  local function ref(x)
    x = tostring(x or "?")
    if vim.fn.strchars(x) > 24 then
      x = vim.fn.strcharpart(x, 0, 23) .. "…"
    end
    return esc(x)
  end
  if side == "both" then
    local since = require("code-review.unified").is_since(wbuf)
    local parts = {
      since and string.format(
        " %%#CodeReviewWinbarNew#SINCE YOUR LAST REVIEW%%* %%<%%#CodeReviewWinbarDim#@%s%%* → %s %%#CodeReviewWinbarDim#@%s%%*",
        esc(((s.previous or {}).head_sha or ""):sub(1, 7)), ref(s.head_ref), esc((s.head_sha or ""):sub(1, 7))
      ) or string.format(
        " %%#CodeReviewWinbarNew#UNIFIED%%* %%<%s %%#CodeReviewWinbarDim#@%s%%* → %s %%#CodeReviewWinbarDim#@%s%%*",
        ref(s.base_ref), esc((s.base_sha or ""):sub(1, 7)), ref(s.head_ref), esc((s.head_sha or ""):sub(1, 7))
      ),
    }
    if i then
      parts[#parts + 1] = string.format("%%#CodeReviewWinbarDim#file %d/%d%%*", i, n)
    end
    if c.viewed[file] then
      parts[#parts + 1] = "%#CodeReviewQfCheck#✓ viewed%*"
    end
    local where = M.context(win)
    if where ~= "" then
      parts[#parts + 1] = "%#CodeReviewWinbarCtx#" .. esc(where) .. "%*"
    end
    local bar = table.concat(parts, " · ")
    local p = require("code-review.progress").in_winbar() and require("code-review.progress").current()
    if p then
      bar = bar .. "%=%#" .. p.hl .. "#" .. esc(p.text) .. " %*"
    end
    return bar
  end
  -- A split pane is narrow: fit the header to it. The side label and the start
  -- of the branch come first; the function name only shows when there is room.
  local width = M.pane_width(win)
  local dw = vim.fn.strdisplaywidth
  local function fit(name, fixed)
    name = tostring(name or "?")
    local room = math.max(6, math.min(24, width - fixed))
    if vim.fn.strchars(name) > room then
      name = vim.fn.strcharpart(name, 0, room - 1) .. "…"
    end
    return name
  end
  local where = M.context(win)
  if side == "old" then
    local sha = (s.base_sha or ""):sub(1, 7)
    local name = fit(s.base_ref, 6 + #sha + 2)
    local used = 5 + dw(name) + 2 + #sha
    return string.format(" %%#CodeReviewWinbarOld#OLD%%* %%<%s %%#CodeReviewWinbarDim#@%s%%*", esc(name), esc(sha))
      .. ((where ~= "" and used + 3 + dw(where) <= width) and (" · %#CodeReviewWinbarCtx#" .. esc(where) .. "%*") or "")
  end
  local sha = (s.head_sha or ""):sub(1, 7)
  local pos = i and string.format("file %d/%d", i, n) or nil
  local viewed = c.viewed[file] == true
  local function tail()
    return (pos and (3 + #pos) or 0) + (viewed and 11 or 0)
  end
  -- too narrow even for the shortest branch name: drop "viewed", then the position
  if viewed and 5 + 6 + 2 + #sha + tail() > width then
    viewed = false
  end
  if pos and 5 + 6 + 2 + #sha + tail() > width then
    pos = nil
  end
  local name = fit(s.head_ref, 6 + #sha + 2 + tail())
  local used = 5 + dw(name) + 2 + #sha + tail()
  local parts = {
    string.format(" %%#CodeReviewWinbarNew#NEW%%* %%<%s %%#CodeReviewWinbarDim#@%s%%*", esc(name), esc(sha)),
  }
  if pos then
    parts[#parts + 1] = "%#CodeReviewWinbarDim#" .. pos .. "%*"
  end
  if viewed then
    parts[#parts + 1] = "%#CodeReviewQfCheck#✓ viewed%*"
  end
  if where ~= "" and used + 3 + dw(where) <= width then
    parts[#parts + 1] = "%#CodeReviewWinbarCtx#" .. esc(where) .. "%*"
  end
  local bar = table.concat(parts, " · ")
  -- the agent's progress after a poke, right-aligned
  local p = require("code-review.progress").in_winbar() and require("code-review.progress").current()
  if p then
    bar = bar .. "%=%#" .. p.hl .. "#" .. esc(p.text) .. " %*"
  end
  return bar
end

local sidebar_hidden = {} -- root -> true after the user closed the sidebar
local loading = {} -- root -> true while the PR is being downloaded
local waiting = {} -- root -> file shown as "loading…", to show for real when it lands
local shown = {} -- root -> the file on screen
local updates = {} -- root -> { commits = n } when GitHub has newer commits than the review
local last_check = {} -- root -> time of the last update check

---Is the PR of `root` still being downloaded?
function M.loading(root)
  return loading[root] == true
end

---Newer commits on GitHub than in the review, or nil.
function M.update_available(root)
  return updates[root]
end

---Go to the review tab and leave exactly one window for the diff, next to the
---sidebar. The sidebar and any quickfix list stay (no :only, no :cclose).
local function review_tab()
  if tab and api.nvim_tabpage_is_valid(tab) then
    api.nvim_set_current_tabpage(tab)
  else
    vim.cmd.tabnew()
    tab = api.nvim_get_current_tabpage()
  end
  vim.cmd("diffoff!")
  local keep
  for _, w in ipairs(api.nvim_tabpage_list_wins(0)) do
    local b = api.nvim_win_get_buf(w)
    if api.nvim_win_get_config(w).relative == "" and not sidebar.is_sidebar(w) and vim.bo[b].buftype ~= "quickfix"
      and not vim.b[b].code_review_panel then -- the conversation panel stays too
      if not keep then
        keep = w
      else
        pcall(api.nvim_win_close, w, false) -- never discards unsaved changes
      end
    end
  end
  if keep then
    api.nvim_set_current_win(keep)
  else
    -- only the file list (and maybe a quickfix) is left: open the diff window
    -- along the opposite edge, so the file list keeps all of its space
    api.nvim_open_win(api.nvim_create_buf(false, true), true, { split = sidebar.opposite(), win = -1 })
    sidebar.restore_size() -- alone it had grown to fill the tab
  end
  vim.wo.winhighlight = ""
  vim.wo.fillchars = vim.go.fillchars
  vim.wo.winbar = ""
  vim.wo.foldtext = vim.go.foldtext
  vim.wo.statuscolumn = ""
  vim.wo.foldmethod = vim.go.foldmethod
  vim.wo.signcolumn = vim.go.signcolumn
end

---"split" (old | new side by side) or "unified" (one column).
function M.layout()
  return require("code-review").config.diff_layout == "unified" and "unified" or "split"
end

---Switch the layout (or toggle it without `layout`) and show the current file again.
function M.set_layout(root, layout)
  if layout and layout ~= "split" and layout ~= "unified" then
    return notify("layout must be split or unified", vim.log.levels.WARN)
  end
  require("code-review").config.diff_layout = layout or (M.layout() == "split" and "unified" or "split")
  local r, file = M.where()
  r = r or root
  if r and file then
    M.show_file(r, file)
  end
  notify("diff layout: " .. M.layout())
end

---Open `file` of the PR in `root`: old on the left, new on the right. The
---cursor goes to `side` (default new) at `line` when given.
---@param side? "old"|"new"
---@param line? integer
function M.show_file(root, file, side, line)
  local s = session.load(root)
  local f = s and entry(s, file)
  if not f then
    return notify("no such file in this PR: " .. tostring(file), vim.log.levels.WARN)
  end
  require("code-review").setup_once()
  if since_mode[root] then
    return M.show_unified(root, file, side, line, true)
  end
  if M.layout() == "unified" then
    return M.show_unified(root, file, side, line)
  end
  local esc = vim.fn.fnameescape
  local has_base, has_head = f.status ~= "added", f.status ~= "removed"
  local base = session.snapshot_path_in(s.cache, file, "old")
  local head = session.snapshot_path_in(s.cache, file, "new")
  -- a file that GitHub did not give us contents for (e.g. binary) has no snapshot
  has_base = has_base and vim.uv.fs_stat(base) ~= nil
  has_head = has_head and vim.uv.fs_stat(head) ~= nil

  review_tab()
  if not has_base and not has_head and M.loading(root) then
    -- not downloaded yet: a placeholder that is replaced when the file arrives
    local buf = api.nvim_create_buf(false, true)
    vim.bo[buf].bufhidden = "wipe"
    api.nvim_buf_set_lines(buf, 0, -1, false, { "", "  ⋯ loading " .. file .. " …" })
    vim.bo[buf].modifiable = false
    vim.b[buf].code_review_placeholder = true
    api.nvim_win_set_buf(0, buf)
    waiting[root] = file
  elseif has_base and has_head then
    vim.cmd.edit(esc(head))
    vim.cmd("diffthis")
    local new_win = api.nvim_get_current_win()
    vim.cmd("leftabove vsplit " .. esc(base))
    vim.cmd("diffthis")
    style_windows(api.nvim_get_current_win(), new_win)
    vim.cmd("wincmd l")
    if not line then
      pcall(vim.cmd, "keepjumps normal! gg]c")
    end
    if side == "old" then
      vim.cmd("wincmd h")
    end
  elseif has_head or has_base then
    vim.cmd.edit(esc(has_head and head or base))
  else
    local msg = file .. ": no text content to show (binary or too large?)"
    if vim.b.code_review_placeholder then -- its file never came: say so instead of "loading…"
      vim.bo.modifiable = true
      api.nvim_buf_set_lines(0, 0, -1, false, { "", "  " .. msg })
      vim.bo.modifiable = false
    end
    notify(msg, vim.log.levels.WARN)
  end
  M.refresh_cache(root)
  M.highlights()
  for _, w in ipairs(api.nvim_tabpage_list_wins(0)) do
    if session.infer(api.nvim_buf_get_name(api.nvim_win_get_buf(w))) then
      vim.wo[w].winbar = WINBAR
      vim.wo[w].foldtext = FOLDTEXT
      vim.wo[w].fillchars = (vim.wo[w].fillchars ~= "" and (vim.wo[w].fillchars .. ",") or "") .. "fold: "
    end
  end
  shown[root] = file
  local win = api.nvim_get_current_win()
  if not sidebar_hidden[root] then
    sidebar.open(root)
    vim.cmd("wincmd =") -- the sidebar keeps its width (winfixwidth); the panes share the rest
  end
  local panel = package.loaded["code-review.panel"]
  if panel then
    panel.restore_size() -- equalizing can squeeze the conversation panel
  end
  sidebar.render(root, file)
  api.nvim_set_current_win(win)
  if line then
    local n = api.nvim_buf_line_count(0)
    pcall(api.nvim_win_set_cursor, 0, { math.max(1, math.min(line, n)), 0 })
    vim.cmd("normal! zz")
    require("code-review").flash()
  end
end

---Show `file` as one unified column (see code-review.unified).
function M.show_unified(root, file, side, line, since)
  local unified = require("code-review.unified")
  shown[root] = file
  review_tab()
  M.refresh_cache(root)
  M.highlights()
  local win = api.nvim_get_current_win()
  local opts
  if since then
    local s = session.load(root)
    local prev = session.snapshot_path_in(s.cache, file, "prev")
    opts = { since = true, old_lines = vim.uv.fs_stat(prev) and vim.fn.readfile(prev) or {} }
  end
  local buf = unified.show(root, file, win, FOLDTEXT, opts)
  vim.wo[win].winbar = WINBAR
  require("code-review").render(buf)
  if not sidebar_hidden[root] then
    sidebar.open(root)
  end
  sidebar.render(root, file)
  local panel = package.loaded["code-review.panel"]
  if panel then
    panel.restore_size()
  end
  api.nvim_set_current_win(win)
  local row = line and unified.row_of(buf, side or "new", line)
  if row then
    pcall(api.nvim_win_set_cursor, win, { row, 0 })
    vim.cmd("normal! zvzz")
    require("code-review").flash(win, row)
  else
    api.nvim_win_set_cursor(win, { 1, 0 })
    unified.next_change(1)
  end
end

---Lines of the PR description page (markdown).
---@return string[]
function M.description_lines(s)
  local meta = { string.format("`%s`", label(s)) }
  if s.author then
    meta[#meta + 1] = "by @" .. s.author
  end
  meta[#meta + 1] = string.format("`%s` ← `%s`", s.base_ref or "?", s.head_ref or "?")
  local state = s.state or "open"
  meta[#meta + 1] = s.draft and (state .. ", draft") or state
  local lines = { "# " .. (s.title or "(no title)"), "", table.concat(meta, " · ") }
  if s.labels and #s.labels > 0 then
    lines[#lines + 1] = "labels: " .. table.concat(s.labels, ", ")
  end
  if s.url then
    lines[#lines + 1] = s.url
  end
  vim.list_extend(lines, { "", "---", "" })
  local body = vim.trim(s.body or "")
  vim.list_extend(lines, vim.split(body ~= "" and body or "_No description provided._", "\n", { plain = true }))
  return lines
end

local desc_win

---Show the PR title and description in a read-only markdown float.
function M.description(root)
  local s = root and session.load(root)
  if not s or s.kind ~= "pr" then
    return notify("not in a PR review", vim.log.levels.WARN)
  end
  if desc_win and api.nvim_win_is_valid(desc_win) then
    api.nvim_win_close(desc_win, true)
  end
  local lines = M.description_lines(s)
  local buf = api.nvim_create_buf(false, true)
  api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].filetype = "markdown"
  vim.bo[buf].modifiable = false
  vim.bo[buf].bufhidden = "wipe"
  local width = math.min(100, vim.o.columns - 6)
  local height = math.max(5, math.min(#lines + 1, vim.o.lines - 8))
  desc_win = api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width,
    height = height,
    row = math.floor((vim.o.lines - height) / 2) - 1,
    col = math.floor((vim.o.columns - width) / 2),
    style = "minimal",
    border = "rounded",
    title = " PR description  (q to close) ",
    title_pos = "center",
  })
  vim.wo[desc_win].wrap = true
  vim.wo[desc_win].linebreak = true
  vim.wo[desc_win].conceallevel = 2
  for _, key in ipairs({ "q", "<Esc>" }) do
    vim.keymap.set("n", key, function()
      if api.nvim_win_is_valid(desc_win) then
        api.nvim_win_close(desc_win, true)
      end
    end, { buffer = buf, desc = "Close PR description" })
  end
end

---The PR file the user is on: the buffer's file in a diff pane, the row under
---the cursor in the sidebar, or a PR item in a quickfix list (thread list).
---@return string? root, string? file
function M.where()
  local u = vim.b.code_review_unified
  if u then
    return u.root, u.file
  end
  local root, file = session.infer(api.nvim_buf_get_name(0))
  if root then
    return root, file
  end
  local sroot, row = sidebar.at_cursor()
  if sroot then
    return sroot, row and row.kind == "file" and row.path or nil
  end
  if vim.bo.buftype == "quickfix" then
    local item = vim.fn.getqflist()[vim.fn.line(".")]
    if item and item.bufnr and item.bufnr > 0 then
      local r, f = session.infer(api.nvim_buf_get_name(item.bufnr))
      if r then
        return r, f
      end
    end
  end
end

---Show the next (dir = 1) or previous (-1) changed file. It stops at the first
---and last file instead of wrapping around. Files marked as viewed are skipped
---unless `include_viewed` is true.
---@return boolean moved
function M.step(dir, include_viewed)
  local root, file = M.where()
  local s = root and session.load(root)
  if not s then
    notify("not in a PR review", vim.log.levels.WARN)
    return false
  end
  local i, n, order = position(s, file)
  if n == 0 then
    return false
  end
  local viewed = include_viewed and {} or M.viewed(root)
  local from = i or (dir > 0 and 0 or n + 1)
  local skipped = 0
  for j = from + dir, dir > 0 and n or 1, dir do
    local cand = order[j]
    if viewed[cand.path] then
      skipped = skipped + 1
    else
      M.show_file(root, cand.path)
      return true
    end
  end
  -- nothing further in this direction; say how many unreviewed files are elsewhere
  local other = 0
  for j, f in ipairs(order) do
    if j ~= from and not viewed[f.path] and ((dir > 0 and j < from) or (dir < 0 and j > from)) then
      other = other + 1
    end
  end
  local msg = dir > 0 and "last file of the PR" or "first file of the PR"
  if skipped > 0 then
    msg = string.format("no more unreviewed files this way (%d viewed skipped)", skipped)
  end
  if other > 0 then
    msg = msg .. string.format("; %d unreviewed file%s the other way (%s)", other, other == 1 and "" or "s", dir > 0 and "[f" or "]f")
  end
  notify(msg)
  M.maybe_summary(root, true)
  return false
end

local summary_shown = {} -- root -> true once the "review complete" summary was shown

---Text of the end-of-review summary.
function M.summary_text(root)
  local c = cached(root)
  local s = c.s
  local n_viewed = 0
  for _, f in ipairs(s.files or {}) do
    if c.viewed[f.path] then
      n_viewed = n_viewed + 1
    end
  end
  local ok, data = pcall(require("code-review.store").read, root)
  local yours, agents, resolved = 0, 0, 0
  for _, t in ipairs(ok and data.threads or {}) do
    if t.status == "resolved" then
      resolved = resolved + 1
    elseif t.needs == "user" then
      yours = yours + 1
    elseif t.needs == "agent" then
      agents = agents + 1
    end
  end
  local text = string.format("Review of %s: %d/%d files viewed", label(s), n_viewed, #(s.files or {}))
  local open = yours + agents
  if open + resolved == 0 then
    return text .. " · no comments."
  end
  text = text .. string.format(" · %d open thread%s", open, open == 1 and "" or "s")
  local parts = {}
  if yours > 0 then
    parts[#parts + 1] = string.format("%d wait%s for you", yours, yours == 1 and "s" or "")
  end
  if agents > 0 then
    parts[#parts + 1] = string.format("%d for the agent", agents)
  end
  if #parts > 0 then
    text = text .. " (" .. table.concat(parts, ", ") .. ")"
  end
  if resolved > 0 then
    text = text .. string.format(" · %d resolved", resolved)
  end
  if yours > 0 then
    local km = require("code-review").config.keymaps or {}
    local key = require("code-review.keys").label(km.next_yours)
    text = text .. (key and string.format(". %s jumps to the ones waiting for you.", key) or ".")
  end
  return text
end

---When every file is viewed, say how the review went: once when the last file
---gets marked, again on request (`force`, e.g. ]f at the end of the PR).
---@return boolean shown
function M.maybe_summary(root, force)
  local c = cached(root)
  if not c then
    return false
  end
  for _, f in ipairs(c.s.files or {}) do
    if not c.viewed[f.path] then
      summary_shown[root] = nil -- not done (any more): announce again when it is
      return false
    end
  end
  if summary_shown[root] and not force then
    return false
  end
  summary_shown[root] = true
  notify("✓ " .. M.summary_text(root))
  return true
end

---Mark `file` as viewed (or clear the mark) and refresh the list. Marking moves
---on to the next file that is still unreviewed.
---@param file? string defaults to the file on screen
function M.toggle_viewed(root, file)
  local s = session.load(root)
  if not s or s.kind ~= "pr" then
    return notify("not in a PR review", vim.log.levels.WARN)
  end
  if not file then
    local _, f = M.where()
    file = f
  end
  if not file or not entry(s, file) then
    return notify("no PR file on screen", vim.log.levels.WARN)
  end
  local now = not session.viewed_map(root)[file]
  session.set_viewed(root, file, now)
  M.refresh_cache(root)
  vim.cmd("redrawstatus!")
  sidebar.render(root)
  if now then
    if M.maybe_summary(root) then
      return
    end
    M.step(1)
  else
    M.maybe_summary(root) -- not complete any more: the next completion is announced again
    notify(file .. ": marked as not viewed")
  end
end

---Show or hide the sidebar of the review. With `position` ("left", "right",
---"bottom", "top") it moves there (and shows) instead.
function M.toggle_sidebar(root, position)
  if position then
    if not sidebar.POSITIONS[position] then
      return notify("position must be left, right, bottom or top", vim.log.levels.WARN)
    end
    require("code-review").config.sidebar_position = position
    sidebar.close()
    sidebar_hidden[root] = nil
    M.files(root, true)
    vim.cmd("wincmd =")
    return
  end
  if sidebar.find_win() then
    sidebar_hidden[root] = true
    return sidebar.close()
  end
  sidebar_hidden[root] = nil
  M.files(root, true)
end

---Close the review tab (and everything in it).
function M.close()
  if tab and api.nvim_tabpage_is_valid(tab) and #api.nvim_list_tabpages() > 1 then
    vim.cmd.tabclose(api.nvim_tabpage_get_number(tab))
  end
  tab = nil
end

---Progress of opening a PR, drawn in place on the command line (not as one
---notification per update). `done`/`total` nil = still reading the PR itself.
function M.show_progress(name, done, total)
  local text
  if not total then
    text = string.format("code-review: fetching %s …", name)
  else
    local width = 10
    local filled = total > 0 and math.floor(done / total * width + 0.5) or width
    text = string.format("code-review: fetching %s  %s%s %d/%d files", name, string.rep("▰", filled), string.rep("▱", width - filled), done, total)
  end
  api.nvim_echo({ { text, "Comment" } }, false, {})
  pcall(vim.cmd.redraw)
end

---Reopen a review from its local snapshots, without the network, at the first
---file not viewed yet.
function M.resume(root)
  require("code-review").setup_once()
  local s = session.load(root)
  if not s or s.kind ~= "pr" then
    return notify("no such review", vim.log.levels.WARN)
  end
  M.refresh_cache(root)
  local order = sidebar.ordered(s)
  if #order == 0 then
    return M.files(root)
  end
  local viewed = M.viewed(root)
  local target = order[1]
  for _, f in ipairs(order) do
    if not viewed[f.path] then
      target = f
      break
    end
  end
  M.show_file(root, target.path)
  return root
end

---One line about a review for the "recent reviews" list.
function M.review_line(r)
  local s, root = r.session, r.root
  local viewed, n_viewed = session.viewed_map(root), 0
  for _, f in ipairs(s.files or {}) do
    if viewed[f.path] then
      n_viewed = n_viewed + 1
    end
  end
  local ok, data = pcall(require("code-review.store").read, root)
  local yours = 0
  for _, t in ipairs(ok and data.threads or {}) do
    if t.needs == "user" and t.status ~= "resolved" then
      yours = yours + 1
    end
  end
  local ago = r.last > 0 and require("code-review").reltime(os.date("!%Y-%m-%dT%H:%M:%SZ", r.last)) or ""
  local parts = { label(s), s.title or "", string.format("%d/%d viewed", n_viewed, #(s.files or {})) }
  if yours > 0 then
    parts[#parts + 1] = string.format("%d waiting for you", yours)
  end
  if ago ~= "" then
    parts[#parts + 1] = ago
  end
  return table.concat(parts, " · ")
end

---Pick one of the reviews on this machine and resume it.
function M.recent()
  local list = session.reviews()
  if #list == 0 then
    return notify("no reviews yet: open one with :CodeReview pr <url>")
  end
  vim.ui.select(list, { prompt = "Recent reviews", format_item = M.review_line }, function(r)
    if not r then
      return
    end
    local s = r.session
    if M.has_snapshots(r.root) then
      M.resume(r.root)
    else -- the cache was wiped: download the files again
      M.fetch(r.root, { host = s.host or "github.com", owner = s.owner, repo = s.repo, number = s.number })
    end
  end)
end

---Fetch a PR (URL or owner/repo#n) and start reviewing it, without blocking:
---a PR reviewed before opens at once from its snapshots (and is checked for new
---commits in the background); a new one opens as soon as its file list is known
---and the files fill in as they arrive.
function M.open(refstr)
  require("code-review").setup_once()
  local ref, err = github.parse_ref(refstr)
  if not ref then
    return notify(err, vim.log.levels.ERROR)
  end
  local root = session.dirs(ref)
  local cached = session.load(root)
  if cached and cached.kind == "pr" and cached.head_sha and M.complete(root) then
    M.resume(root)
    M.check_updates(root, true)
    return root
  end
  return M.fetch(root, ref)
end

---Are all snapshots of the review on disk (it can open without the network)?
function M.complete(root)
  local s = session.load(root)
  for _, f in ipairs(s and s.files or {}) do
    if f.status ~= "added" and not vim.uv.fs_stat(session.snapshot_path_in(s.cache, f.path, "old")) then
      return false
    end
    if f.status ~= "removed" and not vim.uv.fs_stat(session.snapshot_path_in(s.cache, f.path, "new")) then
      return false
    end
  end
  return s ~= nil
end

---Is any snapshot of the review on disk? (false: never downloaded, or the cache was wiped)
function M.has_snapshots(root)
  local s = session.load(root)
  for _, f in ipairs(s and s.files or {}) do
    for _, side in ipairs({ "old", "new" }) do
      if vim.uv.fs_stat(session.snapshot_path_in(s.cache, f.path, side)) then
        return true
      end
    end
  end
  return false
end

---Is the review tab still open? (it may have been closed during a download)
local function tab_open()
  return tab ~= nil and api.nvim_tabpage_is_valid(tab)
end

local return_group = api.nvim_create_augroup("code-review-diff-return", { clear = true })

---Show `file` once it has arrived, without pulling the user away from another
---tab: there it waits until they come back to the review tab (the latest wins).
local function show_arrived(root, file)
  if not tab_open() then
    return
  end
  api.nvim_clear_autocmds({ group = return_group })
  if api.nvim_get_current_tabpage() == tab then
    local win = api.nvim_get_current_win()
    M.show_file(root, file)
    if api.nvim_win_is_valid(win) and sidebar.is_sidebar(win) then
      api.nvim_set_current_win(win)
    end
    return
  end
  api.nvim_create_autocmd("TabEnter", {
    group = return_group,
    callback = function()
      if not tab_open() then
        return true -- the review tab was closed: nothing to show
      end
      if api.nvim_get_current_tabpage() == tab then
        vim.schedule(function()
          if tab_open() and api.nvim_get_current_tabpage() == tab then
            M.show_file(root, file)
          end
        end)
        return true
      end
    end,
  })
end

M.render_every_ms = 100 -- sidebar redraws while files arrive (a big PR sends thousands)

---Download (or re-download) the PR of `root` in the background and keep the
---review on screen up to date.
function M.fetch(root, ref)
  if loading[root] then
    notify("already downloading this PR")
    return root
  end
  local name = string.format("%s/%s#%d", ref.owner, ref.repo, ref.number)
  local had = session.load(root)
  local was_shown = had and shown[root]
  -- decided now: a review tab closed *during* the download must stay closed
  local on_screen = was_shown and tab_open()
  loading[root] = true
  M.show_progress(name, nil, nil)
  local cr = require("code-review")
  local last_render = 0
  local ok, err = pcall(github.open_pr_async, ref, {
    on_meta = function(r)
      M.refresh_cache(r)
      if on_screen then
        sidebar.render(r)
      elseif was_shown then -- reloaded with its tab closed: open it again at that file
        M.show_file(r, was_shown)
      else -- new, or reviewed before but not open: the first file not viewed yet
        M.resume(r)
      end
    end,
    on_file = function(path)
      local now = vim.uv.now()
      if now - last_render >= M.render_every_ms then -- on_done draws the final state
        last_render = now
        sidebar.render(root)
      end
      -- the file on screen (or its "loading…" placeholder) gets the side that arrived,
      -- unless the review tab was closed meanwhile (that would reopen it)
      if tab_open() and (waiting[root] == path or (not on_screen and shown[root] == path)) then
        waiting[root] = nil
        show_arrived(root, path)
      end
    end,
    on_progress = function(done, total)
      M.show_progress(name, done, total)
    end,
    on_done = function(r, ferr, failed)
      loading[root] = nil
      -- a "loading…" placeholder whose file never came (e.g. a 500) is shown again,
      -- now with the usual "no text content" message
      local pending = waiting[root]
      waiting[root] = nil
      if not r then
        local msg = ferr or "could not open the PR"
        if had and not on_screen and M.has_snapshots(root) then
          -- reviewed before (e.g. offline now): open what is on disk
          vim.notify(cr.one_line("code-review: could not download the PR, showing your saved copy: " .. msg), vim.log.levels.WARN)
          return M.resume(root)
        end
        return vim.notify(cr.one_line("code-review: " .. msg), vim.log.levels.ERROR)
      end
      updates[r] = nil
      M.refresh_cache(r)
      sidebar.render(r)
      local s = session.load(r)
      local bad = vim.tbl_keys(failed or {})
      if #bad > 0 then
        table.sort(bad)
        -- one line (a list of every path stops Neovim at "Press ENTER")
        local first, why = table.concat(vim.list_slice(bad, 1, 3), ", "), failed[bad[1]]
        local more = #bad > 3 and string.format(" and %d more", #bad - 3) or ""
        vim.notify(cr.one_line(string.format("code-review: %d file(s) could not be downloaded: %s%s (%s)", #bad, first, more, why)),
          vim.log.levels.WARN)
      end
      local km = cr.config.keymaps or {}
      local step = require("code-review.keys").label(km.next_file)
      local help = require("code-review.keys").label(km.help) or "?"
      local since = s.previous and " · :CodeReview since: changes since your last review" or ""
      -- one line: a longer message stops Neovim at "Press ENTER"
      vim.notify(cr.one_line(string.format("code-review: %s: %d changed files%s · %s keys%s", name, #s.files,
        step and (" · " .. step .. " next file") or "", help, since)))
      local again = pending or (had and was_shown)
      if again then
        show_arrived(r, again) -- the same file, now at the new commit
      end
    end,
  })
  if not ok then -- e.g. a disk error before any request: never stay "already downloading"
    loading[root] = nil
    vim.notify(cr.one_line("code-review: could not open the PR: " .. tostring(err)), vim.log.levels.ERROR)
  end
  return root
end

---Fetch the PR again (new commits), keeping the previous version for "since".
function M.reload(root)
  local s = session.load(root)
  if not s or s.kind ~= "pr" then
    return notify("not in a PR review", vim.log.levels.WARN)
  end
  return M.fetch(root, { host = s.host or "github.com", owner = s.owner, repo = s.repo, number = s.number })
end

M.check_every = 180 -- seconds between background update checks

---Ask GitHub, in the background, whether the PR got new commits; if so show a
---banner (sidebar + notification). Throttled; `force` skips the throttle.
function M.check_updates(root, force)
  local s = session.load(root)
  if not s or s.kind ~= "pr" or loading[root] then
    return
  end
  local now = os.time()
  if not force and last_check[root] and now - last_check[root] < M.check_every then
    return
  end
  last_check[root] = now
  github.check_update(s, function(info)
    if not info or (info.head_sha == s.head_sha and info.base_sha == s.base_sha) then
      return
    end
    local new = (info.commits and s.commits) and math.max(0, info.commits - s.commits) or nil
    updates[root] = { commits = new }
    sidebar.render(root)
    local key = "U in the sidebar or :CodeReview reload"
    notify(string.format("this PR was updated%s · %s", new and string.format(" (%d new commit%s)", new, new == 1 and "" or "s") or "", key), vim.log.levels.WARN)
  end)
end

-- Keys of the thread list: act on the thread under the cursor.
-- Bindings (keymaps.thread) of the thread list: the thread under the cursor, or
-- the list itself (`list`).
M.QF_ACTIONS = {
  reply = { function(root, tid) require("code-review").reply(root, tid) end, "reply" },
  edit = { function(root, tid) require("code-review").edit(root, tid) end, "edit your last message" },
  resolve = { function(root, tid) require("code-review").toggle_resolved(root, tid) end, "resolve / reopen" },
  approve = { function(root, tid) require("code-review").toggle_approved(root, tid) end, "approve / withdraw a code change" },
  delete = { function(root, tid) require("code-review").delete(root, tid) end, "delete the thread" },
  send = { function(root) require("code-review").poke(root) end, "send to the agent" },
  help = { function() require("code-review").help("list") end, "keys", list = true },
  close = { function() vim.cmd.cclose() end, "close the thread list", list = true },
}

---Run a binding of the thread list (see QF_ACTIONS).
function M.qf_action(name)
  local a = M.QF_ACTIONS[name]
  local root, tid = require("code-review").qf_thread()
  if root or (a.list and require("code-review").is_thread_list()) then
    a[1](root, tid)
  end
end

function M.attach_quickfix(group)
  api.nvim_create_autocmd("FileType", {
    group = group,
    pattern = "qf",
    callback = function(ev)
      -- ]f / [f are Neovim's built-in "gf" here, which fails on the first word of
      -- a row (E447). On a PR item (e.g. the thread list of a review) they step files.
      local km = require("code-review").config.keymaps or {}
      local keys = require("code-review.keys")
      local steps = {}
      for _, lhs in ipairs(keys.list(km.next_file)) do steps[lhs] = 1 end
      for _, lhs in ipairs(keys.list(km.prev_file)) do steps[lhs] = -1 end
      for lhs, dir in pairs(steps) do
        vim.keymap.set("n", lhs, function()
          if M.where() then
            M.step(dir)
          else
            vim.cmd("normal! " .. lhs) -- some other list: keep the built-in
          end
        end, { buffer = ev.buf, desc = "Code review: next/previous PR file" })
      end
      local cr = require("code-review")
      -- a thread list: jump to the thread and open it; a click does the same
      local function default_click(keys)
        api.nvim_feedkeys(api.nvim_replace_termcodes(keys, true, false, true), "n", false)
      end
      -- the keys of the thread window act on the thread under the cursor (q closes the list)
      local tk = keys.group("thread")
      for name, a in pairs(M.QF_ACTIONS) do
        for _, key in ipairs(keys.list(tk[name])) do
          -- expr: in any other list the key keeps its built-in meaning (search, macros, ...)
          vim.keymap.set("n", key, function()
            local loclist = vim.fn.getwininfo(api.nvim_get_current_win())[1].loclist == 1
            local ours = not loclist and (a.list and cr.is_thread_list() or cr.qf_thread() ~= nil)
            return ours and string.format("<Cmd>lua require('code-review.diff').qf_action(%q)<CR>", name) or key
          end, { buffer = ev.buf, expr = true, desc = "Code review: " .. a[2] })
        end
      end
      vim.keymap.set("n", "<2-LeftMouse>", function()
        if not cr.open_qf_item() then
          default_click("<2-LeftMouse>")
        end
      end, { buffer = ev.buf, desc = "Code review: open the thread" })
      if cr.config.mouse ~= false then
        vim.keymap.set("n", "<LeftRelease>", function()
          if cr.is_thread_list() and vim.fn.getwininfo(api.nvim_get_current_win())[1].loclist ~= 1 then
            cr.open_qf_item()
          end
        end, { buffer = ev.buf, desc = "Code review: open the thread" })
      end
      vim.keymap.set("n", "<CR>", function()
        if cr.open_qf_item() then
          return
        end
        local idx = vim.fn.line(".")
        local loclist = vim.fn.getwininfo(api.nvim_get_current_win())[1].loclist == 1
        local items = loclist and vim.fn.getloclist(0) or vim.fn.getqflist()
        local item = items[idx]
        local root, file, side, line
        if item then
          local ud = item.user_data
          if type(ud) == "table" and ud.root then
            root, file = ud.root, ud.file
          elseif item.bufnr and item.bufnr > 0 then
            root, file, side = session.infer(api.nvim_buf_get_name(item.bufnr))
            line = item.lnum
          end
        end
        if root and session.load(root) then
          M.show_file(root, file, side, line)
        else
          vim.cmd((loclist and "ll " or "cc ") .. idx)
        end
      end, { buffer = ev.buf, desc = "Code review: open item (PR diff aware)" })
    end,
  })
end

return M
