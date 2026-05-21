---@alias luai.Provider fun(prompt: string, opts: table): string

local M = {}

---@param _spec table
---@return luai.Provider
function M.cli(_spec)
  error "luai.providers.cli: not implemented yet"
end

---@param _spec table
---@return luai.Provider
function M.cursor_agent(_spec)
  error "luai.providers.cursor_agent: not implemented yet"
end

---@param _spec table
---@return luai.Provider
function M.claude_code(_spec)
  error "luai.providers.claude_code: not implemented yet"
end

return M
