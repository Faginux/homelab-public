return {
  "yetone/avante.nvim",
  event = "VeryLazy",
  lazy = false,
  version = false, -- Set this to "*" to always pull the latest release version, or set it to false to update to the latest code changes.
  opts = {
    provider = "claude",
    providers = {
      claude = {
        -- The default of the plugin is claude-sonnet-4-5-20250929, now old.
        model = "claude-opus-5",

        -- The default is 200000, set for the earlier models: Opus 5 has a
        -- window of 1M tokens.
        context_window = 1000000,

        extra_request_body = {
          max_tokens = 64000,

          -- `temperature` is NOT here on purpose. Anthropic removed the sampling
          -- parameters (temperature, top_p, top_k) from the Claude 4.6 models on.
          -- If you send them, the API answers 400.
          --
          -- The default of avante has `temperature = 0.75`. Avante merges the user
          -- options with `vim.tbl_deep_extend("force", ...)`.
          -- So omitting it here is NOT enough to remove it from the table. What saves us is
          -- the provider itself. claude.lua contains is_temperature_unsupported(), which
          -- matches `claude-opus-[4-9]` and clears the field before it sends.
          -- We checked that the pattern catches "claude-opus-5".
          --
          -- Trap, if one day you change model: "claude-fable-5" does NOT match
          -- any of the patterns of that function (it looks for opus/sonnet/haiku).
          -- So the plugin would really send temperature and the API would answer
          -- 400. With fable you need to remove it in another way.
        },
      },
    },
  },
  -- if you want to build from source then do `make BUILD_FROM_SOURCE=true`.
  -- Conditional, not static. the-grid (Debian) and ARCADE (Windows) share this file.
  -- On Windows `make` does not exist. If you choose a
  -- fixed one, avante fails the build on the other node.
  build = vim.fn.has("win32") == 1
    and "powershell -ExecutionPolicy Bypass -File Build.ps1 -BuildFromSource false"
    or "make",
  dependencies = {
    "nvim-treesitter/nvim-treesitter",
    "stevearc/dressing.nvim",
    "nvim-lua/plenary.nvim",
    "MunifTanjim/nui.nvim",
    --- The below dependencies are optional,
    "echasnovski/mini.pick", -- for file_selector provider mini.pick
    "nvim-telescope/telescope.nvim", -- for file_selector provider telescope
    "hrsh7th/nvim-cmp", -- autocompletion for avante commands and mentions
    "ibhagwan/fzf-lua", -- for file_selector provider fzf
    "nvim-tree/nvim-web-devicons", -- or echasnovski/mini.icons
    -- We removed the dependency "zbirenbaum/copilot.lua". It served only
    -- `provider = "copilot"`, which this config does not use (the provider is claude).
    -- It stayed installed and never configured. :checkhealth
    -- reported "Copilot LSP client not available". This error looked
    -- like a fault, but it was only an inert dependency.
    {
      -- support for image pasting
      "HakonHarnes/img-clip.nvim",
      event = "VeryLazy",
      opts = {
        -- recommended settings
        default = {
          embed_image_as_base64 = false,
          prompt_for_file_name = false,
          drag_and_drop = {
            insert_mode = true,
          },
          -- required for Windows users
          use_absolute_path = true,
        },
      },
    },
    {
      -- Make sure to set this up properly if you have lazy=true
      'MeanderingProgrammer/render-markdown.nvim',
      opts = {
        file_types = { "markdown", "Avante" },
      },
      ft = { "markdown", "Avante" },
    },
  },
}
