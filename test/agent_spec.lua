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

-- Test: ask_user with choices uses vim.ui.select and returns the selected choice.
do
  local captured_choices, captured_prompt
  local original_select = vim.ui.select
  vim.ui.select = function(items, opts, cb)
    captured_choices = items
    captured_prompt = opts.prompt
    cb(items[2])
  end

  local result = agent.ask_user("Pick a style:", { "concise", "detailed", "bullets" })

  vim.ui.select = original_select
  assert(captured_prompt == "Pick a style:")
  assert(captured_choices[1] == "concise")
  assert(captured_choices[3] == "bullets")
  assert(result == "detailed", "got: " .. tostring(result))
  print "PASS: agent.ask_user choices via vim.ui.select"
end

-- Test: ask_user returns nil when vim.wait times out (60s with no response).
do
  local original_input = vim.ui.input
  local original_wait = vim.wait
  vim.ui.input = function(_opts, _cb)
    -- Never invoke the callback so the predicate never becomes true.
  end
  vim.wait = function(_timeout, _predicate, _interval)
    return false
  end

  local result = agent.ask_user "ignored"

  vim.ui.input = original_input
  vim.wait = original_wait

  assert(result == nil, "timeout returns nil, got: " .. tostring(result))
  print "PASS: agent.ask_user timeout returns nil"
end

-- Test: agent.call delegates to luai._dispatch_to_provider with __window = corner preset
-- and closes the returned stream before returning the result.
do
  local captured_prompt, captured_opts, close_called
  -- Stub luai to intercept dispatch.
  package.loaded["luai"] = {
    _dispatch_to_provider = function(prompt, opts)
      captured_prompt = prompt
      captured_opts = opts
      return "model response", {
        close = function() close_called = true end,
      }
    end,
  }

  local result = agent.call { prompt = "summarize this", provider = "fast" }

  assert(result == "model response", "raw result returned, got: " .. tostring(result))
  assert(captured_prompt == "summarize this", "prompt forwarded")
  assert(captured_opts.__window, "__window opts present")
  assert(captured_opts.__window.size == "corner", "size = corner")
  assert(captured_opts.__window.focus == false, "focus = false")
  assert(captured_opts.__window.winblend == 10, "winblend = 10")
  assert(captured_opts.__provider == "fast", "provider key converted to __provider")
  assert(captured_opts.provider == nil, "user-friendly `provider` removed")
  assert(close_called, "stream.close was invoked")
  print "PASS: agent.call delegates with corner-window opts and closes stream"
end
