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

-- Test: cmd as function receives (prompt, opts) and its return value is the argv.
do
  local seen_prompt, seen_opts, captured_argv
  vim.system = function(argv, _)
    captured_argv = argv
    return {
      wait = function()
        return { code = 0, stdout = "ok", stderr = "" }
      end,
    }
  end
  vim.fn.executable = function(_) return 1 end

  local p = providers.cli {
    name = "dyn",
    cmd = function(prompt, opts)
      seen_prompt = prompt
      seen_opts = opts
      return { "tool", "--prompt", prompt }
    end,
  }

  p("hello", { x = 1 })
  assert(seen_prompt == "hello", "prompt forwarded to cmd fn")
  assert(seen_opts.x == 1, "opts forwarded to cmd fn")
  assert(captured_argv[1] == "tool")
  assert(captured_argv[3] == "hello")
  print "PASS: cli dynamic argv"
end

-- Test: missing executable errors with provider name and missing command.
do
  vim.fn.executable = function(_) return 0 end
  vim.system = function(_, _)
    error "vim.system should not be called when executable is missing"
  end

  local p = providers.cli { name = "nope", cmd = { "missing-binary" } }
  local ok, err = pcall(p, "", {})
  assert(not ok, "should have errored")
  assert(err:match "nope", "error mentions provider name: " .. tostring(err))
  assert(err:match "missing%-binary", "error mentions missing command: " .. tostring(err))
  print "PASS: cli missing executable errors"
end

-- Test: non-zero exit code surfaces stderr in the error.
do
  vim.fn.executable = function(_) return 1 end
  vim.system = function(_, _)
    return {
      wait = function()
        return { code = 2, stdout = "", stderr = "boom" }
      end,
    }
  end

  local p = providers.cli { name = "fail", cmd = { "x" } }
  local ok, err = pcall(p, "", {})
  assert(not ok)
  assert(err:match "fail failed", "error mentions <name> failed: " .. tostring(err))
  assert(err:match "boom", "error includes stderr: " .. tostring(err))
  print "PASS: cli non-zero exit errors"
end

-- Test: non-zero exit with empty stderr falls back to stdout.
do
  vim.fn.executable = function(_) return 1 end
  vim.system = function(_, _)
    return {
      wait = function()
        return { code = 3, stdout = "out-only", stderr = "" }
      end,
    }
  end

  local p = providers.cli { name = "f2", cmd = { "x" } }
  local ok, err = pcall(p, "", {})
  assert(not ok)
  assert(err:match "out%-only", "error falls back to stdout when stderr empty: " .. tostring(err))
  print "PASS: cli non-zero exit falls back to stdout"
end

-- Test: parse_response transforms stdout into the returned value.
do
  vim.fn.executable = function(_) return 1 end
  vim.system = function(_, _)
    return {
      wait = function()
        return { code = 0, stdout = '{"result":"parsed"}', stderr = "" }
      end,
    }
  end

  local p = providers.cli {
    name = "p",
    cmd = { "x" },
    parse_response = function(stdout)
      return vim.json.decode(stdout).result
    end,
  }
  assert(p("", {}) == "parsed", "parse_response result returned")
  print "PASS: cli parse_response"
end
