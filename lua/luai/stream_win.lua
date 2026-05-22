---@class luai.StreamWin
---@field win integer
---@field buf integer
---@field append fun(chunk: string)
---@field replace fun(lines: string[])
---@field close fun()

local M = {}

---@param _opts? { title?: string }
---@return luai.StreamWin
function M.open(_opts)
  error "luai.stream_win.open: not implemented yet"
end

return M
