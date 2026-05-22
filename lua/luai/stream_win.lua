---@class luai.StreamWin
---@field win integer
---@field buf integer
---@field append fun(chunk: string)
---@field replace fun(lines: string[])
---@field close fun()

local M = {}

---@param opts? { title?: string, geometry?: { size?: string|table }, focus?: boolean, winblend?: integer }
---@return luai.StreamWin
function M.open(opts)
  opts = opts or {}
  local geometry = opts.geometry or { size = "fullsize" }

  local width, height, col, row
  if geometry.size == "corner" then
    width = 70
    height = 12
    col = math.max(0, vim.o.columns - width - 2)
    row = math.max(0, vim.o.lines - height - 2)
  elseif type(geometry.size) == "table" then
    width = geometry.size.width
    height = geometry.size.height
    col = geometry.size.col
    row = geometry.size.row
  else
    width = math.floor(vim.o.columns * 0.8)
    height = math.floor(vim.o.lines * 0.8)
    col = math.floor((vim.o.columns - width) / 2)
    row = math.floor((vim.o.lines - height) / 2)
  end

  local focus = opts.focus
  if focus == nil then focus = true end

  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].filetype = "lua"

  local win = vim.api.nvim_open_win(buf, focus, {
    relative = "editor",
    width = width,
    height = height,
    col = col,
    row = row,
    style = "minimal",
    border = "rounded",
    title = opts.title or "luai",
    title_pos = "center",
  })

  if opts.winblend then
    vim.wo[win].winblend = opts.winblend
  end

  local function append(chunk)
    if chunk == nil or chunk == "" then
      return
    end
    local last_idx = vim.api.nvim_buf_line_count(buf) - 1
    local current_last = vim.api.nvim_buf_get_lines(buf, last_idx, last_idx + 1, false)[1] or ""
    local combined = current_last .. chunk
    local new_lines = vim.split(combined, "\n", { plain = true })
    vim.api.nvim_buf_set_lines(buf, last_idx, last_idx + 1, false, new_lines)
    pcall(vim.cmd.redraw)
  end

  local function replace(lines)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].modifiable = false
    pcall(vim.cmd.redraw)
  end

  local function close()
    pcall(vim.api.nvim_win_close, win, true)
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
  end

  return {
    win = win,
    buf = buf,
    append = append,
    replace = replace,
    close = close,
  }
end

return M
