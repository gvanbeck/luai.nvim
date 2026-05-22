-- Run with: nvim --headless --noplugin -u NONE -l test/run_spec.lua
vim.opt.rtp:append "."

local luai = require "luai"
luai.setup { user_storage = "/tmp/luai_run_spec/lua/luai_user" }

-- Set up a buffer for all tests
local buf = vim.api.nvim_create_buf(true, false)
vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "test line 1", "test line 2", "test line 3", "test line 4" })
vim.api.nvim_set_current_buf(buf)
vim.api.nvim_win_set_cursor(0, { 1, 0 })

-- Test: shorthand "foo" resolves to <ns>.default.foo
do
  local captured_opts
  package.loaded["luai_user.default"] = {
    foo = function(opts) captured_opts = opts end,
  }

  luai.run("foo", {})

  assert(captured_opts ~= nil, "function was called")
  assert(type(captured_opts.bufnr) == "number", "auto-context was built")
  print "PASS: run shorthand routes to <ns>.default.<fn>"
end

-- Test: "module.fn" form routes to <ns>.module.fn
do
  local captured_opts
  package.loaded["luai_user.demo"] = {
    bar = function(opts) captured_opts = opts end,
  }

  luai.run("demo.bar", {})

  assert(captured_opts ~= nil, "demo.bar called")
  print "PASS: run module.fn routes to <ns>.module.fn"
end

-- Test: fully-qualified name (already namespaced) does not double-prefix
do
  local captured_opts
  package.loaded["luai_user.demo"] = {
    baz = function(opts) captured_opts = opts end,
  }

  luai.run("luai_user.demo.baz", {})

  assert(captured_opts ~= nil, "luai_user.demo.baz called")
  print "PASS: run does not double-prefix fully-qualified names"
end

-- Test: missing function raises a clear error.
do
  package.loaded["luai_user.default"] = { something_else = function() end }
  local ok, err = pcall(luai.run, "does_not_exist", {})
  assert(not ok)
  assert(err:match "function not found", "error mentions missing function: " .. tostring(err))
  assert(err:match "luai_user%.default%.does_not_exist", "error names the resolved path: " .. tostring(err))
  print "PASS: run raises clear error on missing function"
end

-- Test: range_present is forwarded to context.build_opts (i.e., opts.range gets set).
do
  local captured_opts
  package.loaded["luai_user.default"] = {
    selrun = function(opts) captured_opts = opts end,
  }

  luai.run("selrun", { range_start = 2, range_end = 4, range_present = true })
  assert(captured_opts.range and captured_opts.range[1] == 2 and captured_opts.range[2] == 4, "range forwarded")
  assert(captured_opts.selection == "test line 2\ntest line 3\ntest line 4", "selection populated, got: " .. tostring(captured_opts.selection))
  print "PASS: run forwards range/selection via context.build_opts"
end

-- Test: complete_function_names returns sorted, filtered candidates.
do
  -- Stub the discovery helpers directly on luai.
  luai._get_generated_modules = function()
    return {
      { module = "luai_user.default", dir = "/p/default", init = "/p/default/init.lua" },
      { module = "luai_user.demo", dir = "/p/demo", init = "/p/demo/init.lua" },
    }
  end
  luai._get_generated_functions_for_module = function(m)
    if m.module == "luai_user.default" then
      return { { module = "luai_user.default", fn = "make_readme", path = "/p/default/make_readme.lua" } }
    end
    return {
      { module = "luai_user.demo", fn = "alpha", path = "/p/demo/alpha.lua" },
      { module = "luai_user.demo", fn = "beta", path = "/p/demo/beta.lua" },
    }
  end

  local all = luai.complete_function_names ""
  -- Expect demo.alpha, demo.beta, default.make_readme, make_readme (bare for default).
  table.sort(all)
  assert(#all == 4, "four candidates, got: " .. #all)
  assert(all[1] == "default.make_readme")
  assert(all[2] == "demo.alpha")
  assert(all[3] == "demo.beta")
  assert(all[4] == "make_readme")

  local dem = luai.complete_function_names "dem"
  assert(#dem == 2, "two candidates with prefix 'dem': " .. #dem)
  assert(dem[1] == "demo.alpha" or dem[1] == "demo.beta")

  print "PASS: complete_function_names returns sorted, filtered candidates"
end
