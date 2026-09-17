return {
  {
    'stevearc/oil.nvim',
    config = function(opts)
      require('oil').setup(opts)
      vim.keymap.set('n', '-', '<cmd>Oil<cr>')
      vim.keymap.set('n', '_', '<cmd>Oil .<cr>')
    end,
    ---@module 'oil'
    ---@type oil.SetupOpts
    opts = {},
    dependencies = { { 'nvim-mini/mini.icons', opts = {} } },
  },
}
