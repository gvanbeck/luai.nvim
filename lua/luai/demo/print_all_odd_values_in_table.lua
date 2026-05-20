return setmetatable({
  history = [==[ [
  {
    "description": "",
    "implementation": "return function(opts)\n  -- Odd numeric entries only (array part of t).\n  for _, v in ipairs(opts.t or {}) do\n    if type(v) == \"number\" and v % 2 ~= 0 then\n      vim.print(v)\n    end\n  end\nend",
    "option_example": {
      "t": [
        1,
        2,
        3,
        4,
        5
      ]
    },
    "option_list": "t"
  }
] ]==],
  implementation = function()
    return function(opts)
      -- Odd numeric entries only (array part of t).
      for _, v in ipairs(opts.t or {}) do
        if type(v) == "number" and v % 2 ~= 0 then
          vim.print(v)
        end
      end
    end
  end,
}, {
  __call = function(self, ...)
    return self.implementation()(...)
  end,
})
