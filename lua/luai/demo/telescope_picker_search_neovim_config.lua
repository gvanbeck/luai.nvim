return setmetatable({
  history = [==[ [
  {
    "description": "",
    "implementation": "return function(opts)\n  -- Grep inside stdpath('config') (Telescope live_grep).\n  opts = vim.tbl_extend('force', { cwd = vim.fn.stdpath('config') }, opts or {})\n  require('telescope.builtin').live_grep(opts)\nend",
    "option_example": [],
    "option_list": ""
  }
] ]==],
  implementation = function()
    return function(opts)
      -- Grep inside stdpath('config') (Telescope live_grep).
      opts = vim.tbl_extend("force", { cwd = vim.fn.stdpath "config" }, opts or {})
      require("telescope.builtin").live_grep(opts)
    end
  end,
}, {
  __call = function(self, ...)
    return self.implementation()(...)
  end,
})
