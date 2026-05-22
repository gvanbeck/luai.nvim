-- Run with: nvim --headless --noplugin -u NONE -l test/telescope_spec.lua
vim.opt.rtp:append "."

-- Confirm luai exposes the discovery helpers the extension needs.
local luai = require "luai"
assert(type(luai._get_generated_modules) == "function", "luai._get_generated_modules must be a function")
assert(type(luai._get_generated_functions_for_module) == "function", "luai._get_generated_functions_for_module must be a function")
assert(type(luai._read_generated_file) == "function", "luai._read_generated_file must be a function")
print "PASS: luai exposes telescope-extension discovery helpers"

-- Test: loading the extension file invokes telescope.register_extension and returns
-- a spec table with `run` and `luai` callable exports.
do
  -- Stub telescope at the module-level just for this test.
  local captured_spec
  package.loaded["telescope"] = {
    register_extension = function(spec)
      captured_spec = spec
      return spec
    end,
  }

  -- Force a fresh load of the extension.
  package.loaded["telescope._extensions.luai"] = nil
  local ext = require "telescope._extensions.luai"

  assert(captured_spec ~= nil, "register_extension was called")
  assert(type(ext.exports) == "table", "ext.exports exists")
  assert(type(ext.exports.run) == "function", "exports.run is callable")
  assert(type(ext.exports.luai) == "function", "exports.luai is callable")
  assert(ext.exports.run == ext.exports.luai, "run and luai point at the same picker")
  print "PASS: extension registers and exports run/luai"
end

-- Test: build_items collects every generated function across modules and hydrates
-- it with option_example + description from the history's latest entry.
do
  -- Stub luai discovery for this test. The stub returns a fixed scenario:
  --   module "alpha" has fn "do_thing" with an opts example and a description.
  --   module "beta"  has fn "noop" with NO option_example and an empty description.
  package.loaded["luai"] = {
    _get_generated_modules = function()
      return {
        { module = "alpha", dir = "/p/alpha", init = "/p/alpha/init.lua" },
        { module = "beta",  dir = "/p/beta",  init = "/p/beta/init.lua" },
      }
    end,
    _get_generated_functions_for_module = function(m)
      if m.module == "alpha" then
        return { { module = "alpha", fn = "do_thing", path = "/p/alpha/do_thing.lua" } }
      end
      return { { module = "beta", fn = "noop", path = "/p/beta/noop.lua" } }
    end,
    _read_generated_file = function(path)
      if path:find "do_thing" then
        return {
          history = {
            { option_example = { x = 1 }, description = "do a thing" },
          },
        }
      end
      return { history = { {} } }
    end,
  }
  -- Re-stub telescope.register_extension (previous test consumed the stub).
  package.loaded["telescope"] = {
    register_extension = function(spec) return spec end,
  }
  package.loaded["telescope._extensions.luai"] = nil
  local ext = require "telescope._extensions.luai"
  local items = ext._build_items()

  assert(#items == 2, "two items, got: " .. #items)

  -- Find each item by module+fn (order isn't guaranteed in general).
  local by_key = {}
  for _, it in ipairs(items) do
    by_key[it.module .. "." .. it.fn] = it
  end

  local alpha = by_key["alpha.do_thing"]
  assert(alpha, "alpha.do_thing in items")
  assert(alpha.path == "/p/alpha/do_thing.lua")
  assert(alpha.option_example.x == 1)
  assert(alpha.description == "do a thing")

  local beta = by_key["beta.noop"]
  assert(beta, "beta.noop in items")
  assert(beta.option_example == nil, "beta has no option_example")
  assert(beta.description == "")
  print "PASS: build_items discovers and hydrates"
end
