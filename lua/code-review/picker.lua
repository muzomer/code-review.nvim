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
  if not s or s.kind ~= "pr" then
    return {}
  end
  local viewed = require("code-review.diff").viewed(root)
  local res = {}
  for _, f in ipairs(require("code-review.sidebar").ordered(s)) do
    local side = f.status == "removed" and "old" or "new"
    res[#res + 1] = {
      text = string.format(
        "%s/%s:1: %s +%d -%d%s",
        side == "old" and "base" or "head", f.path, STATUS[f.status] or "?",
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
    if all or t.status ~= "resolved" then
      local last = t.messages[#t.messages]
      local where = t.file
      if pr and pr.kind == "pr" then
        where = (t.side == "old" and "base/" or "head/") .. t.file
      end
      local state = t.status == "resolved" and "resolved" or (t.needs == "user" and "needs you" or "needs " .. t.needs)
      res[#res + 1] = {
        text = string.format("%s:%d: [%s] %s: %s", where, t.range.start, state, last.author == "user" and "you" or last.author, (last.body:match("^[^\n]*"))),
        file = t.file,
        side = t.side or "new",
        line = t.range.start,
        tid = t.id,
      }
    end
  end
  table.sort(res, function(a, b)
    if a.file ~= b.file then
      return a.file < b.file
    end
    return a.line < b.line
  end)
  return res
end

---Open an entry: the PR diff at that side and line, or the project file.
function M.open(root, e)
  local pr = session.load(root)
  if pr and pr.kind == "pr" then
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
      cwd = (pr and pr.kind == "pr") and pr.cache or root, -- entries are relative to this, for the preview
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
