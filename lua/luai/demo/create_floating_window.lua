return setmetatable({
  history = [==[ [
  {
    "description": "The function should also make sure to:\nCreate a floating window, with the provided background color.",
    "implementation": "return function(opts)\n  opts = opts or {}\n  local buf = vim.api.nvim_create_buf(false, true)\n  vim.api.nvim_buf_set_lines(buf, 0, -1, false, opts.contents or {})\n  if opts.filetype then\n    vim.bo[buf].filetype = opts.filetype\n  end\n  local hl = (\"LuaiFloatBg_%d\"):format(buf)\n  vim.api.nvim_set_hl(0, hl, { bg = opts.background })\n  local max_w, max_h = vim.o.columns - 4, vim.o.lines - 4\n  local width = math.min(80, max_w)\n  local height = math.min(math.max(1, #opts.contents), max_h)\n  height = math.max(3, height)\n  return vim.api.nvim_open_win(buf, true, {\n    relative = \"editor\",\n    row = math.floor((vim.o.lines - height) / 2),\n    col = math.floor((vim.o.columns - width) / 2),\n    width = width,\n    height = height,\n    style = \"minimal\",\n    border = \"rounded\",\n    title = opts.title,\n    title_pos = \"center\",\n    winhighlight = \"Normal:\" .. hl,\n  })\nend",
    "option_example": {
      "background": "green",
      "contents": [
        "print(\"hello world\")"
      ],
      "filetype": "lua",
      "title": "hello world 2"
    },
    "option_list": "contents,title,background,filetype"
  },
  {
    "description": "The function should also make sure to:\nhey, winhighlight is deprecated. dont do that",
    "implementation": "return function(opts)\n  opts = opts or {}\n  local lines = opts.contents or {}\n  local buf = vim.api.nvim_create_buf(false, true)\n  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)\n  if opts.filetype then\n    vim.bo[buf].filetype = opts.filetype\n  end\n  local hl = (\"LuaiFloatBg_%d\"):format(buf)\n  if opts.background then\n    vim.api.nvim_set_hl(0, hl, { bg = opts.background })\n  end\n  local max_w, max_h = vim.o.columns - 4, vim.o.lines - 4\n  local width = math.min(80, max_w)\n  local height = math.max(3, math.min(math.max(1, #lines), max_h))\n  local win = vim.api.nvim_open_win(buf, true, {\n    relative = \"editor\",\n    row = math.floor((vim.o.lines - height) / 2),\n    col = math.floor((vim.o.columns - width) / 2),\n    width = width,\n    height = height,\n    style = \"minimal\",\n    border = \"rounded\",\n    title = opts.title,\n    title_pos = \"center\",\n  })\n  -- Link Normal to a custom group via win-local winhl instead of open_win winhighlight.\n  if opts.background then\n    vim.wo[win].winhl = \"Normal:\" .. hl\n  end\n  return win\nend",
    "option_example": "{\"background\":\"green\",\"contents\":[\"print(\\\"hello world\\\")\"],\"title\":\"hello world 2\",\"filetype\":\"lua\"}",
    "option_list": "background,contents,title,filetype"
  }
] ]==],
  implementation = function()
    return function(opts)
      opts = opts or {}
      local lines = opts.contents or {}
      local buf = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
      if opts.filetype then
        vim.bo[buf].filetype = opts.filetype
      end
      local hl = ("LuaiFloatBg_%d"):format(buf)
      if opts.background then
        vim.api.nvim_set_hl(0, hl, { bg = opts.background })
      end
      local max_w, max_h = vim.o.columns - 4, vim.o.lines - 4
      local width = math.min(80, max_w)
      local height = math.max(3, math.min(math.max(1, #lines), max_h))
      local win = vim.api.nvim_open_win(buf, true, {
        relative = "editor",
        row = math.floor((vim.o.lines - height) / 2),
        col = math.floor((vim.o.columns - width) / 2),
        width = width,
        height = height,
        style = "minimal",
        border = "rounded",
        title = opts.title,
        title_pos = "center",
      })
      -- Link Normal to a custom group via win-local winhl instead of open_win winhighlight.
      if opts.background then
        vim.wo[win].winhl = "Normal:" .. hl
      end
      return win
    end
  end,
}, {
  __call = function(self, ...)
    return self.implementation()(...)
  end,
})
