-- Review comments other people left on the PR on GitHub, shown read-only beside
-- your own threads:
--
--   <root>/.code-review/github.json   { fetched_at, head_sha, total, threads }
--
-- They are kept apart from comments.json on purpose: they never wait for anyone,
-- the agent cannot answer or resolve them, and every fetch replaces the file.
-- A thread is placed on a line only while that line still holds the code it was
-- written on (the last line of its diff hunk); the rest are listed, not drawn.
local github = require("code-review.github")
local session = require("code-review.session")
local store = require("code-review.store")

local api = vim.api
local M = {}

M.FILE = "github.json"
M.MAX = 100 -- threads fetched, and comments per thread

local ns = api.nvim_create_namespace("code-review-github")
local marks = {} -- buf -> { [extmark id] = thread id }
local cache = {} -- root -> { mtime, data }

local QUERY = [[
query($owner: String!, $repo: String!, $number: Int!) {
  repository(owner: $owner, name: $repo) {
    pullRequest(number: $number) {
      reviewThreads(first: 100) {
        totalCount
        nodes {
          isResolved isOutdated path line startLine originalLine diffSide subjectType
          comments(first: 100) {
            totalCount
            nodes { author { login } body createdAt url diffHunk }
          }
        }
      }
    }
  }
}]]

local function path(root)
  return (store.paths(root)) .. "/" .. M.FILE
end

---The commented line, from the end of a diff hunk (without its +/-/space).
local function hunk_line(hunk)
  local last = (hunk or ""):gsub("\r", ""):gsub("\n+$", ""):match("([^\n]*)$")
  return last and last ~= "" and last:sub(2) or nil
end

---Threads of a GraphQL response, in our shape.
---@return table? { total, threads }
function M.parse(data)
  local pr = data and data.repository and data.repository.pullRequest
  if not pr then
    return nil
  end
  local rt = pr.reviewThreads or {}
  local threads = {}
  for i, n in ipairs(rt.nodes or {}) do
    local comments = (n.comments or {}).nodes or {}
    local first = comments[1] or {}
    local messages = {}
    for _, c in ipairs(comments) do
      messages[#messages + 1] = {
        author = c.author and c.author.login or "ghost",
        body = (c.body or ""):gsub("\r\n", "\n"),
        ts = c.createdAt,
      }
    end
    local file_level = n.subjectType == "FILE"
    threads[#threads + 1] = {
      id = "gh" .. i,
      file = n.path,
      side = n.diffSide == "LEFT" and "old" or "new",
      start = not file_level and (n.startLine or n.line) or nil,
      ["end"] = not file_level and n.line or nil,
      original = n.originalLine,
      -- resolved wins: a settled thread stays out of the way even when its code moved on
      status = n.isResolved and "resolved" or n.isOutdated and "outdated" or "open",
      outdated = n.isOutdated or nil,
      file_level = file_level or nil,
      code = not file_level and hunk_line(first.diffHunk) or nil,
      url = first.url,
      messages = messages,
      more = math.max(0, ((n.comments or {}).totalCount or #comments) - #comments),
    }
  end
  return { total = rt.totalCount or #threads, threads = threads }
end

---Save fetched threads. Returns the data, and whether they differ from the saved
---ones (unchanged: nothing is written, nothing needs a redraw).
local function save(root, s, parsed)
  local old = M.load(root)
  if old and old.head_sha == s.head_sha and old.total == parsed.total
    and vim.deep_equal(old.threads, parsed.threads) then
    return old, false
  end
  local data = {
    fetched_at = os.date("!%Y-%m-%dT%H:%M:%SZ"),
    head_sha = s.head_sha,
    total = parsed.total,
    threads = parsed.threads,
  }
  store.ensure_dir(root)
  local tmp = path(root) .. ".tmp." .. vim.uv.os_getpid()
  local f = assert(io.open(tmp, "w"))
  f:write(vim.json.encode(data), "\n")
  f:close()
  assert(vim.uv.fs_rename(tmp, path(root)))
  cache[root] = nil
  return data, true
end

local function pr_session(root)
  local s = session.load(root)
  if s and s.kind == "pr" then
    return s
  end
end

local function vars(s)
  return { owner = s.owner, repo = s.repo, number = s.number }
end

---Fetch the PR's review threads and save them (blocking: the CLI).
---@return table? data
---@return string? err
function M.fetch(root)
  local s = pr_session(root)
  if not s then
    return nil, "not a PR review"
  end
  local data, err = github.graphql(s.host or "github.com", QUERY, vars(s))
  local parsed = M.parse(data)
  if not parsed then
    return nil, err or "the PR was not found"
  end
  return (save(root, s, parsed))
end

---Fetch without blocking; cb(data?, err?, changed?) on the main loop.
function M.fetch_async(root, cb)
  local s = pr_session(root)
  if not s then
    return cb(nil, "not a PR review")
  end
  github.graphql_async(s.host or "github.com", QUERY, vars(s), function(data, err)
    local parsed = M.parse(data)
    if not parsed then
      return cb(nil, err or "the PR was not found")
    end
    local ok, saved, changed = pcall(save, root, s, parsed)
    cb(ok and saved or nil, not ok and tostring(saved) or nil, ok and changed or nil)
  end)
end

---The saved threads of a review, or nil when none were fetched.
function M.load(root)
  local st = vim.uv.fs_stat(path(root))
  if not st then
    cache[root] = nil
    return nil
  end
  local c = cache[root]
  if c and c.mtime == st.mtime.nsec + st.mtime.sec * 1e9 then
    return c.data
  end
  local f = io.open(path(root), "r")
  if not f then
    return nil
  end
  local ok, data = pcall(vim.json.decode, f:read("a"), { luanil = { object = true, array = true } })
  f:close()
  if not ok or type(data) ~= "table" then
    return nil
  end
  data.threads = data.threads or {}
  cache[root] = { mtime = st.mtime.nsec + st.mtime.sec * 1e9, data = data }
  return data
end

function M.find(root, id)
  for _, t in ipairs((M.load(root) or {}).threads or {}) do
    if t.id == id then
      return t
    end
  end
end

---Is thread `t` still on its line in the snapshot `lines`?
function M.placed(t, lines)
  if t.outdated or t.status == "outdated" or t.file_level or not t["end"] then
    return false
  end
  local l = lines and lines[t["end"]]
  if not l then
    return false
  end
  return t.code == nil or vim.trim(l) == vim.trim(t.code)
end

---Status as shown here: an open thread whose line no longer holds its code
---(e.g. the base branch moved) is outdated for us too.
function M.state(root, t)
  if t.status == "open" and not t.file_level and not M.placed(t, session.lines(root, t.file, { side = t.side })) then
    return "outdated"
  end
  return t.status
end

---Counts by status: { open, resolved, outdated }.
function M.counts(root, data)
  local c = { open = 0, resolved = 0, outdated = 0 }
  for _, t in ipairs((data or {}).threads or {}) do
    local st = M.state(root, t)
    c[st] = (c[st] or 0) + 1
  end
  return c
end

---Open threads drawn per file (what you find in the diff): { [path] = n }, and the total.
function M.file_counts(root)
  local res, total = {}, 0
  if not pr_session(root) then
    return res, 0
  end
  local text = {}
  for _, t in ipairs((M.load(root) or {}).threads or {}) do
    if t.status == "open" then
      local key = t.side .. ":" .. t.file
      text[key] = text[key] or session.lines(root, t.file, { side = t.side }) or {}
      if M.placed(t, text[key]) then
        res[t.file] = (res[t.file] or 0) + 1
        total = total + 1
      end
    end
  end
  return res, total
end

---Remove the GitHub threads drawn in `buf`.
function M.clear(buf)
  if api.nvim_buf_is_valid(buf) then
    api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  end
  marks[buf] = nil
end

local function first_line(s)
  return (s:match("^[^\n]*"))
end

---Draw the GitHub threads of `file` in `buf` (called from code-review.render).
---@param side "old"|"new"|"both"
function M.render(buf, root, file, side, opts)
  if not api.nvim_buf_is_valid(buf) then
    return
  end
  api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  marks[buf] = {}
  local data = pr_session(root) and M.load(root)
  if not data then
    return
  end
  local u = require("code-review.unified")
  local n = api.nvim_buf_line_count(buf)
  local text = {}
  local function lines_of(sd)
    text[sd] = text[sd] or session.lines(root, file, { side = sd }) or {}
    return text[sd]
  end
  for _, t in ipairs(data.threads) do
    local wanted = t.file == file and (side == "both" or t.side == side)
      and (t.status ~= "resolved" or opts.show_resolved)
      and not (side == "both" and t.side == "old" and opts.since)
    if wanted and M.placed(t, lines_of(t.side)) then
      local s, e = t.start, t["end"]
      if side == "both" then
        s, e = u.row_of(buf, t.side, s), u.row_of(buf, t.side, e)
        s = s or e
      end
      if s and e and e <= n then
        local last = t.messages[#t.messages] or { author = "?", body = "" }
        local hl = t.status == "resolved" and "CodeReviewDim" or "CodeReviewGitHub"
        local label = t.status == "resolved"
            and string.format("  %s resolved on GitHub · @%s", opts.sign, (t.messages[1] or last).author)
          or string.format("  %s @%s: %s", opts.sign, last.author, first_line(last.body))
        if #t.messages > 1 then
          label = label .. string.format("  (%d)", #t.messages)
        end
        local id = api.nvim_buf_set_extmark(buf, ns, math.max(0, s - 1), 0, {
          end_row = e - 1,
          sign_text = opts.sign,
          sign_hl_group = hl,
          virt_text = { { label, t.status == "resolved" and "CodeReviewDim" or "CodeReviewVirt" } },
          virt_text_pos = "eol",
          priority = 10, -- below your own threads: they win the one sign column
        })
        marks[buf][id] = t.id
      end
    end
  end
end

---GitHub thread ids on `row` (0-based) of `buf`.
function M.at(buf, row)
  local res = {}
  for _, m in ipairs(api.nvim_buf_get_extmarks(buf, ns, { row, 0 }, { row, -1 }, { overlap = true })) do
    local id = marks[buf] and marks[buf][m[1]]
    if id then
      res[#res + 1] = id
    end
  end
  return res
end

-- The read-only thread window ---------------------------------------------------

local float

local function where(t)
  if t.file_level then
    return string.format("`%s`", t.file)
  elseif t.outdated or t.status == "outdated" or not t["end"] then
    return string.format("`%s` (outdated: was line %s)", t.file, tostring(t.original or "?"))
  end
  local loc = t.start and t.start ~= t["end"] and (t.start .. "-" .. t["end"]) or tostring(t["end"])
  return string.format("`%s:%s`%s", t.file, loc, t.side == "old" and " (old side)" or "")
end

---A GitHub thread as markdown.
function M.markdown(root, t)
  local cr = require("code-review")
  local lines = { string.format("%s · on GitHub · %s", where(t), M.state(root, t)), "" }
  if not t.outdated and t.status ~= "outdated" and t["end"] then
    local src = session.lines(root, t.file, { side = t.side }) or {}
    local code = vim.list_slice(src, t.start or t["end"], t["end"])
    if #code > 0 then
      lines[#lines + 1] = "```" .. (vim.filetype.match({ filename = t.file }) or "")
      vim.list_extend(lines, code)
      lines[#lines + 1] = "```"
    end
  end
  for i, m in ipairs(t.messages) do
    if i > 1 then
      vim.list_extend(lines, { "", "---" })
    end
    vim.list_extend(lines, { "", string.format("**@%s** · %s", m.author, cr.reltime(m.ts)), "" })
    vim.list_extend(lines, vim.split(m.body, "\n", { plain = true }))
  end
  if (t.more or 0) > 0 then
    vim.list_extend(lines, { "", string.format("_%d more on GitHub_", t.more) })
  end
  return lines
end

---Show a GitHub thread in a read-only float: `o` opens it in the browser.
function M.open(root, id)
  local t = M.find(root, id)
  if not t then
    return
  end
  if float and api.nvim_win_is_valid(float) then
    api.nvim_win_close(float, true)
  end
  local lines = M.markdown(root, t)
  local buf = api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].filetype = "markdown"
  api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  local width = math.min(100, vim.o.columns - 4)
  local win = api.nvim_open_win(buf, true, {
    relative = "cursor",
    row = 1,
    col = 0,
    width = width,
    height = math.max(1, math.min(#lines, math.floor(vim.o.lines / 2))),
    border = "rounded",
    title = " GitHub ",
    footer = t.url and " o open on GitHub · q close " or " q close ",
    footer_pos = "right",
    style = "minimal",
  })
  float = win
  vim.wo[win].wrap = true
  vim.wo[win].linebreak = true
  vim.wo[win].conceallevel = 2
  vim.wo[win].concealcursor = "n"
  local o = { buffer = buf, nowait = true }
  for _, k in ipairs({ "q", "<Esc>" }) do
    vim.keymap.set("n", k, function() api.nvim_win_close(win, true) end, o)
  end
  if t.url then
    vim.keymap.set("n", "o", function() vim.ui.open(t.url) end, o)
  end
  return win
end

-- Text for the agent ------------------------------------------------------------

local function indent(s, pad)
  return (pad .. s:gsub("\n", "\n" .. pad)):gsub(" +\n", "\n"):gsub(" +$", "")
end

---The threads as text for the CLI (resolved ones only with `all`).
function M.text(root, data, all)
  local out = {}
  for _, t in ipairs(data.threads) do
    if all or t.status ~= "resolved" then
      local placed = M.placed(t, session.lines(root, t.file, { side = t.side }))
      local loc
      if t.file_level then
        loc = t.file .. " (the whole file)"
      elseif placed then
        loc = string.format("%s:%s", t.file, t.start and t.start ~= t["end"] and (t.start .. "-" .. t["end"]) or t["end"])
          .. (t.side == "old" and " (OLD side: the base snapshot)" or "")
      else
        loc = string.format("%s (outdated: was line %s; the code changed since)", t.file, tostring(t.original or "?"))
      end
      out[#out + 1] = string.format("%s · %s%s", loc, M.state(root, t), t.url and (" · " .. t.url) or "")
      if t.code and not placed then
        out[#out + 1] = "  on: " .. vim.trim(t.code)
      end
      for _, m in ipairs(t.messages) do
        out[#out + 1] = string.format("  @%s (%s):", m.author, m.ts or "?")
        out[#out + 1] = indent(vim.trim(m.body), "    ")
      end
      if (t.more or 0) > 0 then
        out[#out + 1] = string.format("  (%d more on GitHub)", t.more)
      end
      out[#out + 1] = ""
    end
  end
  return out
end

return M
