-- Run with: nvim --headless --noplugin -u NONE -l test/dispatch_spec.lua
vim.opt.rtp:append "."

package.loaded["luai"] = nil
local luai = require "luai"

-- Test: no providers configured -> clear error.
do
  luai.setup {}
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
