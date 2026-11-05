-- Re-anchoring threads to code that may have moved or changed.
-- Order: stored position -> exact text search (context breaks ties) ->
-- fuzzy line similarity -> give up (thread becomes "outdated").
--
-- A thread is on whole lines (range = { start, end }), or on the text selected
-- in them: range.start_col / range.end_col are 1-based bytes, the end inclusive,
-- on the first and the last line; anchor.span holds that text ("\n" between
-- lines). When the text cannot be found again, the thread keeps its lines.
local M = {}

M.CONTEXT = 2
M.THRESHOLD = 0.8

---The columns of a thread on selected text, or nil for a thread on whole lines.
---@return integer? start_col, integer? end_col
function M.cols(t)
  local r = t and t.range or {}
  if type(r.start_col) == "number" and type(r.end_col) == "number" and r.start_col >= 1 and r.end_col >= 1 then
    return r.start_col, r.end_col
  end
end

---The text from (s, sc) to (e, ec): 1-based, both ends inclusive.
function M.span_text(lines, s, e, sc, ec)
  if s == e then
    return (lines[s] or ""):sub(sc, ec)
  end
  local out = { (lines[s] or ""):sub(sc) }
  for i = s + 1, e - 1 do
    out[#out + 1] = lines[i] or ""
  end
  out[#out + 1] = (lines[e] or ""):sub(1, ec)
  return table.concat(out, "\n")
end

---Snapshot lines [s, e] (1-based, inclusive) plus surrounding context, and the
---selected text when `sc`/`ec` are given.
function M.capture(lines, s, e, sc, ec)
  local a = { text = {}, context_before = {}, context_after = {} }
  for i = s, e do
    a.text[#a.text + 1] = lines[i] or ""
  end
  for i = math.max(1, s - M.CONTEXT), s - 1 do
    a.context_before[#a.context_before + 1] = lines[i]
  end
  for i = e + 1, math.min(#lines, e + M.CONTEXT) do
    a.context_after[#a.context_after + 1] = lines[i]
  end
  if sc and ec then
    a.span = M.span_text(lines, s, e, sc, ec)
  end
  return a
end

---Where `span` is in lines [s, e]: it must start on line s and end on line e.
---The occurrence nearest to column `near` of line s wins.
---@return integer? start_col, integer? end_col
function M.locate_span(lines, s, e, span, near)
  if type(span) ~= "string" or span == "" then
    return nil
  end
  local block = table.concat(vim.list_slice(lines, s, e), "\n")
  local first_len, last_start = #(lines[s] or ""), #block - #(lines[e] or "") + 1
  local best, best_d
  local from = 1
  while true do
    local p, q = block:find(span, from, true)
    if not p then
      break
    end
    if p <= math.max(first_len, 1) and q >= last_start then
      local d = math.abs(p - (near or 1))
      if not best or d < best_d then
        best, best_d = p, d
      end
    end
    from = p + 1
  end
  if not best then
    return nil
  end
  return best, best + #span - 1 - (last_start - 1)
end

---Put thread `t` on lines [s, e] of `lines`, on its selected text when that is
---still there (else on the whole lines).
function M.place(t, lines, s, e)
  local sc = M.cols(t)
  local ec
  if sc then
    sc, ec = M.locate_span(lines, s, e, (t.anchor or {}).span, sc)
  end
  t.range = { start = s, ["end"] = e, start_col = sc, end_col = ec }
  t.anchor = M.capture(lines, s, e, sc, ec)
end

local function block_eq(lines, s, text)
  for i, l in ipairs(text) do
    if lines[s + i - 1] ~= l then
      return false
    end
  end
  return true
end

local function context_score(lines, s, e, a)
  local score = 0
  local cb = a.context_before or {}
  for i = 1, #cb do
    if lines[s - #cb + i - 1] == cb[i] then
      score = score + 1
    end
  end
  for i, l in ipairs(a.context_after or {}) do
    if lines[e + i] == l then
      score = score + 1
    end
  end
  return score
end

local function norm(s)
  return vim.trim(s or ""):gsub("%s+", " ")
end

local function bigrams(s)
  local t, n = {}, 0
  for i = 1, #s - 1 do
    local b = s:sub(i, i + 1)
    t[b] = (t[b] or 0) + 1
    n = n + 1
  end
  return { t = t, n = n, s = s }
end

-- Dice coefficient over character bigrams of whitespace-normalised lines.
local function similarity(a, b)
  if a.s == b.s then
    return 1
  end
  if a.n == 0 or b.n == 0 then
    return 0
  end
  local inter = 0
  for k, c in pairs(a.t) do
    local d = b.t[k]
    if d then
      inter = inter + math.min(c, d)
    end
  end
  return 2 * inter / (a.n + b.n)
end

M.similarity = function(x, y)
  return similarity(bigrams(norm(x)), bigrams(norm(y)))
end

---Locate an anchor in `lines`.
---@return integer? start, integer? end, string? how "exact"|"moved"|"fuzzy"
function M.locate(lines, a, range)
  local text = a.text or {}
  local k = #text
  if k == 0 or #lines < k then
    return nil
  end
  local s0 = range.start
  if block_eq(lines, s0, text) then
    return s0, s0 + k - 1, "exact"
  end

  local best, best_score, best_dist
  for s = 1, #lines - k + 1 do
    if lines[s] == text[1] and block_eq(lines, s, text) then
      local sc, d = context_score(lines, s, s + k - 1, a), math.abs(s - s0)
      if not best or sc > best_score or (sc == best_score and d < best_dist) then
        best, best_score, best_dist = s, sc, d
      end
    end
  end
  if best then
    return best, best + k - 1, "moved"
  end

  local want, cache = {}, {}
  for i, l in ipairs(text) do
    want[i] = bigrams(norm(l))
  end
  local function line(i)
    local c = cache[i]
    if not c then
      c = bigrams(norm(lines[i]))
      cache[i] = c
    end
    return c
  end
  local best_v = 0
  for s = 1, #lines - k + 1 do
    local total = 0
    for i = 1, k do
      total = total + similarity(line(s + i - 1), want[i])
    end
    local v = total / k
    local d = math.abs(s - s0)
    if v > best_v or (v == best_v and best and d < best_dist) then
      best, best_v, best_dist = s, v, d
    end
  end
  if best and best_v >= M.THRESHOLD then
    return best, best + k - 1, "fuzzy"
  end
  return nil
end

---Re-anchor `threads` (all for one file) against `lines` (nil = file gone).
---Mutates threads; returns true when anything changed.
function M.reanchor_threads(threads, lines)
  local changed = false
  for _, t in ipairs(threads) do
    local s, e, how
    if lines then
      s, e, how = M.locate(lines, t.anchor or {}, t.range)
    end
    if s then
      if how ~= "exact" then
        M.place(t, lines, s, e)
        changed = true
      end
      if t.status == "outdated" then
        t.status = "open"
        changed = true
      end
    elseif t.status == "open" then
      t.status = "outdated"
      changed = true
    end
  end
  return changed
end

---Re-anchor every thread in the project against the text it was written on:
---files on disk, or the base/head snapshots for threads of a diff or PR.
function M.reanchor_root(root)
  local store = require("code-review.store")
  local session = require("code-review.session")
  if not store.exists(root) then
    return
  end
  store.update(root, function(data)
    -- Threads sharing a file, side and base see the same text.
    local groups = {}
    for _, t in ipairs(data.threads) do
      local key = table.concat({ t.file, t.side or "new", t.base or "" }, "\0")
      groups[key] = groups[key] or { threads = {}, t = t }
      table.insert(groups[key].threads, t)
    end
    local changed = false
    for _, g in pairs(groups) do
      local lines = session.lines(root, g.t.file, { side = g.t.side, base = g.t.base })
      changed = M.reanchor_threads(g.threads, lines) or changed
    end
    if not changed then
      return store.UNCHANGED
    end
  end)
end

return M
