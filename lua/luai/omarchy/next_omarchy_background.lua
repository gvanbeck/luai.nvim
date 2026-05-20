return setmetatable({
  history = [==[ [
  {
    "description": "The function should also make sure to:\nmove to the next omarchy background for the current theme",
    "implementation": "return function(opts)\n  -- Advance to the next wallpaper for the active Omarchy theme.\n  vim.system({ \"omarchy-theme-bg-next\" }):wait()\nend",
    "option_example": [],
    "option_list": ""
  }
] ]==],
  implementation = function()
    return function(opts)
      -- Advance to the next wallpaper for the active Omarchy theme.
      vim.system({ "omarchy-theme-bg-next" }):wait()
    end
  end,
}, {
  __call = function(self, ...)
    return self.implementation()(...)
  end,
})
