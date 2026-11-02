-- Entry point for `nvim --clean -l bin/code-review.lua ...`
local here = vim.fs.dirname(vim.fs.normalize(vim.fn.fnamemodify(arg[0], ":p")))
local lua = vim.fs.dirname(here) .. "/lua"
package.path = lua .. "/?.lua;" .. lua .. "/?/init.lua;" .. package.path

local argv = {}
for i = 1, #arg do
  argv[i] = arg[i]
end
os.exit(require("code-review.cli").run(argv))
