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

      local uht_save = 0
      local uht_running = false
      local uht_pending

      local function generate_unreal_header(bufnr)
        if not vim.api.nvim_buf_is_valid(bufnr) then return end
        if uht_running then
          uht_pending = bufnr
          return
        end

        local header = vim.api.nvim_buf_get_name(bufnr)
        local root = vim.fs.root(header, function(name) return name:match '%.uproject$' ~= nil end)
        if not root then return end

        local project_file = vim.fn.glob(root .. '/*.uproject', false, true)[1]
        if not project_file then return end

        local project = vim.fn.fnamemodify(project_file, ':t:r')
        local manifest = root .. '/Intermediate/Build/Linux/' .. project .. 'Editor/Development/' .. project .. 'Editor.uhtmanifest'
        if vim.uv.fs_stat(manifest) == nil then return end

        uht_running = true
        vim.system({
          '/opt/unreal-engine/Engine/Build/BatchFiles/RunUBT.sh',
          '-Mode=UnrealHeaderTool',
          project_file,
          manifest,
          '-WarningsAsErrors',
          '-installed',
        }, { cwd = root, text = true }, function(result)
          vim.schedule(function()
            uht_running = false
            if result.code ~= 0 then
              local output = result.stderr
              if not output or output == '' then output = result.stdout end
              vim.notify(output or 'Header generation failed', vim.log.levels.ERROR, { title = 'UnrealHeaderTool' })
            else
              local generated = root
                .. '/Intermediate/Build/Linux/UnrealEditor/Inc/'
                .. project
                .. '/UHT/'
                .. vim.fn.fnamemodify(header, ':t:r')
                .. '.generated.h'
              for _, client in ipairs(vim.lsp.get_clients { name = 'clangd' }) do
                client:notify('workspace/didChangeWatchedFiles', {
                  changes = { { uri = vim.uri_from_fname(generated), type = 2 } },
                })
              end
            end

            if uht_pending then
              local pending = uht_pending
              uht_pending = nil
              generate_unreal_header(pending)
            end
          end)
        end)
      end

      vim.api.nvim_create_autocmd('BufWritePost', {
        group = vim.api.nvim_create_augroup('unreal-generate-header', { clear = true }),
        pattern = '*.h',
        callback = function(event)
          local text = table.concat(vim.api.nvim_buf_get_lines(event.buf, 0, -1, false), '\n')
          if not text:find('GENERATED_BODY%s*%(') then return end

          uht_save = uht_save + 1
          local save = uht_save
          vim.defer_fn(function()
            if save == uht_save and vim.api.nvim_buf_is_valid(event.buf) then generate_unreal_header(event.buf) end
          end, 300)
        end,
      })

      local uht_running, uht_pending = {}, {}
      local function run_uht(project_root, project, manifest)
        uht_running[project_root] = true
        vim.system({
          '/opt/unreal-engine/Engine/Build/BatchFiles/RunUBT.sh',
          '-Mode=UnrealHeaderTool',
          project,
          manifest,
          '-WarningsAsErrors',
          '-installed',
        }, { cwd = project_root, text = true }, function(result)
          vim.schedule(function()
            uht_running[project_root] = nil
            if result.code == 0 then
              vim.lsp.enable('clangd', false)
              vim.lsp.enable('clangd')
            else
              vim.notify(result.stderr ~= '' and result.stderr or result.stdout, vim.log.levels.ERROR, { title = 'UnrealHeaderTool' })
            end

            if uht_pending[project_root] then
              uht_pending[project_root] = nil
              run_uht(project_root, project, manifest)
            end
          end)
        end)
      end

      vim.api.nvim_create_autocmd('BufWritePost', {
        group = vim.api.nvim_create_augroup('unreal-uht-on-save', { clear = true }),
        pattern = '*.h',
        callback = function(event)
          local lines = vim.api.nvim_buf_get_lines(event.buf, 0, -1, false)
          local is_reflected_header = vim.iter(lines):any(function(line) return line:match '%.generated%.h' ~= nil end)
          if not is_reflected_header then return end

          local project_root = vim.fs.root(event.file, function(name) return name:match '%.uproject$' ~= nil end)
          if not project_root then return end
          if uht_running[project_root] then
            uht_pending[project_root] = true
            return
          end

          local projects = vim.fn.glob(project_root .. '/*.uproject', false, true)
          local manifests = vim.fn.glob(project_root .. '/Intermediate/Build/**/*.uhtmanifest', false, true)
          if not projects[1] or not manifests[1] then return end

          run_uht(project_root, projects[1], manifests[1])
        end,
      })

      local servers = {
        stylua = {},

        roslyn_ls = {
          root_dir = function(bufnr, on_dir)
            local source_file = vim.api.nvim_buf_get_name(bufnr)
            local unreal_root = vim.fs.root(source_file, function(name)
              return name:match '%.uproject$' ~= nil
            end)

            if not unreal_root then return end

            local rules_projects = vim.fn.glob(unreal_root .. '/Intermediate/Build/BuildRulesProjects/**/*.csproj', false, true)
            if rules_projects[1] then on_dir(vim.fs.dirname(rules_projects[1])) end
          end,
        },

        clangd = {
          cmd = {
            'clangd',
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
