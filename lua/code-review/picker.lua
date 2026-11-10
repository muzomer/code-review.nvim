-- Pickers: jump to a file of the PR or to a thread, with a preview.
-- Uses fzf-lua when installed (builtin previewer), else vim.ui.select.
local session = require("code-review.session")
local store = require("code-review.store")

local api = vim.api
local M = {}

local function notify(msg, level)
  vim.notify("code-review: " .. msg, level or vim.log.levels.INFO)
end

local STATUS = { added = "A", removed = "D", modified = "M", renamed = "R" }

---Picker entries for the files of a PR review.
---Each: { text = "head/lib/a.py:1: M +4 -3", file, side, line }
function M.file_entries(root)
  local s = session.load(root)
  if not session.is_snapshots(s) then
    return {}
  end
  -- a commits review's paths start at the commit (the picker runs in the cache of all commits)
  local prefix = s.kind == "commits" and (s.current .. "/") or ""
  local viewed = require("code-review.diff").viewed(root)
  local res = {}
  for _, f in ipairs(require("code-review.sidebar").ordered(s)) do
    local side = f.status == "removed" and "old" or "new"
    res[#res + 1] = {
      text = string.format(
        "%s%s/%s:1: %s +%d -%d%s",
        prefix, side == "old" and "base" or "head", f.path, STATUS[f.status] or "?",
        f.additions or 0, f.deletions or 0, viewed[f.path] and "  ✓ viewed" or ""
      ),
      file = f.path,
      side = side,
    }
  end
  return res
end

---Picker entries for the open threads (all of them with `all`).
function M.thread_entries(root, all)
  local ok, data = pcall(store.read, root)
  local pr = session.load(root)
  local res = {}
  for _, t in ipairs(ok and data.threads or {}) do
    if (all or t.status ~= "resolved") and not store.is_general(t) then
      local last = t.messages[#t.messages]
      local where = t.file
      if session.is_snapshots(pr) then
        where = (t.side == "old" and "base/" or "head/") .. t.file
        if pr.kind == "commits" then
          where = (t.commit or pr.current) .. "/" .. where
        end
      end
      local w = require("code-review").waiting(t)
      res[#res + 1] = {
        loc = string.format("%s:%d:", where, t.range.start),
        turn = w.label,
        rest = string.format("%s: %s", last.author == "user" and "you" or last.author, (last.body:match("^[^\n]*"))),
        rank = w.rank,
        file = t.file,
        side = t.side or "new",
        line = t.range.start,
        tid = t.id,
        commit = t.commit,
      }
    end
  end
  table.sort(res, function(a, b) -- waiting for you first, like the quickfix list
    if a.rank ~= b.rank then
      return a.rank < b.rank
    end
    if a.file ~= b.file then
      return a.file < b.file
    end
    return a.line < b.line
  end)
  -- aligned columns: location, whose turn, message (fzf still reads "path:line:" first)
  local w_loc, w_turn = 0, 0
  for _, e in ipairs(res) do
    w_loc = math.max(w_loc, vim.fn.strdisplaywidth(e.loc))
    w_turn = math.max(w_turn, vim.fn.strdisplaywidth(e.turn))
  end
  local function pad(text, w)
    return text .. string.rep(" ", w - vim.fn.strdisplaywidth(text))
  end
  for _, e in ipairs(res) do
    e.text = pad(e.loc, w_loc) .. " " .. pad(e.turn, w_turn) .. "  " .. e.rest
  end
  return res
end

---Open an entry: the PR diff at that side and line, or the project file.
function M.open(root, e)
  local pr = session.load(root)
  if session.is_snapshots(pr) then
    if e.commit then
      require("code-review.commits").ensure_current(root, e)
    end
    require("code-review.diff").show_file(root, e.file, e.side, e.line)
  else
    vim.cmd.edit(vim.fn.fnameescape(root .. "/" .. e.file))
    pcall(api.nvim_win_set_cursor, 0, { e.line or 1, 0 })
    require("code-review").flash()
  end
  if e.tid then
    require("code-review").open_thread(root, e.tid)
  end
end

---Use fzf-lua? (replaceable in tests)
function M.fzf()
  local ok, fzf = pcall(require, "fzf-lua")
  return ok and fzf or nil
end

---Show `entries` in a picker and open the chosen one.
function M.pick(root, entries, title)
  if #entries == 0 then
    return notify("nothing to pick")
  end
  local fzf = M.fzf()
  if fzf then
    local by_text = {}
    for _, e in ipairs(entries) do
      by_text[e.text] = e
    end
    local pr = session.load(root)
    fzf.fzf_exec(vim.tbl_map(function(e) return e.text end, entries), {
      prompt = title .. "> ",
      -- entries are relative to this, for the preview
      cwd = (pr and pr.kind == "pr") and pr.cache or (pr and pr.kind == "commits") and pr.cache_base or root,
      previewer = "builtin",
      actions = {
        default = function(selected)
          local e = selected and by_text[selected[1]]
          if e then
            M.open(root, e)
          end
        end,
      },
    })
    return
  end
  vim.ui.select(entries, {
    prompt = title,
    format_item = function(e)
      return e.text
    end,
  }, function(e)
    if e then
      M.open(root, e)
    end
  end)
end

function M.files(root)
  M.pick(root, M.file_entries(root), "PR files")
end

function M.threads(root, all)
  M.pick(root, M.thread_entries(root, all), "Threads")
end

return M
