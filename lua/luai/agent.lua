local M = {}

---@param opts table
---@return string
function M.call(opts)
  error "luai.agent.call: not implemented yet"
end

---@param question string
---@param choices? string[]
---@return string?
function M.ask_user(question, choices)
  assert(type(question) == "string", "luai.agent.ask_user: question must be a string")

  local response
  local done = false

  if choices then
    vim.ui.select(choices, { prompt = question }, function(choice)
      response = choice
      done = true
    end)
  else
    vim.ui.input({ prompt = question }, function(input)
      response = input
      done = true
    end)
  end

  local ok = vim.wait(60000, function() return done end, 50)
  if not ok then
    return nil
  end
  return response
end

return M
