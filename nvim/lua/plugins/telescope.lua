return {
  {
    "nvim-telescope/telescope.nvim",
    enabled = true,
    event = "VimEnter",
    dependencies = {
      "nvim-lua/plenary.nvim",
      {
        "nvim-telescope/telescope-fzf-native.nvim",
        build = "make",
        cond = function() return vim.fn.executable("make") == 1 end,
      },
      { "nvim-telescope/telescope-ui-select.nvim" },
      { "nvim-tree/nvim-web-devicons", enabled = vim.g.have_nerd_font },
    },
    config = function()
      -- First matching profile wins. All markers are relative to the current cwd.
      local search_projects = {
        {
          name = "unity",
          root = { directories = { "Packages", "Assets" } },
          exclude = { "UserSettings", "Logs", "Library", "Temp", "obj" },
          exclude_files = { "*.meta", "*.fbx", "*.prefab", "*.asset", "*.mat", "*.unity" },
        },
        {
          name = "unreal",
          root = { files = { "*.uproject" } },
          exclude = { "Binaries", "Intermediate", "Content", "Saved", "DerivedDataCache" },
        },
      }

      local function match_search_project(cwd)
        for _, profile in ipairs(search_projects) do
          local directories = profile.root.directories or {}
          local files = profile.root.files or {}
          local matches = #directories + #files > 0

          for _, directory in ipairs(directories) do
            if vim.fn.isdirectory(vim.fs.joinpath(cwd, directory)) ~= 1 then
              matches = false
              break
            end
          end

          if matches then
            for _, pattern in ipairs(files) do
              local found = false
              local matcher = vim.regex(vim.fn.glob2regpat(pattern))
              for name in vim.fs.dir(cwd) do
                if matcher:match_str(name) and vim.fn.filereadable(vim.fs.joinpath(cwd, name)) == 1 then
                  found = true
                  break
                end
              end
              if not found then
                matches = false
                break
              end
            end
          end

          if matches then return profile end
        end
      end

      local function project_exclude_args(profile)
        local args = {}
        for _, directory in ipairs(profile and profile.exclude or {}) do
          -- Exclusions are root-relative directory paths, not basename filters.
          local path = directory:gsub("\\", "/"):gsub("^%./", ""):gsub("^/+", ""):gsub("/+$", "")
          if path ~= "" then
            args[#args + 1] = "--glob"
            args[#args + 1] = "!/" .. path .. "/**"
          end
        end
        -- Filename globs match at any depth, e.g. "*.meta" or "*.generated.cs".
        for _, pattern in ipairs(profile and profile.exclude_files or {}) do
          if pattern ~= "" then
            args[#args + 1] = "--glob"
            args[#args + 1] = "!" .. pattern:gsub("\\", "/")
          end
        end
        return args
      end

      require("telescope").setup({
        pickers = {
          find_files = {
            fuzzy = false,
            case_mode = "ignore_case",
            path_display = { "filename_first" },

            entry_index = {
              ordinal = function(entry) return vim.fn.fnamemodify(entry.value, ":t") end,
            },
          },
        },
        extensions = {
          ["ui-select"] = { require("telescope.themes").get_dropdown() },
        },
      })

      -- Enable Telescope extensions if they are installed
      pcall(require("telescope").load_extension, "fzf")
      pcall(require("telescope").load_extension, "ui-select")

      -- See `:help telescope.builtin`
      local builtin = require("telescope.builtin")
      local function open_project_picker(picker_name)
        if vim.fn.executable("rg") ~= 1 then
          vim.notify("Project searches require ripgrep (rg)", vim.log.levels.ERROR, { title = "Telescope" })
          return
        end

        local cwd = vim.fn.getcwd()
        local args = project_exclude_args(match_search_project(cwd))
        local opts = { cwd = cwd }
        if picker_name == "find_files" then
          opts.find_command = vim.list_extend({ "rg", "--files", "--color", "never" }, args)
        else
          opts.additional_args = args
        end
        builtin[picker_name](opts)
      end

      vim.keymap.set("n", "<leader>sh", builtin.help_tags, { desc = "[S]earch [H]elp" })
      vim.keymap.set("n", "<leader>sk", builtin.keymaps, { desc = "[S]earch [K]eymaps" })
      vim.keymap.set("n", "<leader>sf", function() open_project_picker("find_files") end, { desc = "[S]earch [F]iles" })
      vim.keymap.set("n", "<leader>ss", builtin.builtin, { desc = "[S]earch [S]elect Telescope" })
      vim.keymap.set({ "n", "v" }, "<leader>sw", function() open_project_picker("grep_string") end, { desc = "[S]earch current [W]ord" })
      vim.keymap.set("n", "<leader>sg", function() open_project_picker("live_grep") end, { desc = "[S]earch by [G]rep" })
      vim.keymap.set("n", "<leader>sd", builtin.diagnostics, { desc = "[S]earch [D]iagnostics" })
      vim.keymap.set("n", "<leader>sr", builtin.resume, { desc = "[S]earch [R]esume" })
      vim.keymap.set("n", "<leader>s.", builtin.oldfiles, { desc = "[S]earch Recent Files (\".\" for repeat)" })
      vim.keymap.set("n", "<leader>sc", builtin.commands, { desc = "[S]earch [C]ommands" })
      vim.keymap.set("n", "<leader><leader>", builtin.buffers, { desc = "[ ] Find existing buffers" })

      vim.api.nvim_create_autocmd("LspAttach", {
        group = vim.api.nvim_create_augroup("telescope-lsp-attach", { clear = true }),
        callback = function(event)
          local buf = event.buf

          vim.keymap.set("n", "grr", builtin.lsp_references, { buffer = buf, desc = "[G]oto [R]eferences" })
          vim.keymap.set("n", "gri", builtin.lsp_implementations, { buffer = buf, desc = "[G]oto [I]mplementation" })
          vim.keymap.set("n", "grd", builtin.lsp_definitions, { buffer = buf, desc = "[G]oto [D]efinition" })
          vim.keymap.set("n", "gO", builtin.lsp_document_symbols, { buffer = buf, desc = "Open Document Symbols" })
          vim.keymap.set("n", "gW", builtin.lsp_dynamic_workspace_symbols, { buffer = buf, desc = "Open Workspace Symbols" })
          vim.keymap.set("n", "grt", builtin.lsp_type_definitions, { buffer = buf, desc = "[G]oto [T]ype Definition" })
        end,
      })

      -- Override default behavior and theme when searching
      vim.keymap.set("n", "<leader>/", function()
        -- You can pass additional configuration to Telescope to change the theme, layout, etc.
        builtin.current_buffer_fuzzy_find(require("telescope.themes").get_dropdown({
          winblend = 10,
          previewer = false,
        }))
      end, { desc = "[/] Fuzzily search in current buffer" })

      -- It's also possible to pass additional configuration options.
      --  See `:help telescope.builtin.live_grep()` for information about particular keys
      vim.keymap.set(
        "n",
        "<leader>s/",
        function()
          builtin.live_grep({
            grep_open_files = true,
            prompt_title = "Live Grep in Open Files",
          })
        end,
        { desc = "[S]earch [/] in Open Files" }
      )

      -- Shortcut for searching your Neovim configuration files
      vim.keymap.set(
        "n",
        "<leader>sn",
        function()
          builtin.find_files({
            cwd = vim.fn.stdpath("config"),
          })
        end,
        { desc = "[S]earch [N]eovim files" }
      )

      -- Unreal related searches
      local unreal_search = {
        search_dirs = { "Editor", "Runtime", "Developer" },
        exclude_files = { "*.uasset", "*.uassets" },
      }

      local function open_unreal_picker(picker_name)
        local engine_root = vim.env.UE_DIR
        if not engine_root or engine_root == "" then
          vim.notify("UE_DIR is not configured!", vim.log.levels.ERROR, { title = "Unreal Engine" })
          return
        end

        local source_root = vim.fs.joinpath(engine_root, "Engine", "Source")
        local stat = vim.uv.fs_stat(source_root)
        if not stat or stat.type ~= "directory" then
          vim.notify("UE_DIR does not contain a valid Engine/Source directory!", vim.log.levels.ERROR, { title = "Unreal Engine" })
          return
        end

        if vim.fn.executable("rg") ~= 1 then
          vim.notify("Unreal searches require ripgrep (rg)", vim.log.levels.ERROR, { title = "Unreal Engine" })
          return
        end

        local args = project_exclude_args(unreal_search)
        local opts = {
          prompt_title = "Unreal Engine Source",
          cwd = source_root,
          search_dirs = vim.deepcopy(unreal_search.search_dirs),
          path_display = { "truncate" },
        }
        if picker_name == "find_files" then
          opts.find_command = vim.list_extend({ "rg", "--files", "--color", "never" }, args)
        else
          opts.additional_args = args
        end
        builtin[picker_name](opts)
      end

      vim.keymap.set("n", "<leader>uf", function() open_unreal_picker("find_files") end, { desc = "[S]earch [U]nreal [F]iles" })
      vim.keymap.set("n", "<leader>ug", function() open_unreal_picker("live_grep") end, { desc = "[S]earch [U]nreal by [G]rep" })
    end,
  },
}
