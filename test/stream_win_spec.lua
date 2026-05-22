-- Run with: nvim --headless --noplugin -u NONE -l test/stream_win_spec.lua
vim.opt.rtp:append "."

local stream_win = require "luai.stream_win"
assert(type(stream_win.open) == "function", "stream_win.open must be a function")
print "PASS: stream_win module exports"
