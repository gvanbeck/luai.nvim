-- Run with: nvim --headless --noplugin -u NONE -l test/telescope_spec.lua
vim.opt.rtp:append "."

-- Confirm luai exposes the discovery helpers the extension needs.
local luai = require "luai"
assert(type(luai._get_generated_modules) == "function", "luai._get_generated_modules must be a function")
assert(type(luai._get_generated_functions_for_module) == "function", "luai._get_generated_functions_for_module must be a function")
assert(type(luai._read_generated_file) == "function", "luai._read_generated_file must be a function")
print "PASS: luai exposes telescope-extension discovery helpers"
