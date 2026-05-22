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

-- Test: pick({}) calls pickers.new with the expected finder, sorter, previewer, and attach_mappings.
do
  -- Reuse the luai stub from the previous test (still in package.loaded).

  local captured_picker_opts, captured_picker_cfg, find_called
  package.loaded["telescope.pickers"] = {
    new = function(opts, cfg)
      captured_picker_opts = opts
      captured_picker_cfg = cfg
      return { find = function() find_called = true end }
    end,
  }
  package.loaded["telescope.finders"] = {
    new_table = function(o) return { _finder = true, source = o } end,
  }
  package.loaded["telescope.config"] = {
    values = {
      generic_sorter = function(_o) return "<sorter>" end,
    },
  }
  package.loaded["telescope.previewers"] = {
    new_buffer_previewer = function(o) return { _previewer = true, source = o } end,
  }
  package.loaded["telescope.actions"] = {
    select_default = { replace = function(_, _fn) end },
    close = function() end,
  }
  package.loaded["telescope.actions.state"] = {
    get_selected_entry = function() return nil end,
  }

  -- Re-stub telescope and reload extension.
  package.loaded["telescope"] = {
    register_extension = function(spec) return spec end,
  }
  package.loaded["telescope._extensions.luai"] = nil
  local ext = require "telescope._extensions.luai"

  ext.exports.run {}

  assert(captured_picker_opts ~= nil, "pickers.new received opts")
  assert(captured_picker_cfg.prompt_title == "luai functions", "prompt_title set")
  assert(captured_picker_cfg.finder._finder, "finder is a finders.new_table")
  assert(#captured_picker_cfg.finder.source.results == 2, "two items in finder")
  assert(captured_picker_cfg.sorter == "<sorter>", "sorter from conf.values")
  assert(captured_picker_cfg.previewer._previewer, "previewer is a buffer previewer")
  assert(type(captured_picker_cfg.attach_mappings) == "function", "attach_mappings is a function")
  assert(find_called, "picker:find() was called")
  print "PASS: pick wires picker with finder, sorter, previewer, attach_mappings"
end

-- Test: entry_maker formats display "module.fn — description" and ordinal "module.fn".
do
  -- Same stubs as above; just verify the entry_maker output for one item.
  local finder
  package.loaded["telescope.finders"] = {
    new_table = function(o) finder = o; return o end,
  }

  package.loaded["telescope"] = { register_extension = function(spec) return spec end }
  package.loaded["telescope._extensions.luai"] = nil
  local ext = require "telescope._extensions.luai"
  ext.exports.run {}

  -- Find the alpha item and run its entry_maker.
  local alpha
  for _, it in ipairs(finder.results) do
    if it.module == "alpha" then alpha = it end
  end
  assert(alpha, "alpha item present in finder results")

  local entry = finder.entry_maker(alpha)
  assert(entry.value == alpha, "entry.value points at the source item")
  assert(entry.ordinal == "alpha.do_thing", "ordinal is module.fn")
  assert(entry.display:find "alpha.do_thing", "display includes module.fn")
  assert(entry.display:find "do a thing", "display includes description snippet")
  assert(entry.path == "/p/alpha/do_thing.lua", "entry.path is the source path")

  -- And beta (no description) gets just module.fn.
  local beta
  for _, it in ipairs(finder.results) do
    if it.module == "beta" then beta = it end
  end
  local beta_entry = finder.entry_maker(beta)
  assert(beta_entry.display == "beta.noop", "no description -> display is just module.fn")
  print "PASS: entry_maker formats display and ordinal"
end
