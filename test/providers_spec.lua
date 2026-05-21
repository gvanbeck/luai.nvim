-- Run with: nvim --headless --noplugin -u NONE -l test/providers_spec.lua
vim.opt.rtp:append "."

local providers = require "luai.providers"

assert(type(providers.cli) == "function", "providers.cli must be a function")
assert(type(providers.cursor_agent) == "function", "providers.cursor_agent must be a function")
assert(type(providers.claude_code) == "function", "providers.claude_code must be a function")
print "PASS: providers module exports"
