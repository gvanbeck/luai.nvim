-- Run with: nvim --headless --noplugin -u NONE -l test/providers_spec.lua
vim.opt.rtp:append "."

local providers = require "luai.providers"

assert(type(providers.cli) == "function", "providers.cli must be a function")
assert(type(providers.cursor_agent) == "function", "providers.cursor_agent must be a function")
assert(type(providers.claude_code) == "function", "providers.claude_code must be a function")
print "PASS: providers module exports"

-- Test: cli with a static argv list invokes vim.system with that argv and
-- returns stdout unchanged when no parse_response is given.
do
  local captured_argv, captured_opts
  vim.system = function(argv, opts)
    captured_argv = argv
    captured_opts = opts
    return {
      wait = function()
        return { code = 0, stdout = "raw response text", stderr = "" }
      end,
    }
  end
  vim.fn.executable = function(_) return 1 end

  local p = providers.cli {
    name = "test",
    cmd = { "fake-cli", "--flag", "value" },
  }

  local result = p("my prompt", { foo = 1 })
  assert(result == "raw response text", "expected stdout returned unchanged, got: " .. tostring(result))
  assert(captured_argv[1] == "fake-cli")
  assert(captured_argv[2] == "--flag")
  assert(captured_argv[3] == "value")
  assert(captured_opts.text == true, "vim.system called with text=true")
  print "PASS: cli static argv"
end
