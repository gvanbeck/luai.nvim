return setmetatable({
  history = [==[ [
  {
    "description": "",
    "implementation": "return function(opts)\n  -- Collapse runs of whitespace to one space, then trim ends.\n  local text = (opts and opts.text) or \"\"\n  return vim.trim((text:gsub(\"%s+\", \" \")))\nend",
    "option_example": {
      "text": "start     hello  world  "
    },
    "option_list": "text"
  }
] ]==],
  implementation = function()
    return function(opts)
      -- Collapse runs of whitespace to one space, then trim ends.
      local text = (opts and opts.text) or ""
      return vim.trim((text:gsub("%s+", " ")))
    end
  end,
}, {
  __call = function(self, ...)
    return self.implementation()(...)
  end,
})
