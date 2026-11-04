-- Conversation panel: the current thread as a chat, docked on the right, with
-- an input box under it. Opt-in (config.conversation = "panel"); the thread
-- float stays the default.
--
--   ┌ t_ab12 · src/auth.py:40 ───────┐
--   │ you · 5 min ago                │
--   │ why swallow the error?         │
--   │ claude · just now              │
--   │ it is retried by the caller    │
--   ├ reply · <C-s> send · <M-s> +poke┤
--   │ |                              │
--   └────────────────────────────────┘
local store = require("code-review.store")

local api = vim.api
local M = {}

local state -- { root, tid, conv = { buf, win }, input = { buf, win }, edit = bool }

local function cr()
  return require("code-review")
end

local function valid(w)
  return w and api.nvim_win_is_valid(w.win) and api.nvim_buf_is_valid(w.buf)
end

---Width of the panel: config.panel_width, else ~35% of the screen (40..70).
function M.width()
  return cr().config.panel_width or math.max(40, math.min(70, math.floor(vim.o.columns * 0.35)))
end

function M.is_open()
  return state ~= nil and valid(state.conv) and valid(state.input)
end

---The thread shown in the panel: root, tid.
function M.current()
  if M.is_open() then
    return state.root, state.tid
  end
end

local function scratch(name, filetype)
  local buf = api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].filetype = filetype
  vim.b[buf].code_review_panel = true -- kept when the review layout is rebuilt
  pcall(api.nvim_buf_set_name, buf, name)
  return buf
end

local keys = require("code-review.keys")

local function input_bar()
  local what = state and state.edit and "edit your last message" or "reply"
  local ik = keys.group("input")
  local send, alt = keys.label(ik.submit) or "-", keys.label(ik.submit_alt) or "-"
  if cr().config.auto_poke then
    return string.format(" %s · %s send + poke the agent · %s send only ", what, send, alt)
  end
  return string.format(" %s · %s send · %s send + poke the agent ", what, send, alt)
end

local function map(buf, modes, lhs, fn, desc)
  keys.set(modes, lhs, fn, { buffer = buf, nowait = true, desc = "Code review panel: " .. desc })
end

local function create()
  local conv = scratch("code-review://conversation", "markdown")
  local input = scratch("code-review://reply", "markdown")
  local cwin = api.nvim_open_win(conv, false, { split = "right", win = -1, width = M.width() })
  local iwin = api.nvim_open_win(input, false, { split = "below", win = cwin, height = 6 })
  for _, w in ipairs({ cwin, iwin }) do
    for opt, val in pairs({ wrap = true, linebreak = true, number = false, relativenumber = false, signcolumn = "no", winfixwidth = true }) do
      vim.wo[w][opt] = val
    end
  end
  vim.wo[cwin].conceallevel = 2
  vim.wo[iwin].winfixheight = true
  state = state or {}
  state.conv, state.input = { buf = conv, win = cwin }, { buf = input, win = iwin }

  local tk, ik = keys.group("thread"), keys.group("input")
  map(conv, "n", tk.close, M.close, "close")
  map(conv, "n", tk.reply, M.focus_input, "write a reply")
  map(conv, "n", tk.edit, M.edit_last, "edit your last message")
  map(conv, "n", tk.resolve, function() cr().toggle_resolved(state.root, state.tid) end, "resolve / reopen")
  map(conv, "n", tk.delete, function() cr().delete(state.root, state.tid) end, "delete the thread")
  map(conv, "n", tk.send, function() cr().poke(state.root) end, "poke the agent")
  map(conv, "n", tk.help, function() cr().help("panel") end, "keys")
  map(input, { "n", "i" }, ik.submit, function() M.send(false) end, "send")
  map(input, "n", ik.submit_normal, function() M.send(false) end, "send")
  map(input, { "n", "i" }, ik.submit_alt, function() M.send(true) end, "send and poke the agent")
  map(input, "n", ik.cancel, M.close, "close")
end

---Show thread `tid` of `root` in the panel (opening it when needed). The focus
---stays where it is.
function M.show(root, tid)
  if not M.is_open() then
    M.close()
    create()
  end
  if state.tid ~= tid then
    state.edit = false
  end
  state.root, state.tid = root, tid
  M.render()
end

---Redraw the panel (e.g. after the agent replied).
function M.render()
  if not M.is_open() then
    return
  end
  local ok, data = pcall(store.read, state.root)
  local t = ok and store.find(data, state.tid)
  local lines = t and cr().thread_markdown(t) or { "_This thread no longer exists._" }
  local buf, win = state.conv.buf, state.conv.win
  vim.bo[buf].modifiable = true
  api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  cr().color_authors(buf, lines)
  vim.wo[win].winbar = t and string.format(" %%#Title#%s%%* · %s:%d ", t.id, t.file, t.range.start) or ""
  vim.wo[state.input.win].winbar = input_bar()
  pcall(api.nvim_win_set_cursor, win, { #lines, 0 }) -- the newest message in view
end

function M.focus_input()
  if M.is_open() then
    api.nvim_set_current_win(state.input.win)
    vim.cmd("startinsert!")
  end
end

---Put your last message in the input box to edit it (until the agent replies).
function M.edit_last()
  local data = store.read(state.root)
  local t = store.find(data, state.tid)
  local last = t and t.messages[#t.messages]
  if not last or last.author ~= "user" then
    return vim.notify("code-review: the agent has already replied; write a reply instead", vim.log.levels.WARN)
  end
  state.edit = true
  api.nvim_buf_set_lines(state.input.buf, 0, -1, false, vim.split(last.body, "\n", { plain = true }))
  vim.wo[state.input.win].winbar = input_bar()
  M.focus_input()
end

---Send what is in the input box: a reply (or the edit), optionally poking the agent.
---@param alt boolean <M-s>: the opposite of <C-s> (which pokes only with config.auto_poke)
function M.send(alt)
  local poke = alt ~= (cr().config.auto_poke == true)
  if not M.is_open() then
    return
  end
  local text = vim.trim(table.concat(api.nvim_buf_get_lines(state.input.buf, 0, -1, false), "\n"))
  if text == "" then
    return
  end
  local root, tid, editing = state.root, state.tid, state.edit
  local refused
  store.update(root, function(d)
    local t = store.find(d, tid)
    if not t then
      refused = "the thread no longer exists"
      return store.UNCHANGED
    end
    if editing then
      local ok, err = store.edit_last_user_message(t, text)
      if not ok then
        refused = err
        return store.UNCHANGED
      end
    else
      store.add_message(t, "user", text)
      if t.status == "resolved" then
        t.status = "open"
      end
    end
  end)
  if refused then
    return vim.notify("code-review: not sent: " .. refused, vim.log.levels.WARN)
  end
  api.nvim_buf_set_lines(state.input.buf, 0, -1, false, {})
  state.edit = false
  cr().after_write(root)
  M.render()
  if poke then
    cr().poke(root)
  end
end

---Give the panel its width again after the review layout was rebuilt.
function M.restore_size()
  if M.is_open() then
    pcall(api.nvim_win_set_width, state.conv.win, M.width())
  end
end

function M.close()
  if state then
    for _, w in ipairs({ state.conv, state.input }) do
      if w and api.nvim_win_is_valid(w.win) and #api.nvim_tabpage_list_wins(0) > 1 then
        pcall(api.nvim_win_close, w.win, true)
      end
    end
  end
  state = nil
end

return M
