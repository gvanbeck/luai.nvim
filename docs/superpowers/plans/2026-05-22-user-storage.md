# User-Owned Storage Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move generated-function storage from `<luai-install>/lua/luai/` to `stdpath('config')/lua/luai_user/` (user-configurable), with namespace `luai_user.*`, and strip the plugin repo of all committed generated functions.

**Architecture:** `setup{}` gains a `user_storage` option (default `stdpath('config') .. "/lua/luai_user"`), validates that it ends in `/lua/<name>`, derives `config._namespace` from the basename, and `mkdir`s the path. The existing helpers (`normalize_module`, `module_to_path`, `ensure_default_module`, `get_generated_modules`) switch from a hard-coded `"luai."` prefix + install-dir root to a dynamic namespace + `config.user_storage` root. The plugin's previously-committed `lua/luai/{demo,omarchy,default}/*` files are deleted; this user's existing demos are first copied into the new user-storage location and their `init.lua` stubs are rewritten to register the new namespace.

**Tech Stack:** Lua 5.1, Neovim (`vim.fn.stdpath`, `vim.fs.dir`, `vim.fs.joinpath`, `vim.fn.expand`, `vim.fn.mkdir`, `vim.api.nvim_get_runtime_file`). Tests are headless via `nvim --headless --noplugin -u NONE -l <spec>.lua`.

**Spec:** `docs/superpowers/specs/2026-05-22-user-storage-design.md`

> **Order rationale:** Task 1 migrates the user's existing files first so that after the storage swap (Tasks 2–3) the picker has something to find at the new location. Task 4 then safely deletes the now-stale copies from the plugin repo.

---

## File Structure

| File | Action | Responsibility |
|---|---|---|
| `~/.config/nvim/lua/luai_user/{demo,omarchy,default}/*` | **Create** | One-off copy from the plugin's currently-committed demos. Each subdirectory's `init.lua` registers `luai_user.<sub>` instead of `luai.<sub>`. |
| `lua/luai.lua` | **Modify** | Add `user_storage` config + setup validation + dynamic-namespace helpers. Replace `luai_install_dir`/`luai_root`/`DEFAULT_MODULE` with `storage_root`/`namespace`/`default_module`. Update all callers (`normalize_module`, `module_to_path`, `ensure_default_module`, `get_generated_modules`). Replace `M._luai_root` export with `M._namespace` and `M._storage_root`. |
| `test/storage_spec.lua` | **Modify** | Tests rewritten for `luai_user.*` namespace + setup validation. |
| `lua/luai/demo/`, `lua/luai/omarchy/`, `lua/luai/default/` | **Delete** | Plugin becomes code-only. 13 files removed. |
| `README.md` | **Modify** | Rewrite "Where generated functions live" subsection + add migration recipe. |

---

## Task 1: Migrate the user's existing files to user storage

**Files:**
- Create: `~/.config/nvim/lua/luai_user/{demo,omarchy,default}/*`

This is a one-off filesystem operation against the user's home directory. No code or test changes. It MUST happen before Tasks 2–3 swap the storage root, so the picker has content at the new location once the code change lands.

- [ ] **Step 1: Confirm source files exist in the plugin source tree**

```bash
ls /Users/gert/Projects/luai.nvim/lua/luai/demo/
ls /Users/gert/Projects/luai.nvim/lua/luai/omarchy/
ls /Users/gert/Projects/luai.nvim/lua/luai/default/
```

Expected: each shows several `.lua` files including `init.lua`. If a directory is missing, skip its copy in Step 2; don't error.

- [ ] **Step 2: Copy files to user storage**

```bash
mkdir -p ~/.config/nvim/lua/luai_user
cp -r /Users/gert/Projects/luai.nvim/lua/luai/demo \
      /Users/gert/Projects/luai.nvim/lua/luai/omarchy \
      /Users/gert/Projects/luai.nvim/lua/luai/default \
      ~/.config/nvim/lua/luai_user/ 2>/dev/null || true
```

`2>/dev/null || true` swallows errors for absent directories so this is idempotent.

- [ ] **Step 3: Rewrite each init.lua stub to register the new namespace**

```bash
for d in ~/.config/nvim/lua/luai_user/*/; do
  module=$(basename "$d")
  printf 'return require("luai")._require_init("luai_user.%s")\n' "$module" > "$d/init.lua"
done
```

- [ ] **Step 4: Verify**

```bash
ls -la ~/.config/nvim/lua/luai_user/
for d in ~/.config/nvim/lua/luai_user/*/; do
  echo "=== $(basename "$d") ==="
  cat "$d/init.lua"
done
```

Expected: three subdirectories (`demo/`, `omarchy/`, `default/`), each containing the function files + an `init.lua` that reads exactly:

```lua
return require("luai")._require_init("luai_user.<sub>")
```

where `<sub>` is the directory name.

- [ ] **Step 5: No commit**

This step is filesystem-only on the user's machine. The plugin repository is untouched. Move to Task 2.

---

## Task 2: Setup validation + dynamic namespace + helpers

**Files:**
- Modify: `lua/luai.lua`
- Modify: `test/storage_spec.lua`

This is the big code change. It introduces the new config option, validates it, derives the namespace, and updates every helper that previously used the install-dir or the hard-coded `"luai."` prefix.

- [ ] **Step 1: Replace `test/storage_spec.lua` with the new test suite**

Replace the entire contents of `test/storage_spec.lua` with:

```lua
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
```

- [ ] **Step 2: Run, confirm it fails on the new API surface**

```bash
nvim --headless --noplugin -u NONE -l test/storage_spec.lua
```

Expected: error something like `attempt to call a nil value (method '_namespace')` or `_normalize_module returns 'luai.default'` (mismatch). Various assertions fail.

- [ ] **Step 3: Update the config block at the top of `lua/luai.lua`**

Find the existing `config` block:

```lua
local config = {
  ---@type table<string, luai.Provider>
  providers = {},
  ---@type string
  default_provider = "default",
}
```

Replace with:

```lua
local config = {
  ---@type table<string, luai.Provider>
  providers = {},
  ---@type string
  default_provider = "default",
  ---@type string: path ending in `/lua/<namespace>` where generated functions live
  user_storage = vim.fn.stdpath "config" .. "/lua/luai_user",
  ---@type string: derived from the basename of user_storage by setup()
  _namespace = "luai_user",
}
```

- [ ] **Step 4: Update `M.setup` to validate user_storage and derive the namespace**

Find `M.setup`:

```lua
M.setup = function(opts)
  opts = opts or {}
  config = vim.tbl_extend("force", config, opts)
end
```

Replace with:

```lua
M.setup = function(opts)
  opts = opts or {}
  config = vim.tbl_extend("force", config, opts)
  config.user_storage = vim.fn.expand(config.user_storage)
  local ns = config.user_storage:match "/lua/([^/]+)/?$"
  assert(ns,
    "[luai] user_storage must end in /lua/<namespace>, got: " .. config.user_storage)
  config._namespace = ns
  vim.fn.mkdir(config.user_storage, "p")
end
```

- [ ] **Step 5: Replace the helpers near the top of `lua/luai.lua`**

Find the existing helper block (added in the prior refactor):

```lua
local DEFAULT_MODULE = "luai.default"

local function luai_install_dir()
  local paths = vim.api.nvim_get_runtime_file("lua/luai.lua", false)
  if not paths or #paths == 0 then
    error "[luai] cannot find luai install directory (lua/luai.lua not on runtimepath)"
  end
  return vim.fn.fnamemodify(paths[1], ":h:h")
end

local function luai_root()
  return vim.fs.joinpath(luai_install_dir(), "lua", "luai")
end

local function normalize_module(module)
  if module == nil or module == "" then
    return DEFAULT_MODULE
  end
  if module == "luai" or vim.startswith(module, "luai.") then
    return module
  end
  return "luai." .. module
end

local function module_to_path(module, file)
  local sub = module == "luai" and "" or module:sub(#"luai." + 1)
  local parts = sub == "" and {} or vim.split(sub, ".", { plain = true })
  table.insert(parts, file .. ".lua")
  return vim.fs.joinpath(luai_root(), unpack(parts))
end

local function ensure_default_module()
  local init_file = module_to_path(DEFAULT_MODULE, "init")
  if not vim.uv.fs_stat(init_file) then
    vim.fn.mkdir(vim.fn.fnamemodify(init_file, ":h"), "p")
    local contents = string.format([[return require("luai")._require_init(%q)]], DEFAULT_MODULE)
    vim.fn.writefile({ contents }, init_file)
  end
end
```

REPLACE the entire block with:

```lua
local function namespace()
  return config._namespace
end

local function storage_root()
  return config.user_storage
end

local function default_module()
  return namespace() .. ".default"
end

local function normalize_module(module)
  local ns = namespace()
  if module == nil or module == "" then
    return ns .. ".default"
  end
  if module == ns or vim.startswith(module, ns .. ".") then
    return module
  end
  return ns .. "." .. module
end

local function module_to_path(module, file)
  local ns = namespace()
  local sub = module == ns and "" or module:sub(#ns + 2) -- strip "<ns>." prefix
  local parts = sub == "" and {} or vim.split(sub, ".", { plain = true })
  table.insert(parts, file .. ".lua")
  return vim.fs.joinpath(storage_root(), unpack(parts))
end

local function ensure_default_module()
  local init_file = module_to_path(default_module(), "init")
  if not vim.uv.fs_stat(init_file) then
    vim.fn.mkdir(vim.fn.fnamemodify(init_file, ":h"), "p")
    local stub = string.format([[return require("luai")._require_init(%q)]], default_module())
    vim.fn.writefile({ stub }, init_file)
  end
end
```

Note: `luai_install_dir` and `luai_root` are gone. `DEFAULT_MODULE` constant is replaced by the `default_module()` function.

- [ ] **Step 6: Replace the underscore-exposed helpers at the bottom of `lua/luai.lua`**

Find the existing exports just before `return M`:

```lua
M._normalize_module = normalize_module
M._module_to_path = module_to_path
M._luai_root = luai_root
```

Replace with:

```lua
M._normalize_module = normalize_module
M._module_to_path = module_to_path
M._namespace = namespace
M._storage_root = storage_root
```

- [ ] **Step 7: Update `get_generated_modules` to use `storage_root()`**

Find `get_generated_modules` in `lua/luai.lua`. The current first line of the body is:

```lua
local get_generated_modules = function()
  local root = luai_root()
  ...
end
```

Change `luai_root()` to `storage_root()`:

```lua
local get_generated_modules = function()
  local root = storage_root()
  ...
end
```

Everything else in that function stays the same.

- [ ] **Step 8: Run, verify 6 PASS in storage_spec**

```bash
nvim --headless --noplugin -u NONE -l test/storage_spec.lua 2>&1 | grep -oE 'PASS:' | wc -l
```

Expected: 6.

- [ ] **Step 9: Re-run the other suites for regression**

```bash
nvim --headless --noplugin -u NONE -l test/stream_win_spec.lua 2>&1 | grep -oE 'PASS:' | wc -l
nvim --headless --noplugin -u NONE -l test/providers_spec.lua 2>&1 | grep -oE 'PASS:' | wc -l
nvim --headless --noplugin -u NONE -l test/dispatch_spec.lua 2>&1 | grep -oE 'PASS:' | wc -l
nvim --headless --noplugin -u NONE -l test/agent_spec.lua 2>&1 | grep -oE 'PASS:' | wc -l
nvim --headless --noplugin -u NONE -l test/telescope_spec.lua 2>&1 | grep -oE 'PASS:' | wc -l
```

Expected: 12, 17, 7, 7, 9.

- [ ] **Step 10: Commit**

```bash
git add lua/luai.lua test/storage_spec.lua
git commit -m "feat(luai): user-configurable storage with dynamic namespace"
```

---

## Task 3: Verify discovery walks user storage

**Files:** none (changes from Task 2 already cover this).

- [ ] **Step 1: Run an integrated smoke test against the migrated user storage**

```bash
nvim --headless --noplugin -u NONE -l - <<'EOF'
vim.opt.rtp:append "."
local luai = require "luai"
luai.setup {}  -- defaults to ~/.config/nvim/lua/luai_user
print("namespace: " .. luai._namespace())
print("root: " .. luai._storage_root())
local mods = luai._get_generated_modules()
print("modules: " .. #mods)
for _, m in ipairs(mods) do
  print("  " .. m.module .. " at " .. m.dir)
end
EOF
```

Expected output (assuming Task 1's migration succeeded):
```
namespace: luai_user
root: /Users/gert/.config/nvim/lua/luai_user
modules: 3
  luai_user.default at /Users/gert/.config/nvim/lua/luai_user/default
  luai_user.demo at /Users/gert/.config/nvim/lua/luai_user/demo
  luai_user.omarchy at /Users/gert/.config/nvim/lua/luai_user/omarchy
```

If `modules: 0`, Task 1's migration didn't land — re-run it.

- [ ] **Step 2: No commit**

This is a verification step. The code change is already committed in Task 2; this just confirms discovery is sound.

---

## Task 4: Delete plugin demos from the repository

**Files:**
- Delete: `lua/luai/demo/` (8 files including init.lua)
- Delete: `lua/luai/omarchy/` (3 files including init.lua)
- Delete: `lua/luai/default/` (2 files including init.lua)

- [ ] **Step 1: Confirm Task 1's migration is intact at the user-storage location**

```bash
ls ~/.config/nvim/lua/luai_user/demo/      | head -3
ls ~/.config/nvim/lua/luai_user/omarchy/   | head -3
ls ~/.config/nvim/lua/luai_user/default/   | head -3
```

Expected: each shows the function files (including `init.lua`) at the new location. If any is missing, STOP — re-do Task 1 first.

- [ ] **Step 2: Remove the directories from the plugin source tree**

```bash
git rm -r lua/luai/demo lua/luai/omarchy lua/luai/default
```

(Using `git rm -r` so the deletions are staged automatically.)

- [ ] **Step 3: Run all 6 spec suites — no regressions, since none of them depend on the deleted files**

```bash
nvim --headless --noplugin -u NONE -l test/storage_spec.lua 2>&1 | grep -oE 'PASS:' | wc -l
nvim --headless --noplugin -u NONE -l test/stream_win_spec.lua 2>&1 | grep -oE 'PASS:' | wc -l
nvim --headless --noplugin -u NONE -l test/providers_spec.lua 2>&1 | grep -oE 'PASS:' | wc -l
nvim --headless --noplugin -u NONE -l test/dispatch_spec.lua 2>&1 | grep -oE 'PASS:' | wc -l
nvim --headless --noplugin -u NONE -l test/agent_spec.lua 2>&1 | grep -oE 'PASS:' | wc -l
nvim --headless --noplugin -u NONE -l test/telescope_spec.lua 2>&1 | grep -oE 'PASS:' | wc -l
```

Expected: 6, 12, 17, 7, 7, 9. Total 58 PASS.

- [ ] **Step 4: Confirm `lua/luai/` only contains code now**

```bash
ls lua/luai/
```

Expected: `agent.lua`, `path.lua`, `prompt/`, `prompt.lua`, `providers.lua`, `stream_win.lua`, `win.lua`. No `demo/`, `omarchy/`, `default/`.

- [ ] **Step 5: Commit**

```bash
git commit -m "refactor(luai): plugin repo becomes code-only, shipped demos removed"
```

---

## Task 5: README — rewrite storage subsection + add migration recipe

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Replace the existing storage subsection**

Open `README.md`. Find the `### Where generated functions live` subsection (under `## Setup`). The current content (after the merge of the prior refactor) starts with `All generated functions are stored under the active luai.nvim install directory...`. Replace the ENTIRE subsection (from the heading through the migration recipe block) with:

````markdown
### Where generated functions live

All generated functions are stored under a user-owned path you control. The default is:

```
~/.config/nvim/lua/luai_user/<module>/<function>.lua
```

Files there are part of your nvim config tree, so they're git-trackable in your dotfiles. The require namespace is derived from the path's last segment (`luai_user` by default), and functions resolve as `require("luai_user.<module>.<fn>")`.

Override the location via `setup{}`:

```lua
require("luai").setup {
  user_storage = vim.fn.stdpath("config") .. "/lua/luai_user",  -- default
  providers = { ... },
  default_provider = "default",
}
```

The path must end in `/lua/<namespace>` so the standard Lua module path resolves it (your nvim config dir is already on the runtimepath). Whatever you choose for `<namespace>` becomes the prefix users will type with `demand("<sub>")` (auto-prefixed to `<namespace>.<sub>`).

Module names you pass to `demand(...)` are auto-prefixed with the namespace if absent:
- `demand("demo")` → `~/.config/nvim/lua/luai_user/demo/`
- `demand("luai_user.demo")` → same path (no double-prefix)
- `demand("foo.bar")` → `~/.config/nvim/lua/luai_user/foo/bar/`

The `M.generate.fn(...)` API has no module, so its files land under `<namespace>.default` at `~/.config/nvim/lua/luai_user/default/<fn>.lua`.

#### Migrating from earlier luai releases

Earlier luai releases either shipped demos under the plugin's own `lua/luai/{demo,omarchy,default}/` or wrote `M.generate` files to `~/.local/share/nvim/luai/generated/`. To bring any of those into the new user-owned location:

```bash
mkdir -p ~/.config/nvim/lua/luai_user

# If you have shipped demos in the plugin install (older versions only):
cp -r ~/.local/share/nvim/lazy/luai.nvim/lua/luai/demo \
      ~/.local/share/nvim/lazy/luai.nvim/lua/luai/omarchy \
      ~/.config/nvim/lua/luai_user/ 2>/dev/null

# If you have functions under the older stdpath('data') location:
cp ~/.local/share/nvim/luai/generated/*.lua \
   ~/.config/nvim/lua/luai_user/default/ 2>/dev/null

# Rewrite each init.lua so it registers the luai_user.* namespace:
for d in ~/.config/nvim/lua/luai_user/*/; do
  module=$(basename "$d")
  printf 'return require("luai")._require_init("luai_user.%s")\n' "$module" > "$d/init.lua"
done
```

After migration the picker and `M.generate.<name>` resolve normally and your functions live in your own dotfiles tree.
````

- [ ] **Step 2: Commit**

```bash
git add README.md
git commit -m "docs: user-owned storage + migration recipe"
```

---

## Task 6: Final verification

**Files:** none

- [ ] **Step 1: All spec suites pass**

```bash
nvim --headless --noplugin -u NONE -l test/storage_spec.lua 2>&1 | grep -oE 'PASS:' | wc -l
nvim --headless --noplugin -u NONE -l test/stream_win_spec.lua 2>&1 | grep -oE 'PASS:' | wc -l
nvim --headless --noplugin -u NONE -l test/providers_spec.lua 2>&1 | grep -oE 'PASS:' | wc -l
nvim --headless --noplugin -u NONE -l test/dispatch_spec.lua 2>&1 | grep -oE 'PASS:' | wc -l
nvim --headless --noplugin -u NONE -l test/agent_spec.lua 2>&1 | grep -oE 'PASS:' | wc -l
nvim --headless --noplugin -u NONE -l test/telescope_spec.lua 2>&1 | grep -oE 'PASS:' | wc -l
```

Expected: 6, 12, 17, 7, 7, 9. Total 58 PASS.

- [ ] **Step 2: Plugin source tree is code-only**

```bash
find lua/luai/ -maxdepth 1 -type d
```

Expected: only `lua/luai/` itself and `lua/luai/prompt/` (the prompt sub-module dir). NO `demo/`, `omarchy/`, `default/`.

- [ ] **Step 3: User-storage discovery works end-to-end**

```bash
nvim --headless --noplugin -u NONE -l - <<'EOF'
vim.opt.rtp:append "."
local luai = require "luai"
luai.setup {}
local mods = luai._get_generated_modules()
print("modules: " .. #mods)
for _, m in ipairs(mods) do print("  " .. m.module) end
EOF
```

Expected: 3 modules listed — `luai_user.default`, `luai_user.demo`, `luai_user.omarchy`.

- [ ] **Step 4: `lua/luai.lua` has no leftover references to the old helpers**

```bash
grep -nE 'luai_install_dir|luai_root|DEFAULT_MODULE\b' lua/luai.lua
```

Expected: no output.

- [ ] **Step 5: Branch history is coherent**

```bash
git log --oneline master..HEAD
git diff master --stat
```

Expected: 3 commits on the branch (Task 2 code, Task 4 deletions, Task 5 README). File impact:
- `lua/luai.lua` modified.
- `test/storage_spec.lua` modified.
- `README.md` modified.
- `lua/luai/{demo,omarchy,default}/*` deleted (13 files).

- [ ] **Step 6: Parse-check `test/manual.lua`**

```bash
nvim --headless --noplugin -u NONE \
  -c 'lua local f, err = loadfile("test/manual.lua"); print(err and ("ERROR: " .. err) or "OK")' \
  -c 'qa'
```

Expected: `OK`.
