local M = {}

---@param ctx? { range_start?: integer, range_end?: integer, range_present?: boolean }
---@return table: opts with auto-context keys populated
function M.build_opts(ctx)
  ctx = ctx or {}
  local bufnr = vim.api.nvim_get_current_buf()
  local win = vim.api.nvim_get_current_win()
  local cursor = vim.api.nvim_win_get_cursor(win)

  local opts = {
    bufnr = bufnr,
    win = win,
    cwd = vim.uv.cwd() or vim.fn.getcwd(),
    cword = vim.fn.expand "<cword>",
    cfile = vim.fn.expand "<cfile>",
    cursor = cursor,
    line_number = cursor[1],
    line = vim.api.nvim_buf_get_lines(bufnr, cursor[1] - 1, cursor[1], false)[1] or "",
    filetype = vim.bo[bufnr].filetype,
  }

  if ctx.range_present and ctx.range_start and ctx.range_end then
    opts.range = { ctx.range_start, ctx.range_end }
    local lines = vim.api.nvim_buf_get_lines(bufnr, ctx.range_start - 1, ctx.range_end, false)
    opts.selection = table.concat(lines, "\n")
  end

  return opts
end

return M
