---@class luai.StreamWin
---@field win integer
---@field buf integer
---@field append fun(chunk: string)
---@field replace fun(lines: string[])
---@field close fun()

local M = {}

---@param opts? { title?: string }
---@return luai.StreamWin
function M.open(opts)
  opts = opts or {}

  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].filetype = "lua"

  local width = math.floor(vim.o.columns * 0.8)
  local height = math.floor(vim.o.lines * 0.8)
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width,
    height = height,
    col = math.floor((vim.o.columns - width) / 2),
    row = math.floor((vim.o.lines - height) / 2),
    style = "minimal",
    border = "rounded",
    title = opts.title or "luai",
    title_pos = "center",
  })

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
