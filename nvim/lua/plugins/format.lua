return {
	{
		"stevearc/conform.nvim",
		event = { "BufWritePre" },
		cmd = { "ConformInfo" },
		keys = {
			{
				"<leader>f",
				function()
					require("conform").format({ async = true })
				end,
				mode = { "n", "v" },
				desc = "[F]ormat buffer",
			},
		},
		opts = {
			notify_on_error = true,
			format_on_save = function(bufnr)
				local enabled_filetypes = {
					lua = true,
					python = true,
				}
				if enabled_filetypes[vim.bo[bufnr].filetype] then
					return { timeout_ms = 500 }
				else
					return nil
				end
			end,
			default_format_opts = {
				lsp_format = "fallback",
			},
			formatters_by_ft = {
				-- put external formatters here
			},
		},
	},
}
