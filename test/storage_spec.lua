-- Run with: nvim --headless --noplugin -u NONE -l test/storage_spec.lua
vim.opt.rtp:append "."

local luai = require "luai"

-- Default setup derives namespace "luai_user" from stdpath('config')/lua/luai_user.
do
  luai.setup {}
  assert(luai._namespace() == "luai_user", "default namespace, got: " .. tostring(luai._namespace()))
  local root = luai._storage_root()
  assert(root:match "/lua/luai_user$", "default root ends in /lua/luai_user, got: " .. root)
  print "PASS: setup derives default namespace luai_user"
end

-- Custom user_storage with valid /lua/<name> suffix derives custom namespace.
do
  luai.setup { user_storage = "/tmp/luai_spec/lua/team_funcs" }
  assert(luai._namespace() == "team_funcs", "custom namespace, got: " .. tostring(luai._namespace()))
  assert(luai._storage_root() == "/tmp/luai_spec/lua/team_funcs", "custom root, got: " .. luai._storage_root())
  print "PASS: custom user_storage derives namespace from basename"
end

-- Invalid user_storage (no /lua/<name> suffix) raises an assertion error.
do
  local ok, err = pcall(luai.setup, { user_storage = "/tmp/no_lua_segment" })
  assert(not ok)
  assert(err:match "user_storage must end in /lua/", "error mentions the requirement: " .. tostring(err))
  print "PASS: invalid user_storage path raises clear error"
end

-- normalize_module honours the current namespace.
do
  luai.setup { user_storage = "/tmp/luai_spec/lua/luai_user" }
  assert(luai._normalize_module(nil) == "luai_user.default", "nil -> namespace.default")
  assert(luai._normalize_module "" == "luai_user.default", "empty -> namespace.default")
  assert(luai._normalize_module "demo" == "luai_user.demo", "auto-prefix")
  assert(luai._normalize_module "luai_user.demo" == "luai_user.demo", "no double-prefix")
  assert(luai._normalize_module "luai_user" == "luai_user", "root unchanged")
  assert(luai._normalize_module "foo.bar.baz" == "luai_user.foo.bar.baz", "deep path prefixed")
  print "PASS: normalize_module uses dynamic namespace"
end

-- module_to_path resolves paths under storage_root.
do
  luai.setup { user_storage = "/tmp/luai_spec/lua/luai_user" }
  local p_demo = luai._module_to_path("luai_user.demo", "create_window")
  assert(p_demo == "/tmp/luai_spec/lua/luai_user/demo/create_window.lua", "got: " .. p_demo)
  local p_default = luai._module_to_path("luai_user.default", "thing")
  assert(p_default == "/tmp/luai_spec/lua/luai_user/default/thing.lua", "got: " .. p_default)
  local p_deep = luai._module_to_path("luai_user.foo.bar", "baz")
  assert(p_deep == "/tmp/luai_spec/lua/luai_user/foo/bar/baz.lua", "got: " .. p_deep)
  print "PASS: module_to_path resolves under storage_root"
end

-- Changing namespace via setup changes the path too.
do
  luai.setup { user_storage = "/tmp/team_root/lua/myfns" }
  local p = luai._module_to_path("myfns.greetings", "hello")
  assert(p == "/tmp/team_root/lua/myfns/greetings/hello.lua", "got: " .. p)
  print "PASS: module_to_path follows reconfigured namespace"
end
