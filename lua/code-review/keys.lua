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
    -- a group (an empty table counts as one: vim.islist({}) is true)
    if type(v) == "table" and (next(v) == nil or not vim.islist(v)) and type(d) == "table" and not vim.islist(d) then
      for k2, v2 in pairs(v) do
        d[k2] = v2
      end
    else
      out[k] = v
    end
  end
  return out
end

local function is_binding(v)
  if v == false or v == nil or type(v) == "string" then
    return true
  end
  return type(v) == "table" and vim.islist(v) and vim.iter(v):all(function(k) return type(k) == "string" end)
end

---Drop the bindings of the user's `keymaps` that are not a key, a list of keys
---or false (a group, like `input`, must be a table of bindings).
---@return table|false|nil keymaps
---@return string[] problems
function M.validate(user, defaults)
  local problems = {}
  if user == nil or user == false then
    return user, problems
  end
  if type(user) ~= "table" then
    return nil, { "keymaps must be a table or false; using the defaults" }
  end
  local out = {}
  for k, v in pairs(user) do
    local d = defaults[k]
    if type(d) == "table" and not vim.islist(d) then -- a group
      if type(v) ~= "table" or vim.islist(v) then
        problems[#problems + 1] = string.format("keymaps.%s must be a table of bindings; using the defaults", k)
      else
        out[k] = {}
        for k2, v2 in pairs(v) do
          if is_binding(v2) then
            out[k][k2] = v2
          else
            problems[#problems + 1] = string.format("keymaps.%s.%s must be a key, a list of keys or false; using the default", k, k2)
          end
        end
      end
    elseif is_binding(v) then
      out[k] = v
    else
      problems[#problems + 1] = string.format("keymaps.%s must be a key, a list of keys or false; using the default", k)
    end
  end
  return out, problems
end

---The bindings of a group of the config (thread, input, sidebar).
function M.group(name)
  return (require("code-review").config.keymaps or {})[name] or {}
end

return M
