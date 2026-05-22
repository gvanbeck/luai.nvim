local M = {}

---@param opts { prompt: string, provider?: string, [string]: any }
---@return string
function M.call(opts)
  assert(type(opts) == "table", "luai.agent.call: opts table required")
  assert(type(opts.prompt) == "string", "luai.agent.call: `prompt` is required")

  local call_opts = vim.deepcopy(opts)
  if call_opts.provider then
    call_opts.__provider = call_opts.provider
    call_opts.provider = nil
  end
  call_opts.__window = { size = "corner", focus = false, winblend = 10 }

  local luai = require "luai"
  local result, stream = luai._dispatch_to_provider(opts.prompt, call_opts)
  stream.close()
  return result
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
