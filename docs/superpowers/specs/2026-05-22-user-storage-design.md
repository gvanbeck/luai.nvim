# User-Owned Storage for Generated Functions

**Status:** approved
**Date:** 2026-05-22

## Problem

The recently merged unified-storage refactor (spec `2026-05-22-unified-storage-design.md`) places all generated functions under `<luai-install>/lua/luai/`. In practice this means:

- For users running luai via lazy.nvim, generated files land in `~/.local/share/nvim/lazy/luai.nvim/lua/luai/` — a directory managed by the plugin manager that may be wiped on plugin update.
- Files cannot be git-tracked as part of the user's own dotfiles.
- The plugin repository accumulates user-specific content. We already committed `lua/luai/default/make_readme.lua`, `lua/luai/demo/*`, and `lua/luai/omarchy/*` into the upstream repo from this user's local generations — content that doesn't belong there.

We want generated functions to live in a user-owned, git-trackable location, with a different namespace from the plugin's own code.

## Goals

- Default storage at `stdpath('config') .. "/lua/luai_user"` (typically `~/.config/nvim/lua/luai_user`). User-owned, included automatically in `runtimepath`.
- New require namespace `luai_user.*` (not `luai.*`), so user-generated content can't shadow or collide with plugin-shipped modules.
- A single `setup({ user_storage = "..." })` knob to override the storage root. The namespace is derived from the basename of the path (last component after `/lua/`).
- The plugin repository becomes code-only. All previously-committed generated functions (`lua/luai/demo/*`, `lua/luai/omarchy/*`, `lua/luai/default/*`) are deleted in the same change.
- A README-documented migration recipe for the user's own files (one-off `cp` + a sed-style rewrite of each `init.lua` stub to reference the new namespace).

## Non-goals

- A `:LuaiBootstrap` or `:LuaiMigrate` command that automates the on-disk copy. v1 is documentation-only — the user runs `cp` once and is done.
- Backwards compatibility for the brief unified-storage window. The on-disk format is unchanged; the only difference is location + namespace prefix. Files that already exist under `<install>/lua/luai/` keep working in-place if the user manually points `user_storage` there, but the supported flow is to move them.
- Multi-namespace setups (e.g., one storage for personal, one for team). One root per nvim instance; user can switch via `setup{}` if they want.

## Design

### Setup configuration

```lua
require("luai").setup {
  -- defaults to vim.fn.stdpath("config") .. "/lua/luai_user"
  user_storage = vim.fn.stdpath("config") .. "/lua/luai_user",
  providers = {...},
  default_provider = "default",
}
```

`user_storage` MUST end in `/lua/<name>` so that `require("<name>.<sub>")` resolves through the standard Lua module path (and so the user's nvim config dir, which contains `lua/`, is already on the runtimepath). The namespace is `<name>`. `setup{}` asserts on this shape.

```lua
function M.setup(opts)
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

The mkdir is idempotent and ensures the directory exists from setup-time onward, even before any generation runs.

### Helpers

`lua/luai.lua` keeps the same helpers added in the prior refactor, but the namespace becomes dynamic:

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

local function normalize_module(name)
  local ns = namespace()
  if name == nil or name == "" then return ns .. ".default" end
  if name == ns or vim.startswith(name, ns .. ".") then return name end
  return ns .. "." .. name
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

The `luai_install_dir` and `luai_root` helpers from the prior refactor are deleted — no longer needed since storage lives outside the plugin install.

### Workflow changes

All workflows route through the helpers above; the changes from the prior unified-storage refactor stay structurally the same, only the root path and namespace shift.

#### `demand("foo").bar(opts)`

`normalize_module("foo")` returns `"luai_user.foo"`. `module_to_path("luai_user.foo", "init")` returns `<user_storage>/foo/init.lua`. Same stub-writing flow as before; the stub registers `"luai_user.foo"` via `_require_init`.

#### `generate.fn(opts)`

`Generated:__index/__newindex` call `ensure_default_module()` (which now uses the dynamic namespace) and `module_to_path(default_module(), key)`. File lands at `<user_storage>/default/<fn>.lua`.

#### `improve(module).fn = value`

Normalizes the module name and resolves via `module_to_path`. Same as before.

#### `_get_generated_modules()`

Walks `<user_storage>/*/init.lua` only. Same logic as the prior refactor's discovery, just rooted at the user-owned path instead of the plugin install.

#### `:LuaiGenerate` / `:LuaiImprove` / `:Telescope luai`

No code changes. They delegate to the affected functions and inherit the new namespace + path.

### Plugin repository cleanup

Deleted from the plugin source tree:
- `lua/luai/demo/*` (7 function files + init.lua)
- `lua/luai/omarchy/*` (2 function files + init.lua)
- `lua/luai/default/*` (1 function file + init.lua) — was committed as part of the migration; gets reverted in the same change.

After cleanup, `lua/luai/` contains only `init.lua`-equivalent code: `providers.lua`, `stream_win.lua`, `path.lua`, `win.lua`, `agent.lua`, `prompt.lua`, `prompt/`. No content.

### Migration recipe (README)

```bash
mkdir -p ~/.config/nvim/lua/luai_user

# If you had any demos or generated functions in the old <luai-install>/lua/luai/
# directory (before this change), copy them over:
cp -r ~/.local/share/nvim/lazy/luai.nvim/lua/luai/{demo,omarchy,default} \
   ~/.config/nvim/lua/luai_user/ 2>/dev/null

# Rewrite the init.lua stubs to register the new namespace:
for d in ~/.config/nvim/lua/luai_user/*/; do
  module=$(basename "$d")
  printf 'return require("luai")._require_init("luai_user.%s")\n' "$module" > "$d/init.lua"
done
```

For this user specifically: the implementation plan executes the above copy + rewrite as a one-off step on their machine before deleting the in-repo demos, so picker behaviour stays continuous.

### Data flow

```
:luafile setup
  require("luai").setup { user_storage = stdpath("config") .. "/lua/luai_user", ... }
    expand path, validate "/lua/<name>" suffix, store config._namespace = "luai_user"
    mkdir <storage>

demand("foo").bar(opts)
  normalize_module("foo")            -> "luai_user.foo"
  module_to_path(...)                -> <storage>/foo/init.lua
  if missing: write stub registering "luai_user.foo"
  require("luai_user.foo").bar(opts)
    -> _require_init metatable
    -> module_to_path -> <storage>/foo/bar.lua
    -> require + run, or generate + write + run

generate.bar(opts)
  default_module() = "luai_user.default"
  ensure_default_module()            -> <storage>/default/init.lua
  module_to_path(...)                -> <storage>/default/bar.lua
  Generated metatable + cache

:Telescope luai
  _get_generated_modules() walks <storage>/*/init.lua
  every entry namespaced "luai_user.<sub>"
```

### Error handling

| Case | Behaviour |
|---|---|
| `user_storage` path doesn't end in `/lua/<name>` | `setup{}` asserts with a clear message at config time. |
| `user_storage` path doesn't exist | `setup{}` mkdirs it (idempotent). |
| `user_storage` not writable (rare) | mkdir errors at setup with a clear filesystem message. Subsequent generations fail with the same error. |
| Discovery finds nothing | Picker opens with an empty list; existing `vim.notify "[luai] No generated modules found under the luai root."` already handles this and is reworded to "under user storage". |

### Backward compatibility

**Breaking changes**:
- Require strings change from `luai.demo.*` → `luai_user.demo.*` after migration. Any code referencing the old strings must be updated.
- After upgrade, a user who hasn't migrated sees an empty picker until they run the migration recipe.
- The previously-shipped demos are removed from the plugin install.

**Mitigations**:
- README's migration recipe is a single copy-paste block.
- The plugin's setup default points at `~/.config/nvim/lua/luai_user`, which is the spot the recipe writes to — no further config needed.

### Testing

`test/storage_spec.lua` updates:
1. After `setup{}`, `_namespace()` returns `"luai_user"`.
2. `_normalize_module("foo")` returns `"luai_user.foo"` (was `"luai.foo"`).
3. `_normalize_module(nil)` returns `"luai_user.default"`.
4. `_module_to_path("luai_user.demo", "create_window")` ends in `/lua/luai_user/demo/create_window.lua`.
5. `_module_to_path("luai_user.foo.bar", "baz")` ends in `/lua/luai_user/foo/bar/baz.lua`.
6. `setup{ user_storage = "/path/without/lua/segment" }` raises with a clear message.
7. `setup{ user_storage = "/whatever/lua/team_funcs" }` derives namespace `team_funcs`.

The other suites (providers/dispatch/agent/telescope/stream_win) need no test code changes since they don't reference the storage helpers directly. The Telescope spec's existing stub of `luai._get_generated_modules` continues to work because that interface is unchanged.

### File-impact summary

| File | Action | Approx. lines |
|---|---|---|
| `lua/luai.lua` | Modify (setup validation, dynamic namespace in helpers, drop `luai_install_dir`/`luai_root`, point root at `config.user_storage`) | +20 net |
| `lua/luai/demo/`, `lua/luai/omarchy/`, `lua/luai/default/` | **Delete** | -13 files |
| `test/storage_spec.lua` | Modify (new namespace + setup validation tests) | +25 |
| `README.md` | Rewrite "Where generated functions live" subsection + add migration recipe | +30 net |
| `~/.config/nvim/lua/luai_user/` (user machine, one-off) | Create + populate via the migration recipe | manual or scripted in the plan |

## Open questions

None — all three open points raised during brainstorming were resolved:
- Setup field name: `user_storage`.
- No `:LuaiBootstrap` command in v1 — manual recipe in README.
- `lua/luai/default/make_readme.lua` is removed alongside the demo cleanup (effectively reverts commit `0fc5e7d`).
