-- nvim-treesitter, `main` branch.
--
-- WHY `main` AND NOT THE HISTORIC DEFAULT `master`
--   The two branches are not compatible with each other. The version of nvim
--   forces the choice, not taste:
--     `main`   needs nvim >= 0.12.
--     `master` is "locked, backward compatible with Nvim 0.11". On 0.12 it
--              really breaks. Six predicates in query_predicates.lua read
--              `match[id]` as a single node, but since 0.12 it is a LIST.
--              The most visible is `set-lang-from-info-string!`. It resolves the
--              language inside the ```yaml blocks of a markdown. It makes
--              any markdown buffer with code blow up, the avante sidebar included.
--
--   You still need the explicit pin. The default branch of the repo changed
--   over time. Without `branch =` you end up where the plugin decides.
--
-- WHY THERE IS NO CONDITIONAL ANY MORE
--   There was one. It chose the branch based on `has("nvim-0.12")`. We removed it
--   when both nodes that mount this config moved to nvim 0.12.5.
--   The scope does not mount it at all: its sparse-checkout takes only
--   dotfiles/starship. It kept alive a branch of code that no node
--   ran and that nobody could test -- coverage in appearance only. In its place
--   there is the guard below. It at least fails and says what to do.
--
-- REQUIREMENTS on a new node
--   - nvim >= 0.12          (apt on Debian 13 gives 0.10.4. Use
--                            dotfiles/upgrade-nvim-the-grid.sh. install-the-grid.sh
--                            now calls it by itself.)
--   - tree-sitter-cli >= 0.26.1 in the PATH.
--   - a C compiler          (build-essential on Debian. On Windows the VS Build
--                            Tools, which Enter-BuildEnv loads.)

if vim.fn.has("nvim-0.12") == 0 then
  -- Noisy on purpose. The alternative is that the plugin loads and then
  -- blows up on a random file with an error that does not name the real cause.
  vim.notify(
    "nvim-treesitter (ramo main) richiede nvim >= 0.12, qui c'e' la "
      .. tostring(vim.version())
      .. ".\nPlugin non caricato. Aggiorna con dotfiles/upgrade-nvim-the-grid.sh",
    vim.log.levels.WARN,
    { title = "treesitter" }
  )
  return {}
end

-- List adapted to the real use of the homelab. The original typecraft one was for web
-- dev (ruby, scss, html, css, javascript, typescript). Above all it had NO
-- `yaml`. This is the format of the 19 docker-compose files that are the reason
-- for the repo to exist.
local LINGUE = {
  "bash",            -- install and maintenance scripts
  "yaml",            -- docker-compose: the format edited most here
  "json",
  "toml",            -- starship.toml
  "lua",             -- this config
  "markdown",        -- the documentation of the repo
  "markdown_inline", -- code blocks inside markdown
  "dockerfile",
  "python",
  "go",
  "rust",
}

return {
  {
    "nvim-treesitter/nvim-treesitter",
    branch = "main",
    lazy = false, -- the main branch says that it does not support lazy-loading
    build = ":TSUpdate",
    config = function()
      local ts = require("nvim-treesitter")

      ts.setup({
        -- Prepends this folder to the runtimepath. Without it, the plugin installs
        -- the parsers but nvim does not find them.
        install_dir = vim.fn.stdpath("data") .. "/site",
      })

      -- Async on purpose. If the start blocks to compile parsers, that is
      -- worse than the problem it solves. And it is cheap in steady state.
      -- install() compares with the parsers already present and skips the ones
      -- that exist. From the second time on it does no work.
      ts.install(LINGUE)

      -- On `main` highlighting does not turn on from setup() any more: it must be started
      -- for each buffer. No `pattern`, so it also works for the parsers installed
      -- by hand later, with no need to keep two lists aligned.
      vim.api.nvim_create_autocmd("FileType", {
        group = vim.api.nvim_create_augroup("treesitter_start", { clear = true }),
        callback = function(args)
          -- pcall because start() raises when no parser exists for that
          -- filetype. This is very normal outside the list above. It does not
          -- deserve an error on the screen.
          pcall(vim.treesitter.start, args.buf)
        end,
      })
    end,
  },
}
