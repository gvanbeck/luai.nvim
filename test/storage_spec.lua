-- Run with: nvim --headless --noplugin -u NONE -l test/storage_spec.lua
vim.opt.rtp:append "."

local luai = require "luai"

-- normalize_module tests
do
  assert(luai._normalize_module(nil) == "luai.default", "nil -> default")
  assert(luai._normalize_module "" == "luai.default", "empty -> default")
  assert(luai._normalize_module "demo" == "luai.demo", "demo -> luai.demo")
  assert(luai._normalize_module "luai.demo" == "luai.demo", "luai.demo unchanged")
  assert(luai._normalize_module "luai" == "luai", "luai unchanged")
  assert(luai._normalize_module "foo.bar.baz" == "luai.foo.bar.baz", "deep path prefixed")
  print "PASS: normalize_module covers nil/empty/short/long/already-prefixed/root"
end

-- module_to_path tests
do
  local root = luai._luai_root()
  assert(type(root) == "string" and root ~= "", "luai_root is a non-empty string")

  local p_demo = luai._module_to_path("luai.demo", "create_window")
  assert(p_demo:match "/lua/luai/demo/create_window%.lua$", "got: " .. p_demo)

  local p_default = luai._module_to_path("luai.default", "thing")
  assert(p_default:match "/lua/luai/default/thing%.lua$", "got: " .. p_default)

  local p_deep = luai._module_to_path("luai.foo.bar", "baz")
  assert(p_deep:match "/lua/luai/foo/bar/baz%.lua$", "got: " .. p_deep)

  local p_init = luai._module_to_path("luai.demo", "init")
  assert(p_init:match "/lua/luai/demo/init%.lua$", "init.lua suffix")
  print "PASS: module_to_path resolves submodule, default, deep, and init"
end
