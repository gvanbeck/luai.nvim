-- Run with: nvim --headless --noplugin -u NONE -l test/dispatch_spec.lua
vim.opt.rtp:append "."

-- Stub stream_win for all tests in this file (real impl tested separately).
local stub_calls = { open = 0, last_opts = nil }
package.loaded["luai.stream_win"] = {
  open = function(o)
    stub_calls.open = stub_calls.open + 1
    stub_calls.last_opts = o
    return {
      win = 0,
      buf = 0,
      append = function() end,
      replace = function() end,
      close = function() end,
    }
  end,
}

package.loaded["luai"] = nil
local luai = require "luai"

-- Test: no providers configured -> clear error.
do
  luai.setup { providers = {} }
  local ok, err = pcall(luai._dispatch_to_provider, "prompt", {})
  assert(not ok, "dispatch must error when no providers configured")
  assert(err:match "no providers configured", "error mentions missing providers: " .. tostring(err))
  print "PASS: dispatch errors when no providers configured"
end

-- Test: default routing picks `default_provider`.
do
  local seen_name
  luai.setup {
    providers = {
      default = function(prompt, opts) seen_name = "default"; return "from-default" end,
      other = function(prompt, opts) seen_name = "other"; return "from-other" end,
    },
    default_provider = "default",
  }

  local result = luai._dispatch_to_provider("prompt", {})
  assert(result == "from-default")
  assert(seen_name == "default")
  print "PASS: dispatch picks default_provider"
end

-- Test: opts.__provider overrides default.
do
  luai.setup {
    providers = {
      default = function(_, _) return "from-default" end,
      fast = function(_, _) return "from-fast" end,
    },
    default_provider = "default",
  }

  local result = luai._dispatch_to_provider("prompt", { __provider = "fast" })
  assert(result == "from-fast", "got: " .. tostring(result))
  print "PASS: dispatch honors opts.__provider"
end

-- Test: unknown provider name -> clear error listing configured names.
do
  luai.setup {
    providers = {
      a = function(_, _) return "" end,
      b = function(_, _) return "" end,
    },
    default_provider = "a",
  }

  local ok, err = pcall(luai._dispatch_to_provider, "prompt", { __provider = "ghost" })
  assert(not ok)
  assert(err:match "unknown provider: ghost", "error names the bad provider: " .. tostring(err))
  -- Configured list is unordered; check both names are mentioned.
  assert(err:match "a" and err:match "b", "error lists configured providers: " .. tostring(err))
  print "PASS: dispatch errors on unknown provider"
end

-- Test: provider receives (prompt, opts) unchanged.
do
  local seen_prompt, seen_opts
  luai.setup {
    providers = {
      default = function(prompt, opts)
        seen_prompt = prompt
        seen_opts = opts
        return "ok"
      end,
    },
    default_provider = "default",
  }

  luai._dispatch_to_provider("the prompt", { __model = "x", foo = 1 })
  assert(seen_prompt == "the prompt")
  assert(seen_opts.__model == "x")
  assert(seen_opts.foo == 1)
  print "PASS: dispatch forwards prompt and opts unchanged"
end

-- Test: dispatch opens a stream window, sets opts.__on_chunk, and returns (result, stream).
do
  local seen_on_chunk
  luai.setup {
    providers = {
      default = function(prompt, opts)
        seen_on_chunk = opts.__on_chunk
        return "ok"
      end,
    },
    default_provider = "default",
  }

  local opens_before = stub_calls.open
  local result, stream = luai._dispatch_to_provider("prompt", {})

  assert(stub_calls.open == opens_before + 1, "stream_win.open was called")
  assert(result == "ok")
  assert(type(seen_on_chunk) == "function", "provider received a callable __on_chunk")
  assert(type(stream) == "table", "second return is the stream handle table")
  assert(type(stream.append) == "function")
  assert(type(stream.replace) == "function")
  assert(type(stream.close) == "function")
  print "PASS: dispatch opens stream and forwards __on_chunk"
end

-- Test: dispatch forwards opts.__window to stream_win.open.
do
  luai.setup {
    providers = {
      default = function(_, _) return "ok" end,
    },
    default_provider = "default",
  }

  stub_calls.last_opts = nil
  luai._dispatch_to_provider("prompt", {
    __window = { size = "corner", focus = false, winblend = 10 },
  })

  local opts = stub_calls.last_opts
  assert(type(opts) == "table", "stream_win.open received opts table")
  assert(opts.geometry and opts.geometry.size == "corner", "size = corner forwarded")
  assert(opts.focus == false, "focus = false forwarded")
  assert(opts.winblend == 10, "winblend = 10 forwarded")
  print "PASS: dispatch forwards __window to stream_win.open"
end
