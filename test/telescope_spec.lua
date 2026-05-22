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
