-- Neovim config of the demo recording (nvim --clean -u demo/init.lua).
local repo = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
vim.opt.rtp:prepend(repo)
vim.g.mapleader = " "
vim.o.termguicolors = true
vim.o.number = true
vim.o.signcolumn = "yes"
vim.o.swapfile = false
vim.o.shada = ""
vim.o.laststatus = 3
vim.o.statusline = " %t%=%l:%c "
vim.o.cmdheight = 1
vim.o.showmode = false
vim.o.ruler = false
vim.o.shortmess = vim.o.shortmess .. "IF"

require("code-review").setup({
  agent = "headless",
  headless = { cmd = repo .. "/demo/bin/claude" },
})

-- A caption across the top, set with :Caption <text> (typed while the recording is hidden).
vim.api.nvim_set_hl(0, "DemoCaption", { fg = "#1e1e2e", bg = "#89b4fa", bold = true })
vim.api.nvim_set_hl(0, "DemoCaptionFill", { bg = "#313244" })
vim.o.showtabline = 2
local caption = "code-review.nvim · ask your AI agent about code, right where it is"
_G.demo_tabline = function()
  return "%#DemoCaption#  " .. caption:gsub("%%", "%%%%") .. "  %#DemoCaptionFill#"
end
vim.o.tabline = "%!v:lua.demo_tabline()"
vim.api.nvim_create_user_command("Caption", function(o)
  caption = o.args
  vim.cmd("redrawtabline")
  vim.cmd("echo ''")
end, { nargs = "+" })

-- VHS can only send Alt with an uppercase letter: let Alt-Shift-s act as Alt-s.
vim.keymap.set({ "n", "i" }, "<M-S>", "<M-s>", { remap = true })
