return setmetatable({
  history = [==[ [
  {
    "description": "",
    "implementation": "return function(opts)\n  opts = opts or {}\n  -- Open a centered float and SSH into terminal.shop from a job-driven terminal.\n  local buf = vim.api.nvim_create_buf(false, true)\n  local w = math.floor(vim.o.columns * 0.85)\n  local h = math.floor(vim.o.lines * 0.85)\n  vim.api.nvim_open_win(buf, true, {\n    relative = \"editor\",\n    width = w,\n    height = h,\n    row = math.max(0, math.floor((vim.o.lines - h) / 2)),\n    col = math.max(0, math.floor((vim.o.columns - w) / 2)),\n    style = \"minimal\",\n    border = \"rounded\",\n  })\n  vim.fn.termopen(\"ssh terminal.shop\", {\n    on_exit = function()\n      if vim.api.nvim_buf_is_valid(buf) then\n        vim.api.nvim_buf_delete(buf, { force = true })\n      end\n    end,\n  })\n  vim.cmd.startinsert()\nend",
    "option_example": [],
    "option_list": ""
  }
] ]==],
  implementation = function()
    return function(opts)
      opts = opts or {}
      -- Open a centered float and SSH into terminal.shop from a job-driven terminal.
      local buf = vim.api.nvim_create_buf(false, true)
      local w = math.floor(vim.o.columns * 0.85)
      local h = math.floor(vim.o.lines * 0.85)
      vim.api.nvim_open_win(buf, true, {
        relative = "editor",
        width = w,
        height = h,
        row = math.max(0, math.floor((vim.o.lines - h) / 2)),
        col = math.max(0, math.floor((vim.o.columns - w) / 2)),
        style = "minimal",
        border = "rounded",
      })
      vim.fn.termopen("ssh terminal.shop", {
        on_exit = function()
          if vim.api.nvim_buf_is_valid(buf) then
            vim.api.nvim_buf_delete(buf, { force = true })
          end
        end,
      })
      vim.cmd.startinsert()
    end
  end,
}, {
  __call = function(self, ...)
    return self.implementation()(...)
  end,
})
