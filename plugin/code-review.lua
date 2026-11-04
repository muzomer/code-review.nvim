if vim.g.loaded_code_review then
  return
end
vim.g.loaded_code_review = 1

vim.api.nvim_create_user_command("CodeReview", function(o)
  require("code-review").command(o)
end, {
  nargs = "*",
  range = true,
  desc = "code-review: add | open | resolve | delete | list [all] | copy | refresh | pr <url> | files | nextfile | prevfile",
  complete = function(arglead)
    return require("code-review").complete(arglead)
  end,
})

-- `nvim https://github.com/<owner>/<repo>/pull/<n>` starts a PR review.
--
-- Neovim's built-in remote-file handler (runtime/plugin/net.lua) would fetch
-- that URL as an HTML page too. For a private repo it fails with a 404 error
-- message, and the hit-enter prompt that follows interrupts our fetch. When
-- the arguments hold a PR URL, keep that handler from loading in this session.
for _, arg in ipairs(vim.fn.argv()) do
  if type(arg) == "string" and arg:match("^https?://") and require("code-review.github").parse_ref(arg) then
    vim.g.loaded_nvim_net_plugin = true
    break
  end
end

vim.api.nvim_create_autocmd("VimEnter", {
  once = true,
  callback = function()
    local github = require("code-review.github")
    for _, arg in ipairs(vim.fn.argv()) do
      if type(arg) == "string" and arg:match("^https?://") and github.parse_ref(arg) then
        vim.schedule(function()
          vim.cmd("silent! %bdelete!") -- unload the URL buffer netrw made (its id must stay valid for netrw)
          require("code-review.diff").open(arg)
        end)
        return
      end
    end
  end,
})
