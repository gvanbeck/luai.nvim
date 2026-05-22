-- Run with: nvim --headless --noplugin -u NONE -l test/stream_win_spec.lua
vim.opt.rtp:append "."

local stream_win = require "luai.stream_win"
assert(type(stream_win.open) == "function", "stream_win.open must be a function")
print "PASS: stream_win module exports"

-- Test: open() returns a table with win, buf, and 3 functions; buf starts with one empty line.
do
  local s = stream_win.open { title = "test" }
  assert(type(s.win) == "number", "win is a number")
  assert(type(s.buf) == "number", "buf is a number")
  assert(type(s.append) == "function")
  assert(type(s.replace) == "function")
  assert(type(s.close) == "function")
  assert(vim.api.nvim_buf_line_count(s.buf) == 1, "fresh buffer has one empty line")
  s.close()
  print "PASS: stream_win.open shape"
end

-- Test: append handles partial line (no trailing newline) — appends to the last line in place.
do
  local s = stream_win.open {}
  s.append "hello"
  local lines = vim.api.nvim_buf_get_lines(s.buf, 0, -1, false)
  assert(#lines == 1, "one line after partial chunk")
  assert(lines[1] == "hello", "got: " .. tostring(lines[1]))
  s.close()
  print "PASS: stream_win.append partial line"
end

-- Test: append concatenates further partials onto the same line.
do
  local s = stream_win.open {}
  s.append "hello "
  s.append "world"
  local lines = vim.api.nvim_buf_get_lines(s.buf, 0, -1, false)
  assert(#lines == 1)
  assert(lines[1] == "hello world", "got: " .. tostring(lines[1]))
  s.close()
  print "PASS: stream_win.append concatenates partials"
end

-- Test: append with embedded newline splits into new lines.
do
  local s = stream_win.open {}
  s.append "first\nsecond\nthird"
  local lines = vim.api.nvim_buf_get_lines(s.buf, 0, -1, false)
  assert(#lines == 3, "got " .. #lines .. " lines")
  assert(lines[1] == "first")
  assert(lines[2] == "second")
  assert(lines[3] == "third")
  s.close()
  print "PASS: stream_win.append splits on newline"
end

-- Test: replace overwrites the entire buffer with the given lines array.
do
  local s = stream_win.open {}
  s.append "garbage"
  s.replace { "clean", "code", "here" }
  local lines = vim.api.nvim_buf_get_lines(s.buf, 0, -1, false)
  assert(#lines == 3)
  assert(lines[1] == "clean")
  assert(lines[2] == "code")
  assert(lines[3] == "here")
  s.close()
  print "PASS: stream_win.replace overwrites"
end

-- Test: close deletes the window and buffer.
do
  local s = stream_win.open {}
  s.close()
  assert(not vim.api.nvim_win_is_valid(s.win), "window is invalid after close")
  assert(not vim.api.nvim_buf_is_valid(s.buf), "buffer is invalid after close")
  print "PASS: stream_win.close destroys win and buf"
end
