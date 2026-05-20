return setmetatable({
  history = [==[ [
  {
    "description": "",
    "implementation": "return function(opts)\n  -- Omarchy applies the theme across Hyprland, Waybar, terminals, etc.\n  vim.validate({ theme = { opts and opts.theme, \"string\" } })\n  vim.system({ \"omarchy-theme-set\", opts.theme }):wait()\nend",
    "option_example": {
      "theme": "gruvbox"
    },
    "option_list": "theme"
  }
] ]==],
  implementation = function()
    return function(opts)
      -- Omarchy applies the theme across Hyprland, Waybar, terminals, etc.
      vim.validate { theme = { opts and opts.theme, "string" } }
      vim.system({ "omarchy-theme-set", opts.theme }):wait()
    end
  end,
}, {
  __call = function(self, ...)
    return self.implementation()(...)
  end,
})
