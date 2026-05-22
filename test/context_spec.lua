-- Run with: nvim --headless --noplugin -u NONE -l test/context_spec.lua
vim.opt.rtp:append "."

local ctx = require "luai.context"

-- Test: build_opts({}) returns the basic context keys, no range/selection.
do
  -- Set up a known buffer state.
  local buf = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "alpha", "beta", "gamma", "delta", "epsilon" })
  vim.api.nvim_set_current_buf(buf)
  vim.bo[buf].filetype = "lua"
  vim.api.nvim_win_set_cursor(0, { 3, 1 })

  local opts = ctx.build_opts {}
  assert(opts.bufnr == buf, "bufnr matches current")
  assert(type(opts.win) == "number", "win is a number")
  assert(type(opts.cwd) == "string" and opts.cwd ~= "", "cwd populated")
  assert(opts.cword == "gamma", "cword from line 3, got: " .. tostring(opts.cword))
  assert(opts.cursor[1] == 3, "cursor row 3")
  assert(opts.line_number == 3, "line_number 3")
  assert(opts.line == "gamma", "line text matches, got: " .. tostring(opts.line))
  assert(opts.filetype == "lua", "filetype lua")
  assert(type(opts.cfile) == "string", "cfile is a string (empty when nothing under cursor)")
  assert(opts.range == nil, "no range when not requested")
  assert(opts.selection == nil, "no selection when no range")
  print "PASS: build_opts populates basic context"
end

-- Test: with range present, range and selection are populated from the buffer.
do
  local buf = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "one", "two", "three", "four", "five" })
  vim.api.nvim_set_current_buf(buf)
  vim.api.nvim_win_set_cursor(0, { 1, 0 })

  local opts = ctx.build_opts { range_present = true, range_start = 2, range_end = 4 }
  assert(opts.range and opts.range[1] == 2 and opts.range[2] == 4, "range = {2,4}")
  assert(opts.selection == "two\nthree\nfour", "selection joined, got: " .. tostring(opts.selection))
  print "PASS: build_opts populates range + selection"
end

-- Test: line_number always equals cursor[1].
do
  local buf = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "x", "y", "z" })
  vim.api.nvim_set_current_buf(buf)
  vim.api.nvim_win_set_cursor(0, { 2, 0 })

  local opts = ctx.build_opts {}
  assert(opts.line_number == opts.cursor[1], "line_number == cursor[1]")
  print "PASS: line_number == cursor[1]"
end

-- Test: range_present = false (or absent) does not populate range/selection
-- even if range_start/range_end are provided.
do
  local buf = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "a", "b" })
  vim.api.nvim_set_current_buf(buf)

  local opts = ctx.build_opts { range_start = 1, range_end = 2, range_present = false }
  assert(opts.range == nil, "range absent when range_present=false")
  assert(opts.selection == nil, "selection absent when range_present=false")
  print "PASS: range_present=false suppresses range/selection"
end
