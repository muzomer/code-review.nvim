if vim.g.loaded_code_review then
  return
end
vim.g.loaded_code_review = 1

vim.api.nvim_create_user_command("CodeReview", function(o)
  require("code-review").command(o)
end, {
  nargs = "*",
  range = true,
  desc = "code-review: add | open | resolve | delete | list [all] | copy | refresh",
  complete = function(arglead)
    return require("code-review").complete(arglead)
  end,
})
