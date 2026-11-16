return {
  {
    "neovim/nvim-lspconfig",
    dependencies = {
      "saghen/blink.cmp",
      {
        "mason-org/mason.nvim",
        opts = {},
      },
      "mason-org/mason-lspconfig.nvim",
      "WhoIsSethDaniel/mason-tool-installer.nvim",
      { "j-hui/fidget.nvim", opts = {} },
    },
    config = function()
      vim.api.nvim_create_autocmd("LspAttach", {
        group = vim.api.nvim_create_augroup("kickstart-lsp-attach", { clear = true }),
        callback = function(event)
          local map = function(keys, func, desc, mode)
            mode = mode or "n"
            vim.keymap.set(mode, keys, func, { buffer = event.buf, desc = "LSP: " .. desc })
          end

          map("grn", vim.lsp.buf.rename, "[R]e[n]ame")
          map("gra", vim.lsp.buf.code_action, "[G]oto Code [A]ction", { "n", "x" })
          map("grD", vim.lsp.buf.declaration, "[G]oto [D]eclaration")

          map("gri", vim.lsp.buf.implementation, "[G]oto [I]mplementation")
          map("grt", vim.lsp.buf.type_definition, "[G]oto [T]ype definition")
          map("grr", vim.lsp.buf.references, "[G]oto [R]eferences")

          local client = vim.lsp.get_client_by_id(event.data.client_id)
          if client and client:supports_method("textDocument/documentHighlight", event.buf) then
            local highlight_augroup = vim.api.nvim_create_augroup("kickstart-lsp-highlight", { clear = false })
            vim.api.nvim_create_autocmd({ "CursorHold", "CursorHoldI" }, {
              buffer = event.buf,
              group = highlight_augroup,
              callback = vim.lsp.buf.document_highlight,
            })

            vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI" }, {
              buffer = event.buf,
              group = highlight_augroup,
              callback = vim.lsp.buf.clear_references,
            })

            vim.api.nvim_create_autocmd("LspDetach", {
              group = vim.api.nvim_create_augroup("kickstart-lsp-detach", { clear = true }),
              callback = function(event2)
                vim.lsp.buf.clear_references()
                vim.api.nvim_clear_autocmds({ group = "kickstart-lsp-highlight", buffer = event2.buf })
              end,
            })
          end

          if client and client:supports_method("textDocument/inlayHint", event.buf) then
            map("<leader>th", function() vim.lsp.inlay_hint.enable(not vim.lsp.inlay_hint.is_enabled({ bufnr = event.buf })) end, "[T]oggle Inlay [H]ints")
          end
        end,
      })

      local servers = {
        pyright = {},

        jdtls = {
          cmd = function(dispatchers, config)
            local root = config.root_dir or vim.fn.getcwd()
            local data_dir = vim.fn.stdpath("cache") .. "/jdtls/workspace/" .. vim.fs.basename(root) .. "-" .. vim.fn.sha256(root):sub(1, 8)
            local cmd = { "jdtls", "-data", data_dir }
            -- jdtls itself needs Java 25+ (its launcher only checks for 21), regardless of the java pinned by the project's mise.toml
            local mise = vim.system({ "mise", "where", "java@26" }, { text = true }):wait()
            if mise.code == 0 then
              local java = vim.fs.joinpath(vim.trim(mise.stdout), "bin", vim.fn.has("win32") == 1 and "java.exe" or "java")
              table.insert(cmd, "--java-executable=" .. java)
            else
              vim.notify("jdtls: java@26 not found in mise, using java from PATH", vim.log.levels.WARN)
            end
            local lombok = vim.fn.expand("$MASON/share/jdtls/lombok.jar")
            if vim.uv.fs_stat(lombok) then
              table.insert(cmd, "--jvm-arg=-javaagent:" .. lombok)
            else
              vim.notify("jdtls: lombok.jar not found, starting without Lombok support", vim.log.levels.WARN)
            end
            return vim.lsp.rpc.start(cmd, dispatchers, { cwd = config.cmd_cwd, env = config.cmd_env, detached = config.detached })
          end,
        },

        stylua = {},

        roslyn_ls = {
          capabilities = {
            workspace = {
              didChangeWatchedFiles = {
                -- Let Roslyn watch project files directly, including Unity's generated .csproj files.
                dynamicRegistration = false,
              },
            },
          },
          root_dir = function(bufnr, on_dir)
            local source_file = vim.api.nvim_buf_get_name(bufnr)

            local unreal_root = vim.fs.root(source_file, function(name) return name:match("%.uproject$") ~= nil end)
            if unreal_root then
              local rules_project = vim.fn.glob(unreal_root .. "/Intermediate/Build/BuildRulesProjects/**/*.csproj", false, true)[1]
              if rules_project then
                on_dir(vim.fs.dirname(rules_project))
                return
              end
            end

            local root = vim.fs.root(source_file, function(name) return name:match("%.slnx?$") ~= nil end)
              or vim.fs.root(source_file, function(name) return name:match("%.csproj$") ~= nil end)
            if root then on_dir(root) end
          end,
        },

        clangd = {
          cmd = {
            "clangd",
            "--use-dirty-headers",
            "--query-driver="
              .. vim.fn.expand("$HOME")
              .. "/.espressif/tools/**/bin/*,/opt/unreal-engine/Engine/Extras/ThirdPartyNotUE/SDKs/HostLinux/Linux_x64/v26_clang-20.1.8-rockylinux8/x86_64-unknown-linux-gnu/bin/clang++",
          },
        },

        astro = {
          init_options = {
            typescript = {
              tsdk = vim.fn.stdpath("data") .. "/mason/packages/astro-language-server/node_modules/typescript/lib",
            },
          },
        },

        tsc = {
          -- TypeScript 7 ships its own language server (tsc --lsp); lspconfig's default spawns node_modules/.bin/tsc without the .cmd extension, which fails on Windows
          cmd = function(dispatchers, config)
            local bin = vim.fs.joinpath(config.root_dir, "node_modules/.bin", vim.fn.has("win32") == 1 and "tsc.cmd" or "tsc")
            return vim.lsp.rpc.start({ bin, "--lsp", "--stdio" }, dispatchers, { cwd = config.root_dir })
          end,
          root_dir = function(bufnr, on_dir)
            local root = vim.fs.root(bufnr, "node_modules")
            if not root then return end
            local ok, pkg = pcall(vim.fn.readfile, vim.fs.joinpath(root, "node_modules/typescript/package.json"))
            if not ok then return end
            local version = vim.version.parse(vim.json.decode(table.concat(pkg, "\n")).version or "")
            if version and version.major >= 7 then on_dir(root) end
          end,
        },

        lua_ls = {
          on_init = function(client)
            client.server_capabilities.documentFormattingProvider = false -- Disable formatting (formatting is done by stylua)

            if client.workspace_folders then
              local path = client.workspace_folders[1].name
              if path ~= vim.fn.stdpath("config") and (vim.uv.fs_stat(path .. "/.luarc.json") or vim.uv.fs_stat(path .. "/.luarc.jsonc")) then return end
            end

            client.config.settings.Lua = vim.tbl_deep_extend("force", client.config.settings.Lua, {
              runtime = {
                version = "LuaJIT",
                path = { "lua/?.lua", "lua/?/init.lua" },
              },
              workspace = {
                checkThirdParty = false,
                library = vim.tbl_extend("force", vim.api.nvim_get_runtime_file("", true), {
                  "${3rd}/luv/library",
                  "${3rd}/busted/library",
                }),
              },
            })
          end,
          settings = {
            Lua = {
              format = { enable = false },
            },
          },
        },
      }

      local ensure_installed = vim.tbl_filter(function(name) return name ~= "tsc" end, vim.tbl_keys(servers))
      require("mason-tool-installer").setup({ ensure_installed = ensure_installed })

      local blink = require("blink-cmp")
      for name, server in pairs(servers) do
        server.capabilities = blink.get_lsp_capabilities(server.capabilities)
        vim.lsp.config(name, server)
        vim.lsp.enable(name)
      end
    end,
  },
}
