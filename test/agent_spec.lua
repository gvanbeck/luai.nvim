-- Run with: nvim --headless --noplugin -u NONE -l test/agent_spec.lua
vim.opt.rtp:append "."

-- The agent module loads on-demand; no stubs needed for ask_user tests.
local agent = require "luai.agent"

assert(type(agent.call) == "function", "agent.call exported")
assert(type(agent.ask_user) == "function", "agent.ask_user exported")
print "PASS: luai.agent module exports"

-- Test: ask_user without choices uses vim.ui.input and returns the input value.
do
  local captured_prompt
  local original_input = vim.ui.input
  vim.ui.input = function(opts, cb)
    captured_prompt = opts.prompt
    cb "user typed this"
  end

  local result = agent.ask_user "What is your name?"

  vim.ui.input = original_input
  assert(captured_prompt == "What is your name?")
  assert(result == "user typed this", "got: " .. tostring(result))
  print "PASS: agent.ask_user free-text via vim.ui.input"
end
