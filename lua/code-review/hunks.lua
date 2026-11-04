-- Line-level diff of two texts and the mapping of lines between them.
-- Shared by: inline-thread mirroring, character highlights, the unified view.
local M = {}

local text_diff = (vim.text and vim.text.diff) or vim.diff

---Hunks between two line lists: { {start_a, count_a, start_b, count_b}, ... }
---(1-based; a count of 0 means the start is the line *before* the hunk).
---@param a string[]
---@param b string[]
---@return integer[][]
function M.indices(a, b)
  -- an empty side is "" (no lines), not "\n" (one empty line)
  local function text(lines)
    return #lines == 0 and "" or (table.concat(lines, "\n") .. "\n")
  end
  return text_diff(text(a), text(b), { result_type = "indices" })
end

---Map a 1-based line of one side to the matching line of the other side.
---Lines inside a changed hunk map to the same offset in the other side's hunk;
---a deleted line maps to the line where it was.
---@param hunks integer[][] from M.indices
---@param from_a boolean the line is on side a
function M.map_line(hunks, line, from_a)
  local offset = 0
  for _, h in ipairs(hunks) do
    local sa, ca, sb, cb = h[1], h[2], h[3], h[4]
    if not from_a then
      sa, ca, sb, cb = sb, cb, sa, ca
    end
    local first_a = ca == 0 and sa + 1 or sa
    if line < first_a then
      return line + offset
    end
    if ca > 0 and line <= sa + ca - 1 then
      return cb == 0 and math.max(1, sb) or sb + math.min(line - sa, cb - 1)
    end
    local end_a = ca == 0 and sa or sa + ca - 1
    local end_b = cb == 0 and sb or sb + cb - 1
    offset = end_b - end_a
  end
  return line + offset
end

return M
