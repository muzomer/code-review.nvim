-- Minimal test runner: nvim --clean -l tests/run.lua [spec ...]
local root = vim.fs.dirname(vim.fs.dirname(vim.fs.normalize(vim.fn.fnamemodify(arg[0], ":p"))))
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path
vim.opt.runtimepath:prepend(root)
_G.PLUGIN_ROOT = root

-- PR sessions of tests live in a throwaway directory, never in the real cache.
local sandbox = vim.fn.tempname()
vim.env.NVIM_CODE_REVIEW_STATE = sandbox .. "/state"
vim.env.NVIM_CODE_REVIEW_CACHE = sandbox .. "/cache"

local passed, failed, prefix = 0, 0, ""

function _G.describe(name, fn)
  local old = prefix
  prefix = prefix .. name .. " > "
  fn()
  prefix = old
end

function _G.it(name, fn)
  local ok, err = xpcall(fn, debug.traceback)
  if ok then
    passed = passed + 1
    io.stdout:write("  ok    ", prefix, name, "\n")
  else
    failed = failed + 1
    io.stdout:write("  FAIL  ", prefix, name, "\n", err, "\n")
  end
end

function _G.eq(got, want)
  if not vim.deep_equal(got, want) then
    error("expected " .. vim.inspect(want) .. "\n     got " .. vim.inspect(got), 2)
  end
end

function _G.tmp_project(files)
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir .. "/.git", "p")
  for path, lines in pairs(files or {}) do
    vim.fn.mkdir(vim.fs.dirname(dir .. "/" .. path), "p")
    vim.fn.writefile(lines, dir .. "/" .. path)
  end
  return vim.fs.normalize(vim.uv.fs_realpath(dir))
end

local specs = {}
for i = 1, #arg do
  specs[#specs + 1] = arg[i]
end
if #specs == 0 then
  specs = vim.fn.glob(root .. "/tests/*_spec.lua", false, true)
end
for _, f in ipairs(specs) do
  io.stdout:write(vim.fn.fnamemodify(f, ":t"), "\n")
  dofile(f)
end
io.stdout:write(string.format("\n%d passed, %d failed\n", passed, failed))
os.exit(failed > 0 and 1 or 0)
