# Unified Storage Location for Generated Functions

**Status:** approved
**Date:** 2026-05-22

## Problem

`luai.nvim` currently writes generated functions to two different roots depending on which API the user called:

- `demand("module").fn(...)` writes to wherever `lua/<first-segment-of-module>` resolves on the runtimepath — typically the active `luai.nvim` install dir, e.g. `~/.local/share/nvim/lazy/luai.nvim/lua/luai/demo/`.
- `generate.fn(...)` writes to `stdpath("data")/luai/generated/fn.lua` — `~/.local/share/nvim/luai/generated/`.

Effects:
- Generated files end up in two unrelated trees.
- The Telescope picker (which walks runtimepath for `_require_init` markers) finds the `demand` files but misses the `generate` files entirely.
- The user has 2 stranded files (`generate_barebone_readme.lua`, `make_readme.lua`) in the stdpath root that nothing surfaces anymore.

We want **one storage root** under the active `luai.nvim` install dir, with a default-module fallback when no module is passed.

## Goals

- All workflows (`demand`, `generate`, `improve`, `:LuaiGenerate`, `:LuaiImprove`, `:Telescope luai`) write to and read from a single root.
- The root is `<luai-install>/lua/luai/`, resolved at runtime via `nvim_get_runtime_file("lua/luai/init.lua", false)`.
- Module names without a `luai.` prefix are auto-prefixed, so `demand("foo")` and `demand("luai.foo")` resolve identically.
- `generate.fn` (no module) falls back to module `luai.default`.
- Every generated function is `require`-able directly via `require("luai.<sub>.<fn>")` because everything lives under `lua/luai/`.

## Non-goals

- Auto-migration of the 2 stranded files under `stdpath("data")/luai/generated/`. README documents the manual move.
- Removal of the old `stdpath("data")/luai/generated/` directory. luai stops touching it; the user can delete it manually.
- Changing the on-disk file format (`return setmetatable({history=..., implementation=...})` stays identical).
- New configuration knobs to override the storage root in v1.

## Design

### Storage helpers

Two new module-local helpers in `lua/luai.lua`, replacing the existing `basepath` constant:

```lua
---@return string: the directory containing the active luai.nvim install (the parent of /lua/luai)
local function luai_install_dir()
  local paths = vim.api.nvim_get_runtime_file("lua/luai/init.lua", false)
  if not paths or #paths == 0 then
    error "[luai] cannot find luai install directory (lua/luai/init.lua not on runtimepath)"
  end
  return vim.fn.fnamemodify(paths[1], ":h:h:h")
end

---@return string: <install>/lua/luai — the root for all generated content
local function luai_root()
  return vim.fs.joinpath(luai_install_dir(), "lua", "luai")
end
```

`nvim_get_runtime_file` returns the first match, which is the active install. For the user's normal setup that's the lazy-managed clone. For the dev workflow with `:set rtp+=.` it's the source checkout.

### Default module constant

```lua
local DEFAULT_MODULE = "luai.default"
```

When `generate.fn` is invoked without a module context, all paths and require strings derive from this. Subdirectory: `<root>/default/`. Init stub at `<root>/default/init.lua` so `require("luai.default")` resolves.

### Module-name normalisation

```lua
---@param module? string
---@return string: a module name guaranteed to start with "luai."
local function normalize_module(module)
  if module == nil or module == "" then
    return DEFAULT_MODULE
  end
  if module == "luai" or vim.startswith(module, "luai.") then
    return module
  end
  return "luai." .. module
end
```

- `nil`/`""` → `"luai.default"`.
- `"luai"` → `"luai"` (edge case, rejected later if used as a module root).
- `"luai.demo"` → `"luai.demo"` (no double-prefix).
- `"demo"` → `"luai.demo"`.
- `"foo.bar"` → `"luai.foo.bar"`.

### Path resolution

```lua
---@param module string (normalized, starts with "luai." or equals "luai")
---@param file string: filename without extension (e.g. "init" or "create_floating_window")
---@return string: absolute filepath
local function module_to_path(module, file)
  -- module is "luai.demo" or "luai.foo.bar"; the part after "luai." is the sub-path
  local sub = module == "luai" and "" or module:sub(#"luai." + 1)
  local parts = sub == "" and {} or vim.split(sub, ".", { plain = true })
  table.insert(parts, file .. ".lua")
  return vim.fs.joinpath(luai_root(), unpack(parts))
end
```

Examples:
- `module_to_path("luai.demo", "init")` → `<root>/demo/init.lua`.
- `module_to_path("luai.default", "make_readme")` → `<root>/default/make_readme.lua`.
- `module_to_path("luai.foo.bar", "baz")` → `<root>/foo/bar/baz.lua`.

### Workflow changes

#### `demand(module).fn(opts)` (in `lua/luai.lua`)

```lua
M.demand = function(module)
  local norm = normalize_module(module)
  local init_file = module_to_path(norm, "init")
  if not vim.uv.fs_stat(init_file) then
    vim.fn.mkdir(vim.fn.fnamemodify(init_file, ":h"), "p")
    local contents = string.format([[return require("luai")._require_init(%q)]], norm)
    vim.fn.writefile({ contents }, init_file)
  end
  return require(norm)
end
```

`find_module` is removed entirely — its rtp-scanning logic is replaced by direct path construction.

#### `_require_init(module)` flow

The init stub still writes `return require("luai")._require_init("<normalized module>")`. The runtime metatable behaviour is unchanged except that `find_module(module, fn)` calls become `module_to_path(module, fn)`.

#### `M.generate.fn(opts)` (`Generated` metatable)

`get_generated_filepath(key)` now returns `module_to_path(DEFAULT_MODULE, key)`. Before any generation, the metatable ensures `<root>/default/init.lua` exists (same stub pattern as demand). The in-memory `cached[key]` table stays — it's keyed by function name and `luai.default` is the only module that uses it, so no collisions.

```lua
local function ensure_default_module()
  local init_file = module_to_path(DEFAULT_MODULE, "init")
  if not vim.uv.fs_stat(init_file) then
    vim.fn.mkdir(vim.fn.fnamemodify(init_file, ":h"), "p")
    local contents = string.format([[return require("luai")._require_init(%q)]], DEFAULT_MODULE)
    vim.fn.writefile({ contents }, init_file)
  end
end
```

`Generated:__index` and `:__newindex` both call this before any disk work.

#### `M.improve(module).fn = value` and `update_existing_generation`

`find_module(module, fn)` → `module_to_path(normalize_module(module), fn)`. Otherwise unchanged.

#### `get_generated_modules()` (used by `improve_select` and the Telescope picker)

Replaces the rtp scan with a direct walk of `<luai_root>`:

```lua
local function get_generated_modules()
  local root = luai_root()
  local items = {}
  for name, type_ in vim.fs.dir(root) do
    if type_ == "directory" then
      local init_path = vim.fs.joinpath(root, name, "init.lua")
      local stat = vim.uv.fs_stat(init_path)
      if stat then
        local lines = vim.fn.readfile(init_path)
        local module = lines[1] and lines[1]:match(generated_module_pattern)
        if module then
          table.insert(items, {
            module = module,
            dir = vim.fs.joinpath(root, name),
            init = init_path,
          })
        end
      end
    end
  end
  table.sort(items, function(l, r) return l.module < r.module end)
  return items
end
```

`generated_module_pattern` stays as-is (matches `return require("luai")._require_init("...")`). The scan is narrower than today (only `<root>/*/init.lua` instead of all of rtp), which is more deterministic and avoids picking up unrelated init files.

#### `get_generated_functions_for_module(module_item)`

Unchanged — already walks `module_item.dir` for `*.lua` files except `init.lua`.

#### `:LuaiGenerate` and `:LuaiImprove`

No code changes. They delegate to `M.generate` and `M.improve_select` and inherit the new behaviour for free.

#### `:Telescope luai`

No code changes in `lua/telescope/_extensions/luai.lua`. It calls `luai._get_generated_modules()` and `luai._get_generated_functions_for_module(m)` — both now return data from the unified root.

#### `agent.call{}`

Unchanged. Doesn't persist anything; the spec doesn't apply.

### Data flow

```
demand("foo").bar(opts)
  module = normalize_module("foo")                  → "luai.foo"
  init_file = module_to_path(module, "init")        → <root>/foo/init.lua
  if not exists: mkdir + writefile stub
  return require("luai.foo")

require("luai.foo").bar(opts)
  → _require_init("luai.foo") metatable's __index["bar"]
    path_fn = "luai.foo.bar"
    if file_exists(<root>/foo/bar.lua): require(path_fn)
    else: generate → write at <root>/foo/bar.lua → require(path_fn)

generate.bar(opts)
  ensure_default_module()                           → <root>/default/init.lua exists
  filepath = module_to_path("luai.default", "bar")  → <root>/default/bar.lua
  Generated:__index reads/generates at filepath
  cached["bar"] = { fn, stat }
```

### Backward compatibility

Files that already live under `<install>/lua/luai/demo/` and `<install>/lua/luai/omarchy/`:
- Unaffected. They were already at the right location.
- `demand("luai.demo").foo` and `demand("luai.omarchy").foo` continue to work.

Files under `stdpath("data")/luai/generated/` (`generate_barebone_readme.lua`, `make_readme.lua`):
- Become orphaned. `M.generate.generate_barebone_readme` now resolves to `<root>/default/generate_barebone_readme.lua`, which doesn't exist → triggers a fresh generation.
- README adds a "Migration" subsection with a manual `cp` recipe.

The `basepath = vim.fs.joinpath(stdpath('data'), 'luai', 'generated')` constant + the `vim.fn.mkdir(basepath, "p")` line at the top of `lua/luai.lua` are deleted. The directory and its 2 files remain on disk untouched; luai just stops referencing them.

### Error handling

| Case | Behaviour |
|---|---|
| `luai_install_dir()` returns empty (luai not on rtp) | `error("[luai] cannot find luai install directory...")` at first generation attempt. |
| `normalize_module("luai")` (root only, no submodule) | Allowed during normalisation, but `module_to_path("luai", fn)` produces `<root>/fn.lua` — writing a "function" directly into the luai root. Edge-case; demand/generate flows never pass exactly `"luai"`. |
| Mkdir on read-only luai install | Filesystem error propagates from `vim.fn.mkdir`. v1 doesn't handle this — would surface as a normal nvim error. Lazy installs are user-writable. |

### Testing

The existing spec suites mock `vim.system` and don't exercise file I/O against the luai install dir. They continue to pass without changes.

New tests in `test/storage_spec.lua`:
1. `normalize_module(nil)` → `"luai.default"`.
2. `normalize_module("")` → `"luai.default"`.
3. `normalize_module("foo")` → `"luai.foo"`.
4. `normalize_module("luai.demo")` → `"luai.demo"` (no double prefix).
5. `normalize_module("foo.bar.baz")` → `"luai.foo.bar.baz"`.
6. `module_to_path("luai.demo", "create_window")` ends with `lua/luai/demo/create_window.lua`.
7. `module_to_path("luai.default", "thing")` ends with `lua/luai/default/thing.lua`.
8. `module_to_path("luai.foo.bar", "baz")` ends with `lua/luai/foo/bar/baz.lua`.

The helpers must be exposed for testing: `M._normalize_module`, `M._module_to_path`, `M._luai_root`.

### File-impact summary

| File | Action | Approx. lines |
|---|---|---|
| `lua/luai.lua` | Major modify — replace `basepath`, add helpers, replace `find_module` callers, simplify `get_generated_modules`, expose helpers for tests. | ~80 net |
| `lua/telescope/_extensions/luai.lua` | None (it uses `luai._get_*` already). | 0 |
| `test/storage_spec.lua` | New (~50 lines, 8 helper tests). | +50 |
| `README.md` | Add "Where generated functions live" subsection + migration note. | +20 |

## Open questions

None. All three open points from brainstorming were approved:
- Default module name: `luai.default`.
- Discovery walks `<luai_root>/*/init.lua` only (no rtp scan).
- No auto-migration of the 2 stranded files — README note covers it.
