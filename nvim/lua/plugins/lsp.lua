return {
  {
    'neovim/nvim-lspconfig',
    dependencies = {
      'saghen/blink.cmp',
      {
        'mason-org/mason.nvim',
        opts = {},
      },
      'mason-org/mason-lspconfig.nvim',
      'WhoIsSethDaniel/mason-tool-installer.nvim',
      { 'j-hui/fidget.nvim', opts = {} },
    },
    config = function()
      vim.api.nvim_create_autocmd('LspAttach', {
        group = vim.api.nvim_create_augroup('kickstart-lsp-attach', { clear = true }),
        callback = function(event)
          local map = function(keys, func, desc, mode)
            mode = mode or 'n'
            vim.keymap.set(mode, keys, func, { buffer = event.buf, desc = 'LSP: ' .. desc })
          end

          map('grn', vim.lsp.buf.rename, '[R]e[n]ame')
          map('gra', vim.lsp.buf.code_action, '[G]oto Code [A]ction', { 'n', 'x' })
          map('grD', vim.lsp.buf.declaration, '[G]oto [D]eclaration')

          map('gri', vim.lsp.buf.implementation, '[G]oto [I]mplementation')
          map('grt', vim.lsp.buf.type_definition, '[G]oto [T]ype definition')
          map('grr', vim.lsp.buf.references, '[G]oto [R]eferences')

          local client = vim.lsp.get_client_by_id(event.data.client_id)
          if client and client:supports_method('textDocument/documentHighlight', event.buf) then
            local highlight_augroup = vim.api.nvim_create_augroup('kickstart-lsp-highlight', { clear = false })
            vim.api.nvim_create_autocmd({ 'CursorHold', 'CursorHoldI' }, {
              buffer = event.buf,
              group = highlight_augroup,
              callback = vim.lsp.buf.document_highlight,
            })

            vim.api.nvim_create_autocmd({ 'CursorMoved', 'CursorMovedI' }, {
              buffer = event.buf,
              group = highlight_augroup,
              callback = vim.lsp.buf.clear_references,
            })

            vim.api.nvim_create_autocmd('LspDetach', {
              group = vim.api.nvim_create_augroup('kickstart-lsp-detach', { clear = true }),
              callback = function(event2)
                vim.lsp.buf.clear_references()
                vim.api.nvim_clear_autocmds { group = 'kickstart-lsp-highlight', buffer = event2.buf }
              end,
            })
          end

          if client and client:supports_method('textDocument/inlayHint', event.buf) then
            map('<leader>th', function() vim.lsp.inlay_hint.enable(not vim.lsp.inlay_hint.is_enabled { bufnr = event.buf }) end, '[T]oggle Inlay [H]ints')
          end
        end,
      })

      local servers = {
        pyright = {},

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

            local unreal_root = vim.fs.root(source_file, function(name) return name:match '%.uproject$' ~= nil end)
            if unreal_root then
              local rules_project = vim.fn.glob(unreal_root .. '/Intermediate/Build/BuildRulesProjects/**/*.csproj', false, true)[1]
              if rules_project then
                on_dir(vim.fs.dirname(rules_project))
                return
              end
            end

            local root = vim.fs.root(source_file, function(name) return name:match '%.slnx?$' ~= nil end)
              or vim.fs.root(source_file, function(name) return name:match '%.csproj$' ~= nil end)
            if root then on_dir(root) end
          end,
        },

        clangd = {
          cmd = {
            'clangd',
            '--use-dirty-headers',
            '--query-driver='
              .. vim.fn.expand '$HOME'
              .. '/.espressif/tools/**/bin/*,/opt/unreal-engine/Engine/Extras/ThirdPartyNotUE/SDKs/HostLinux/Linux_x64/v26_clang-20.1.8-rockylinux8/x86_64-unknown-linux-gnu/bin/clang++',
          },
        },

        astro = {
          init_options = {
            typescript = {
              tsdk = vim.fn.stdpath 'data' .. '/mason/packages/astro-language-server/node_modules/typescript/lib',
            },
          },
        },

        lua_ls = {
          on_init = function(client)
            client.server_capabilities.documentFormattingProvider = false -- Disable formatting (formatting is done by stylua)

            if client.workspace_folders then
              local path = client.workspace_folders[1].name
              if path ~= vim.fn.stdpath 'config' and (vim.uv.fs_stat(path .. '/.luarc.json') or vim.uv.fs_stat(path .. '/.luarc.jsonc')) then return end
            end

            client.config.settings.Lua = vim.tbl_deep_extend('force', client.config.settings.Lua, {
              runtime = {
                version = 'LuaJIT',
                path = { 'lua/?.lua', 'lua/?/init.lua' },
              },
              workspace = {
                checkThirdParty = false,
                library = vim.tbl_extend('force', vim.api.nvim_get_runtime_file('', true), {
                  '${3rd}/luv/library',
                  '${3rd}/busted/library',
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

      local ensure_installed = vim.tbl_keys(servers or {})
      require('mason-tool-installer').setup { ensure_installed = ensure_installed }

      local blink = require 'blink-cmp'
      for name, server in pairs(servers) do
        server.capabilities = blink.get_lsp_capabilities(server.capabilities)
        vim.lsp.config(name, server)
        vim.lsp.enable(name)
      end
    end,
  },
}
