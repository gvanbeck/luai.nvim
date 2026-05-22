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

-- Test: cursor_agent builds the documented argv and extracts .result.
do
  local captured_argv
  vim.fn.executable = function(_) return 1 end
  vim.system = function(argv, _)
    captured_argv = argv
    return {
      wait = function()
        return {
          code = 0,
          stdout = '{"result": "return function(opts) end"}',
          stderr = "",
        }
      end,
    }
  end

  local p = providers.cursor_agent { model = "composer-2-fast" }
  local result = p("my prompt", {})
  assert(result == "return function(opts) end", "extracts .result")

  assert(captured_argv[1] == "agent", "argv[1] == 'agent'")
  assert(vim.list_contains(captured_argv, "-p"))
  assert(vim.list_contains(captured_argv, "--mode"))
  assert(vim.list_contains(captured_argv, "ask"))
  assert(vim.list_contains(captured_argv, "--output-format"))
  assert(vim.list_contains(captured_argv, "json"))
  assert(vim.list_contains(captured_argv, "--model"))
  assert(vim.list_contains(captured_argv, "composer-2-fast"))
  assert(vim.list_contains(captured_argv, "--trust"))
  assert(vim.list_contains(captured_argv, "--workspace"))
  assert(captured_argv[#captured_argv] == "my prompt", "prompt is the last argv element")
  print "PASS: cursor_agent argv + JSON parse"
end

-- Test: opts.__model overrides the default model.
do
  local captured_argv
  vim.fn.executable = function(_) return 1 end
  vim.system = function(argv, _)
    captured_argv = argv
    return {
      wait = function()
        return { code = 0, stdout = '{"result":"x"}', stderr = "" }
      end,
    }
  end

  local p = providers.cursor_agent { model = "composer-2-fast" }
  p("prompt", { __model = "gpt-5.4-medium-fast" })
  assert(vim.list_contains(captured_argv, "gpt-5.4-medium-fast"))
  assert(not vim.list_contains(captured_argv, "composer-2-fast"))
  print "PASS: cursor_agent __model override"
end

-- Test: invalid JSON from the agent surfaces a clear provider-named error.
do
  vim.fn.executable = function(_) return 1 end
  vim.system = function(_, _)
    return {
      wait = function()
        return { code = 0, stdout = "not json at all", stderr = "" }
      end,
    }
  end

  local p = providers.cursor_agent { model = "composer-2-fast" }
  local ok, err = pcall(p, "", {})
  assert(not ok)
  assert(err:match "cursor_agent: invalid JSON", "error names provider + says invalid JSON: " .. tostring(err))
  print "PASS: cursor_agent invalid JSON errors"
end

-- Test: JSON without a string `.result` field surfaces a clear error.
do
  vim.fn.executable = function(_) return 1 end
  vim.system = function(_, _)
    return {
      wait = function()
        return { code = 0, stdout = '{"other":"x"}', stderr = "" }
      end,
    }
  end

  local p = providers.cursor_agent { model = "composer-2-fast" }
  local ok, err = pcall(p, "", {})
  assert(not ok)
  assert(err:match "result", "error mentions the missing field: " .. tostring(err))
  print "PASS: cursor_agent missing .result errors"
end

-- Test: claude_code builds expected argv and extracts .result.
do
  local captured_argv
  vim.fn.executable = function(_) return 1 end
  vim.system = function(argv, _)
    captured_argv = argv
    return {
      wait = function()
        return {
          code = 0,
          stdout = '{"result":"return function(opts) end"}',
          stderr = "",
        }
      end,
    }
  end

  local p = providers.claude_code { model = "sonnet" }
  local result = p("my prompt", {})
  assert(result == "return function(opts) end")

  assert(captured_argv[1] == "claude")
  assert(vim.list_contains(captured_argv, "-p"))
  assert(vim.list_contains(captured_argv, "--output-format"))
  assert(vim.list_contains(captured_argv, "json"))
  assert(vim.list_contains(captured_argv, "--model"))
  assert(vim.list_contains(captured_argv, "sonnet"))
  assert(captured_argv[#captured_argv] == "my prompt", "prompt is last argv element")
  print "PASS: claude_code argv + JSON parse"
end

-- Test: opts.__model overrides default model.
do
  local captured_argv
  vim.fn.executable = function(_) return 1 end
  vim.system = function(argv, _)
    captured_argv = argv
    return {
      wait = function()
        return { code = 0, stdout = '{"result":"x"}', stderr = "" }
      end,
    }
  end

  local p = providers.claude_code { model = "sonnet" }
  p("prompt", { __model = "opus" })
  assert(vim.list_contains(captured_argv, "opus"))
  assert(not vim.list_contains(captured_argv, "sonnet"))
  print "PASS: claude_code __model override"
end

-- Test: cli with opts.__on_chunk uses vim.system's async/callback form
-- and forwards stdout chunks to __on_chunk; the final return is the concatenated stdout.
do
  local captured_argv, captured_stdout_cb, captured_on_complete
  vim.fn.executable = function(_) return 1 end
  vim.system = function(argv, sys_opts, on_complete)
    captured_argv = argv
    captured_stdout_cb = sys_opts.stdout
    captured_on_complete = on_complete
    vim.schedule(function()
      sys_opts.stdout(nil, "hello ")
      sys_opts.stdout(nil, "world")
      on_complete { code = 0, stdout = "", stderr = "" }
    end)
    return { kill = function(_) end }
  end

  local chunks = {}
  local p = providers.cli {
    name = "stream-test",
    cmd = { "x" },
  }
  local result = p("prompt", {
    __on_chunk = function(c) table.insert(chunks, c) end,
  })

  assert(result == "hello world", "concatenated stdout returned, got: " .. tostring(result))
  assert(#chunks == 2, "two chunks forwarded, got: " .. #chunks)
  assert(chunks[1] == "hello ")
  assert(chunks[2] == "world")
  assert(captured_argv[1] == "x")
  assert(type(captured_on_complete) == "function", "vim.system called in async form (3rd arg)")
  print "PASS: cli async with __on_chunk"
end

-- Test: when vim.wait times out, sys:kill is called and an error is raised.
do
  vim.fn.executable = function(_) return 1 end
  local kill_called = false
  vim.system = function(_, _, _on_complete)
    -- Never call on_complete so vim.wait will time out
    return { kill = function(_sig) kill_called = true end }
  end

  -- Monkey-patch vim.wait to return false (timeout) immediately for the test.
  local original_wait = vim.wait
  vim.wait = function(_timeout_ms, _predicate, _interval)
    return false
  end

  local p = providers.cli { name = "slow", cmd = { "x" } }
  local ok, err = pcall(p, "", { __on_chunk = function() end })

  vim.wait = original_wait

  assert(not ok)
  assert(err:match "slow: generation timed out", "error mentions timeout: " .. tostring(err))
  assert(kill_called, "sys:kill should have been called")
  print "PASS: cli async timeout kills child"
end

-- Test: claude_code with __on_chunk switches argv to --output-format stream-json --verbose
-- and forwards model text deltas (extracted from assistant events) to user's on_chunk.
do
  local captured_argv
  vim.fn.executable = function(_) return 1 end
  vim.system = function(argv, sys_opts, on_complete)
    captured_argv = argv
    vim.schedule(function()
      -- Emit two assistant events with text and one final result event.
      sys_opts.stdout(nil, '{"type":"assistant","message":{"content":[{"type":"text","text":"hello "}]}}\n')
      sys_opts.stdout(nil, '{"type":"assistant","message":{"content":[{"type":"text","text":"world"}]}}\n')
      sys_opts.stdout(nil, '{"type":"result","result":"return function(opts) end"}\n')
      on_complete { code = 0, stdout = "", stderr = "" }
    end)
    return { kill = function() end }
  end

  local user_chunks = {}
  local p = providers.claude_code { model = "sonnet" }
  local result = p("my prompt", {
    __on_chunk = function(t) table.insert(user_chunks, t) end,
  })

  assert(result == "return function(opts) end", "extracts result from final stream-json event")
  assert(vim.list_contains(captured_argv, "stream-json"), "argv uses stream-json output format")
  assert(vim.list_contains(captured_argv, "--verbose"), "argv includes --verbose")
  assert(vim.list_contains(captured_argv, "sonnet"))
  assert(captured_argv[#captured_argv] == "my prompt")
  assert(#user_chunks == 2, "two text deltas forwarded, got: " .. #user_chunks)
  assert(user_chunks[1] == "hello ")
  assert(user_chunks[2] == "world")
  print "PASS: claude_code stream-json argv + text-delta forwarding"
end

-- Test: claude_code WITHOUT __on_chunk still uses --output-format json (sync path unchanged).
do
  local captured_argv
  vim.fn.executable = function(_) return 1 end
  vim.system = function(argv, _sys_opts)
    captured_argv = argv
    return {
      wait = function()
        return { code = 0, stdout = '{"result":"x"}', stderr = "" }
      end,
    }
  end

  local p = providers.claude_code { model = "sonnet" }
  local result = p("prompt", {})
  assert(result == "x")
  assert(vim.list_contains(captured_argv, "json"))
  assert(not vim.list_contains(captured_argv, "stream-json"))
  print "PASS: claude_code without __on_chunk stays on json path"
end
