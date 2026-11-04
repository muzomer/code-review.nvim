-- Key bindings from the config. A binding is a key ("r"), several keys
-- ({ "r", "i" }), or false / nil for none.
local M = {}

---The keys of a binding, as a list.
---@param v string|string[]|false|nil
---@return string[]
function M.list(v)
  if type(v) == "string" then
    return v ~= "" and { v } or {}
  end
  return type(v) == "table" and v or {}
end

---How a binding is shown in help and footers: "r", "r / i", or nil for none.
function M.label(v)
  local l = M.list(v)
  return #l > 0 and table.concat(l, " / ") or nil
end

---Map every key of a binding.
function M.set(modes, v, fn, opts)
  for _, lhs in ipairs(M.list(v)) do
    vim.keymap.set(modes, lhs, fn, opts)
  end
end

---Merge the user's `keymaps` into the defaults. A binding the user sets replaces
---the default as a whole (a deep merge would mix two key lists entry by entry);
---groups (thread, input, sidebar) are merged binding by binding.
function M.merge(defaults, user)
  if user == false then
    return false -- no keys at all
  end
  local out = vim.deepcopy(defaults)
  for k, v in pairs(user or {}) do
    local d = out[k]
    if type(v) == "table" and not vim.islist(v) and type(d) == "table" and not vim.islist(d) then
      for k2, v2 in pairs(v) do
        d[k2] = v2
      end
    else
      out[k] = v
    end
  end
  return out
end

---The bindings of a group of the config (thread, input, sidebar).
function M.group(name)
  return (require("code-review").config.keymaps or {})[name] or {}
end

return M
