return {
  {
    'nvim-mini/mini.nvim',
    version = false,
    config = function()
      require('mini.pairs').setup()
      require('mini.starter').setup()
      require('mini.splitjoin').setup()

      local statusline = require 'mini.statusline'
      statusline.setup { use_icons = vim.g.have_nerd_font }
      statusline.section_location = function() return '%2l:%-2v' end
    end,
  },
}
