return {
  {
    'sindrets/diffview.nvim',
    cmd = { 'DiffviewOpen', 'DiffviewClose', 'DiffviewFileHistory' },
    keys = {
      { '<leader>do', '<cmd>DiffviewOpen<cr>', desc = '[D]iffview [O]pen changes' },
      { '<leader>dc', '<cmd>DiffviewClose<cr>', desc = '[D]iffview [C]lose' },
      { '<leader>dh', '<cmd>DiffviewFileHistory %<cr>', desc = '[D]iffview current file [H]istory' },
      { '<leader>dH', '<cmd>DiffviewFileHistory<cr>', desc = '[D]iffview repo [H]istory' },
    },
    opts = {},
  },
}
