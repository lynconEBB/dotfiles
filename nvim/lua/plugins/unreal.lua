return {
  {
    name = 'ue-generated-sync',
    dir = vim.fn.stdpath 'config',
    lazy = false,
    config = function() require('ue_generated_sync').setup() end,
  },
}
