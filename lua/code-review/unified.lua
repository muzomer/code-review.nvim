-- Unified diff view: one buffer, old and new lines interleaved like on GitHub.
--
-- The buffer holds the plain code (no +/- in the text, so syntax highlighting
-- works); a status column shows the old and new line numbers and +/-, and
-- changed rows get the review colors. Every row maps to a line of the old side,
-- the new side, or both, so comments and threads keep their real positions.
local session = require("code-review.session")
local hunks = require("code-review.hunks")

local api = vim.api
local M = {}

M.context = 3 -- unchanged lines kept open around each change; longer stretches fold

local ns = api.nvim_create_namespace("code-review-unified")
local data = {} -- buf -> { root, file, rows, old = { [line] = row }, new = { [line] = row } }

---Rows of the unified view: { kind = "ctx"|"del"|"add", old?, new?, text }.
---@param old string[]
---@param new string[]
function M.rows(old, new)
  local rows, oi, ni = {}, 1, 1
  local function same_until(old_stop)
    while oi < old_stop do
      rows[#rows + 1] = { kind = "ctx", old = oi, new = ni, text = new[ni] or old[oi] }
      oi, ni = oi + 1, ni + 1
    end
  end
  for _, h in ipairs(hunks.indices(old, new)) do
    local sa, ca, sb, cb = h[1], h[2], h[3], h[4]
    same_until(ca == 0 and sa + 1 or sa)
    for k = 0, ca - 1 do
      rows[#rows + 1] = { kind = "del", old = sa + k, text = old[sa + k] }
    end
    for k = 0, cb - 1 do
      rows[#rows + 1] = { kind = "add", new = sb + k, text = new[sb + k] }
    end
    if ca > 0 then
      oi = sa + ca
    end
    if cb > 0 then
      ni = sb + cb
    end
  end
  same_until(#old + 1)
  return rows
end

---Does `buf` show "since your last review" (its old lines are the previous head)?
function M.is_since(buf)
  return data[buf] ~= nil and data[buf].since == true
end

---Is `buf` a unified view? Returns its { root, file }.
function M.info(buf)
  local d = data[buf]
  return d and { root = d.root, file = d.file }
end

---Row of `line` on `side` ("old"|"new") in the unified buffer.
function M.row_of(buf, side, line)
  local d = data[buf]
  if not d then
    return nil
  end
  return (side == "old" and d.old or d.new)[line]
end

---The row record at a buffer row.
function M.at(buf, row)
  local d = data[buf]
  return d and d.rows[row]
end

---Turn a range of buffer rows into a side and a line range on it, for a new
---comment: a removed row comments on the old side, anything else on the new side.
---@return ("old"|"new")? side nil: the row only exists in your last review (since view)
---@return integer first, integer last
function M.translate(buf, row1, row2)
  local d = data[buf]
  local r1 = d and d.rows[row1]
  if not r1 then
    return nil, "nothing to comment on here" -- an empty view (e.g. a file without text)
  end
  if d.since and r1.kind == "del" then
    return nil -- that line is gone from the PR: there is no code to comment on
  end
  local side = r1.kind == "del" and "old" or "new"
  local function line_on(r)
    return r and (side == "old" and r.old or r.new)
  end
  local first = line_on(r1)
  local last
  for row = row2, row1, -1 do
    last = line_on(d.rows[row])
    if last then
      break
    end
  end
  return side, first, math.max(first, last or first)
end

---Status column: old and new line numbers and +/-.
function M.statuscol()
  local win = vim.g.statusline_winid or api.nvim_get_current_win()
  local d = data[api.nvim_win_get_buf(win)]
  local r = d and vim.v.virtnum == 0 and d.rows[vim.v.lnum]
  if not r then
    return "%s" .. string.rep(" ", 12)
  end
  local mark = r.kind == "add" and "+" or r.kind == "del" and "-" or " "
  local hl = r.kind == "add" and "CodeReviewStatAdd" or r.kind == "del" and "CodeReviewStatDel" or "LineNr"
  return string.format("%%s%%#%s#%4s %4s %s %%*", hl, r.old or "", r.new or "", mark)
end

local STATUSCOL = "%{%v:lua.require'code-review.unified'.statuscol()%}"

---Jump to the next (1) or previous (-1) block of changes. Stops at the ends.
function M.next_change(dir)
  local buf = api.nvim_get_current_buf()
  local d = data[buf]
  if not d then
    return
  end
  local row = api.nvim_win_get_cursor(0)[1]
  local n = #d.rows
  local function starts_block(i)
    local r, prev = d.rows[i], d.rows[i - 1]
    return r and r.kind ~= "ctx" and (not prev or prev.kind == "ctx")
  end
  local i = row + dir
  while i >= 1 and i <= n do
    if starts_block(i) then
      vim.cmd("normal! m'")
      api.nvim_win_set_cursor(0, { i, 0 })
      vim.cmd("normal! zv")
      return
    end
    i = i + dir
  end
  vim.notify("code-review: no more changes " .. (dir > 0 and "below" or "above"))
end

---Show `file` of the PR as a unified view in `win`.
---@return integer buf
---@param opts? { old_lines?: string[], since?: boolean } since = previous head → current head
function M.show(root, file, win, foldtext, opts)
  opts = opts or {}
  local old = opts.old_lines or session.lines(root, file, { side = "old" }) or {}
  local new = session.lines(root, file) or {}
  -- readfile() turns a NUL byte into "\n", which a buffer line cannot hold;
  -- "\0" is how a buffer line spells NUL (binary files then show as text)
  local function nul(lines)
    return vim.tbl_map(function(l) return (l:gsub("\n", "\0")) end, lines)
  end
  old, new = nul(old), nul(new)
  local rows = M.rows(old, new)

  local name = "code-review://" .. (opts.since and "since/" or "unified/") .. (root:match("[^/]+/[^/]+/[^/]+/pr%-%d+$") or root) .. "/" .. file
  local existing = vim.fn.bufnr(name)
  if existing ~= -1 then
    pcall(api.nvim_buf_delete, existing, { force = true })
  end
  local buf = api.nvim_create_buf(false, true)
  pcall(api.nvim_buf_set_name, buf, name)
  vim.bo[buf].bufhidden = "wipe"
  vim.b[buf].code_review_unified = { root = root, file = file }
  local text = {}
  local d = { root = root, file = file, rows = rows, old = {}, new = {}, since = opts.since }
  for i, r in ipairs(rows) do
    text[i] = r.text or ""
    if r.old then
      d.old[r.old] = i
    end
    if r.new then
      d.new[r.new] = i
    end
  end
  data[buf] = d
  api.nvim_buf_set_lines(buf, 0, -1, false, text)
  vim.bo[buf].modifiable = false
  local ft = vim.filetype.match({ filename = file })
  if ft then
    vim.bo[buf].filetype = ft
  end
  for i, r in ipairs(rows) do
    if r.kind ~= "ctx" then
      api.nvim_buf_set_extmark(buf, ns, i - 1, 0, {
        line_hl_group = r.kind == "add" and "CodeReviewDiffAdded" or "CodeReviewDiffRemoved",
        priority = 10,
      })
    end
  end
  api.nvim_create_autocmd("BufWipeout", {
    buffer = buf,
    once = true,
    callback = function()
      data[buf] = nil
    end,
  })
  vim.keymap.set("n", "]c", function() M.next_change(1) end, { buffer = buf, desc = "Code review: next change" })
  vim.keymap.set("n", "[c", function() M.next_change(-1) end, { buffer = buf, desc = "Code review: previous change" })

  api.nvim_win_set_buf(win, buf)
  for opt, val in pairs({
    statuscolumn = STATUSCOL, signcolumn = "yes:1", number = false, relativenumber = false,
    foldmethod = "manual", foldenable = true, foldlevel = 0, foldtext = foldtext or vim.go.foldtext,
    fillchars = "fold: ", wrap = false,
  }) do
    vim.wo[win][opt] = val
  end
  -- fold long unchanged stretches, keeping some context around each change
  api.nvim_win_call(win, function()
    vim.cmd("silent! normal! zE")
    local start
    for i = 1, #rows + 1 do
      local ctx = rows[i] and rows[i].kind == "ctx"
      if ctx and not start then
        start = i
      elseif not ctx and start then
        local first = start == 1 and 1 or start + M.context
        local last = i == #rows + 1 and i - 1 or i - 1 - M.context
        if last - first >= 1 then
          vim.cmd(string.format("%d,%dfold", first, last))
        end
        start = nil
      end
    end
  end)
  return buf
end

return M
