return setmetatable({
  history = [==[ [
  {
    "description": "",
    "implementation": "return function(opts)\n  -- New split buffer holds the message (opts.message defaults to empty).\n  local message = type(opts) == \"table\" and opts.message or \"\"\n  vim.cmd.new()\n  vim.fn.setline(1, vim.split(message, \"\\n\", { plain = true }))\nend",
    "option_example": {
      "message": "hi react miami"
    },
    "option_list": "message"
  },
  {
    "description": "The function should also make sure to:\nopen in a floating window",
    "implementation": "return function(opts)\n  -- Floating scratch buffer shows opts.message (empty string if missing or invalid).\n  local message = type(opts) == \"table\" and type(opts.message) == \"string\" and opts.message or \"\"\n  local lines = vim.split(message, \"\\n\", { plain = true })\n  if #lines == 0 then\n    lines = { \"\" }\n  end\n  local buf = vim.api.nvim_create_buf(false, true)\n  vim.bo[buf].bufhidden = \"wipe\"\n  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)\n  local max_w = 1\n  for _, line in ipairs(lines) do\n    max_w = math.max(max_w, vim.api.nvim_strwidth(line))\n  end\n  local width = math.max(1, math.min(vim.o.columns - 2, max_w + 2))\n  local height = math.max(1, math.min(vim.o.lines - 2, #lines))\n  local row = math.floor((vim.o.lines - height) / 2)\n  local col = math.floor((vim.o.columns - width) / 2)\n  vim.api.nvim_open_win(buf, true, {\n    relative = \"editor\",\n    width = width,\n    height = height,\n    row = row,\n    col = col,\n    style = \"minimal\",\n    border = \"single\",\n  })\nend",
    "option_example": "{\"message\":\"hi react miami\"}",
    "option_list": "message"
  }
] ]==],
  implementation = function()
    return function(opts)
      -- Floating scratch buffer shows opts.message (empty string if missing or invalid).
      local message = type(opts) == "table" and type(opts.message) == "string" and opts.message or ""
      local lines = vim.split(message, "\n", { plain = true })
      if #lines == 0 then
        lines = { "" }
      end
      local buf = vim.api.nvim_create_buf(false, true)
      vim.bo[buf].bufhidden = "wipe"
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
      local max_w = 1
      for _, line in ipairs(lines) do
        max_w = math.max(max_w, vim.api.nvim_strwidth(line))
      end
      local width = math.max(1, math.min(vim.o.columns - 2, max_w + 2))
      local height = math.max(1, math.min(vim.o.lines - 2, #lines))
      local row = math.floor((vim.o.lines - height) / 2)
      local col = math.floor((vim.o.columns - width) / 2)
      vim.api.nvim_open_win(buf, true, {
        relative = "editor",
        width = width,
        height = height,
        row = row,
        col = col,
        style = "minimal",
        border = "single",
      })
    end
  end,
}, {
  __call = function(self, ...)
    return self.implementation()(...)
  end,
})
