vim.cmd("set expandtab")
vim.cmd("set tabstop=2")
vim.cmd("set softtabstop=2")
vim.cmd("set shiftwidth=2")
vim.g.mapleader = " "

vim.opt.swapfile = false

-- Navigate vim panes better
vim.keymap.set('n', '<c-k>', ':wincmd k<CR>')
vim.keymap.set('n', '<c-j>', ':wincmd j<CR>')
vim.keymap.set('n', '<c-h>', ':wincmd h<CR>')
vim.keymap.set('n', '<c-l>', ':wincmd l<CR>')

vim.keymap.set('n', '<leader>h', ':nohlsearch<CR>')
vim.wo.number = true

-- Clipboard on Windows -- fallback, not default.
--
-- nvim installed with winget brings win32yank.exe with it
-- in C:\Program Files\Neovim\bin (checked on ARCADE, nvim 0.12.5). That
-- folder is in the PATH, so in this case this block NEVER activates.
--
-- It serves the installations that do not have win32yank (build from source,
-- tarball, Scoop). Without it, "+y fails with no message. You spend half an hour
-- to understand that the problem is the clipboard provider and not your keymap.
--
-- The field `name` is not decoration. :checkhealth prints it, so
-- the clipboard path in use stays visible instead of something to guess.
--
-- On the-grid has("win32") returns 0, so the block does nothing. Both OS use the same file, with one
-- behavior for each OS.
if vim.fn.has("win32") == 1 and vim.fn.executable("win32yank.exe") == 0 then
  vim.g.clipboard = {
    name = "win32-powershell-fallback",
    copy = { ["+"] = "clip.exe", ["*"] = "clip.exe" },
    paste = {
      ["+"] = 'powershell.exe -NoLogo -NoProfile -c [Console]::Out.Write($(Get-Clipboard -Raw))',
      ["*"] = 'powershell.exe -NoLogo -NoProfile -c [Console]::Out.Write($(Get-Clipboard -Raw))',
    },
    cache_enabled = 0,
  }
end
