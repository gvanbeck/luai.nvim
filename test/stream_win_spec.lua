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

-- Test: replace locks the buffer (nomodifiable) per spec.
do
  local s = stream_win.open {}
  s.replace { "final code" }
  assert(vim.bo[s.buf].modifiable == false, "buffer must be nomodifiable after replace")
  s.close()
  print "PASS: stream_win.replace locks buffer"
end

-- Test: open with geometry = { size = "corner" } opens a 70x12 window in bottom-right.
do
  local s = stream_win.open { geometry = { size = "corner" } }
  local cfg = vim.api.nvim_win_get_config(s.win)
  assert(cfg.width == 70, "width is 70, got: " .. tostring(cfg.width))
  assert(cfg.height == 12, "height is 12, got: " .. tostring(cfg.height))
  -- Bottom-right means col + width is near the right edge and row + height is near the bottom.
  assert(cfg.col + 70 <= vim.o.columns, "fits horizontally")
  assert(cfg.row + 12 <= vim.o.lines, "fits vertically")
  assert(cfg.col + 70 >= vim.o.columns - 4, "col is near right edge, got col: " .. tostring(cfg.col))
  assert(cfg.row + 12 >= vim.o.lines - 4, "row is near bottom edge, got row: " .. tostring(cfg.row))
  s.close()
  print "PASS: stream_win.open corner geometry"
end

-- Test: open with focus = false does not change the current window after opening.
do
  local before_win = vim.api.nvim_get_current_win()
  local s = stream_win.open { focus = false }
  local after_win = vim.api.nvim_get_current_win()
  assert(after_win == before_win, "focus=false leaves current window unchanged")
  s.close()
  print "PASS: stream_win.open focus=false leaves focus alone"
end

-- Test: open with winblend = 10 sets the win-local winblend option.
do
  local s = stream_win.open { winblend = 10 }
  assert(vim.wo[s.win].winblend == 10, "winblend applied, got: " .. tostring(vim.wo[s.win].winblend))
  s.close()
  print "PASS: stream_win.open winblend"
end

-- Test: open without geometry uses the existing fullsize default (80% x 80%).
do
  local s = stream_win.open {}
  local cfg = vim.api.nvim_win_get_config(s.win)
  local expected_width = math.floor(vim.o.columns * 0.8)
  local expected_height = math.floor(vim.o.lines * 0.8)
  assert(cfg.width == expected_width, "default width unchanged, got: " .. tostring(cfg.width))
  assert(cfg.height == expected_height, "default height unchanged, got: " .. tostring(cfg.height))
  s.close()
  print "PASS: stream_win.open fullsize default unchanged"
end
