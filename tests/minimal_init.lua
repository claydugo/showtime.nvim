-- Minimal init for headless test runs.
-- Adds plenary.nvim (cloned into .deps/) and the plugin itself to runtimepath.

local cwd = vim.fn.getcwd()
vim.opt.runtimepath:prepend(cwd .. "/.deps/plenary.nvim")
vim.opt.runtimepath:prepend(cwd)
vim.opt.swapfile = false
vim.cmd("runtime plugin/plenary.vim")
