# Unified Storage Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move every generated luai function under a single root `<active-luai-install>/lua/luai/`, auto-prefix module names with `luai.`, and fall back to module `luai.default` when no module is given (so `generate.fn` no longer writes to `stdpath('data')/luai/generated`).

**Architecture:** Two new module-local helpers in `lua/luai.lua` — `luai_install_dir()` (resolves via `nvim_get_runtime_file("lua/luai.lua", false)`) and `luai_root()` (joins `/lua/luai`). All call sites that previously used `find_module` or `get_generated_filepath` are migrated to a unified `module_to_path(normalize_module(name), fn)` pipeline. Discovery (`get_generated_modules`) walks `<luai_root>/*/init.lua` directly instead of scanning the runtimepath. The old `basepath`, `find_module`, and `get_generated_filepath` are deleted once nothing references them.

**Tech Stack:** Lua 5.1, Neovim runtime (`vim.api.nvim_get_runtime_file`, `vim.fs.dir`, `vim.fs.joinpath`, `vim.split`, `vim.startswith`, `vim.uv.fs_stat`). Tests are headless via `nvim --headless --noplugin -u NONE -l <spec>.lua`; storage helpers are pure Lua + Neovim API so they test without stubs.

**Spec:** `docs/superpowers/specs/2026-05-22-unified-storage-design.md`

> **Note on spec correction:** The spec mentions `lua/luai/init.lua` as the runtime-file marker. The actual canonical file is `lua/luai.lua` (the top-level entry point — there is no `lua/luai/init.lua`). This plan uses `lua/luai.lua`.

---

## File Structure

| File | Action | Responsibility |
|---|---|---|
| `lua/luai.lua` | **Modify** | Add helpers (`luai_install_dir`, `luai_root`, `normalize_module`, `module_to_path`, `ensure_default_module`, `DEFAULT_MODULE`). Migrate `demand`, `_require_init`, `Generated:__index/__newindex`, `update_existing_generation`, `improve`, and `get_generated_modules`. Delete `basepath`, `find_module`, `get_generated_filepath` once unreferenced. Expose `_normalize_module` / `_module_to_path` / `_luai_root` for tests. |
| `test/storage_spec.lua` | **Create** | Eight pure-Lua tests covering `normalize_module` and `module_to_path`. |
| `README.md` | **Modify** | New "Where generated functions live" subsection (storage path + manual migration recipe for the 2 stranded files under `stdpath('data')/luai/generated/`). |
| `lua/telescope/_extensions/luai.lua` | **No change** | Already routes through `luai._get_generated_modules` / `_get_generated_functions_for_module` / `_read_generated_file`. Picks up the new discovery semantics for free. |

---

## Task 1: Add storage helpers + their tests

**Files:**
- Modify: `lua/luai.lua`
- Create: `test/storage_spec.lua`

- [ ] **Step 1: Write the failing tests**

Create `test/storage_spec.lua`:

```lua
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
  -- Path assertions are suffix-based so they survive different repo locations.
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
```

- [ ] **Step 2: Run, confirm failure**

```bash
nvim --headless --noplugin -u NONE -l test/storage_spec.lua
```

Expected: error `attempt to call a nil value (method '_normalize_module')` or similar — luai doesn't expose these yet.

- [ ] **Step 3: Add the helpers to `lua/luai.lua`**

Open `lua/luai.lua`. Find the existing `basepath` line near the top (right after `local config = {...}`):

```lua
-- Basepath for generated functions from luai, that are not from `demand(...)`
local basepath = vim.fs.joinpath(vim.fn.stdpath "data" --[[@as string]], "luai", "generated")
vim.fn.mkdir(basepath, "p")
```

Leave `basepath` alone for now (Task 7 deletes it). Immediately **after** the `basepath` block, add:

```lua
local DEFAULT_MODULE = "luai.default"

---@return string: the directory containing the active luai.nvim install (parent of /lua)
local function luai_install_dir()
  local paths = vim.api.nvim_get_runtime_file("lua/luai.lua", false)
  if not paths or #paths == 0 then
    error "[luai] cannot find luai install directory (lua/luai.lua not on runtimepath)"
  end
  return vim.fn.fnamemodify(paths[1], ":h:h")
end

---@return string: <install>/lua/luai — the root for all generated content
local function luai_root()
  return vim.fs.joinpath(luai_install_dir(), "lua", "luai")
end

---@param module? string
---@return string: a module name guaranteed to start with "luai." (or be exactly "luai")
local function normalize_module(module)
  if module == nil or module == "" then
    return DEFAULT_MODULE
  end
  if module == "luai" or vim.startswith(module, "luai.") then
    return module
  end
  return "luai." .. module
end

---@param module string: normalized module (starts with "luai." or equals "luai")
---@param file string: filename without extension (e.g. "init", "create_window")
---@return string: absolute filepath under <luai_root>
local function module_to_path(module, file)
  local sub = module == "luai" and "" or module:sub(#"luai." + 1)
  local parts = sub == "" and {} or vim.split(sub, ".", { plain = true })
  table.insert(parts, file .. ".lua")
  return vim.fs.joinpath(luai_root(), unpack(parts))
end

---Ensure the default module's init.lua exists so `require("luai.default.<fn>")` resolves.
local function ensure_default_module()
  local init_file = module_to_path(DEFAULT_MODULE, "init")
  if not vim.uv.fs_stat(init_file) then
    vim.fn.mkdir(vim.fn.fnamemodify(init_file, ":h"), "p")
    local contents = string.format([[return require("luai")._require_init(%q)]], DEFAULT_MODULE)
    vim.fn.writefile({ contents }, init_file)
  end
end
```

Then at the END of the file, just before `return M`, add the test-facing exports:

```lua
M._normalize_module = normalize_module
M._module_to_path = module_to_path
M._luai_root = luai_root
```

(Put them next to the existing `M._dispatch_to_provider`, `M._get_generated_modules`, etc. — same pattern.)

- [ ] **Step 4: Run, verify both blocks pass**

```bash
nvim --headless --noplugin -u NONE -l test/storage_spec.lua 2>&1 | grep -oE 'PASS:' | wc -l
```

Expected: 2 PASS lines, exit 0.

- [ ] **Step 5: Re-run other suites to confirm no regression**

```bash
nvim --headless --noplugin -u NONE -l test/stream_win_spec.lua 2>&1 | grep -oE 'PASS:' | wc -l
nvim --headless --noplugin -u NONE -l test/providers_spec.lua 2>&1 | grep -oE 'PASS:' | wc -l
nvim --headless --noplugin -u NONE -l test/dispatch_spec.lua 2>&1 | grep -oE 'PASS:' | wc -l
nvim --headless --noplugin -u NONE -l test/agent_spec.lua 2>&1 | grep -oE 'PASS:' | wc -l
nvim --headless --noplugin -u NONE -l test/telescope_spec.lua 2>&1 | grep -oE 'PASS:' | wc -l
```

Expected: 12, 17, 7, 7, 9.

- [ ] **Step 6: Commit**

```bash
git add lua/luai.lua test/storage_spec.lua
git commit -m "feat(luai): storage helpers — luai_root, module_to_path, normalize_module"
```

---

## Task 2: Migrate `M.demand` to the new helpers

**Files:**
- Modify: `lua/luai.lua`

- [ ] **Step 1: Locate `M.demand` and update it**

In `lua/luai.lua`, find `M.demand`. It currently reads:

```lua
M.demand = function(module)
  -- generate: lua/luai/utils/init.lua
  -- generate: lua/luai/utils/split_string_on_vowels.lua
  local init_file = find_module(module, "init")

  -- If we haven't generated the init file, then we need to generate it.
  if not vim.uv.fs_stat(init_file) then
    vim.fn.mkdir(vim.fn.fnamemodify(init_file, ":h"), "p")
    local contents = string.format([[return require("luai")._require_init("%s")]], module)
    vim.fn.writefile({ contents }, init_file)
  end

  return require(module)
end
```

REPLACE with:

```lua
M.demand = function(module)
  local norm = normalize_module(module)
  local init_file = module_to_path(norm, "init")

  -- Generate the init stub on first use.
  if not vim.uv.fs_stat(init_file) then
    vim.fn.mkdir(vim.fn.fnamemodify(init_file, ":h"), "p")
    local contents = string.format([[return require("luai")._require_init(%q)]], norm)
    vim.fn.writefile({ contents }, init_file)
  end

  return require(norm)
end
```

Behaviour changes:
- `demand("foo")` now writes `<root>/foo/init.lua` (not `<rtp>/lua/foo/init.lua`).
- `demand("luai.foo")` writes to the same place (no double-prefix).
- The stub uses `%q` instead of `%s` so quotes/backslashes in module names are escaped properly.
- `require(norm)` returns `require("luai.foo")` (not `require("foo")`).

- [ ] **Step 2: Run all spec suites — no regressions expected**

```bash
nvim --headless --noplugin -u NONE -l test/storage_spec.lua 2>&1 | grep -oE 'PASS:' | wc -l
nvim --headless --noplugin -u NONE -l test/stream_win_spec.lua 2>&1 | grep -oE 'PASS:' | wc -l
nvim --headless --noplugin -u NONE -l test/providers_spec.lua 2>&1 | grep -oE 'PASS:' | wc -l
nvim --headless --noplugin -u NONE -l test/dispatch_spec.lua 2>&1 | grep -oE 'PASS:' | wc -l
nvim --headless --noplugin -u NONE -l test/agent_spec.lua 2>&1 | grep -oE 'PASS:' | wc -l
nvim --headless --noplugin -u NONE -l test/telescope_spec.lua 2>&1 | grep -oE 'PASS:' | wc -l
```

Expected: 2, 12, 17, 7, 7, 9.

- [ ] **Step 3: Commit**

```bash
git add lua/luai.lua
git commit -m "feat(luai): demand uses module_to_path + auto-prefixes 'luai.'"
```

---

## Task 3: Migrate `_require_init` generation closure

**Files:**
- Modify: `lua/luai.lua`

- [ ] **Step 1: Update the generation closure inside `_require_init`**

Find `M._require_init` in `lua/luai.lua`. The generation closure inside it currently reads:

```lua
return function(options)
  local filepath = find_module(module, key)

  local new_function, stream = generate_new_function {
    function_name = key,
    options = options,
  }
  store_new_function(filepath, key, new_function)
  stream.close()

  return require(path_fn)(options)
end
```

REPLACE the `find_module` line:

```lua
return function(options)
  local filepath = module_to_path(module, key)

  local new_function, stream = generate_new_function {
    function_name = key,
    options = options,
  }
  store_new_function(filepath, key, new_function)
  stream.close()

  return require(path_fn)(options)
end
```

`module` here is already normalized — it came from the init.lua stub which Task 2's `demand` writes with the normalized form.

- [ ] **Step 2: Re-run spec suites — same counts as Task 2**

```bash
nvim --headless --noplugin -u NONE -l test/storage_spec.lua 2>&1 | grep -oE 'PASS:' | wc -l
nvim --headless --noplugin -u NONE -l test/telescope_spec.lua 2>&1 | grep -oE 'PASS:' | wc -l
```

Expected: 2 and 9 (the rest are unchanged).

- [ ] **Step 3: Commit**

```bash
git add lua/luai.lua
git commit -m "feat(luai): _require_init uses module_to_path"
```

---

## Task 4: Migrate `Generated` metatable to `luai.default`

**Files:**
- Modify: `lua/luai.lua`

- [ ] **Step 1: Update `Generated:__index`**

Find `function Generated:__index(key)` in `lua/luai.lua`. The function currently reads:

```lua
function Generated:__index(key)
  local filepath = get_generated_filepath(key)

  -- Save things into memory, so we don't read from disk all the time
  if cached[key] and not path.is_file_newer(filepath, cached[key].stat) then
    return cached[key].fn
  end

  -- Read things from disk, so we don't ask AI to generate every time
  local generated_filepath = get_generated_filepath(key)
  local result = read_generated_file(generated_filepath)
  -- ... (rest unchanged)
end
```

REPLACE the first two `get_generated_filepath(key)` calls and add an `ensure_default_module()` at the top of the function:

```lua
function Generated:__index(key)
  ensure_default_module()
  local filepath = module_to_path(DEFAULT_MODULE, key)

  -- Save things into memory, so we don't read from disk all the time
  if cached[key] and not path.is_file_newer(filepath, cached[key].stat) then
    return cached[key].fn
  end

  -- Read things from disk, so we don't ask AI to generate every time
  local generated_filepath = filepath
  local result = read_generated_file(generated_filepath)
  -- ... (rest unchanged)
end
```

(The `local generated_filepath = filepath` line reuses the same value rather than calling the helper twice — minor cleanup.)

- [ ] **Step 2: Update `Generated:__newindex`**

Find `function Generated:__newindex(key, value)` in `lua/luai.lua`. The function currently reads:

```lua
function Generated:__newindex(key, value)
  local generated_filepath = get_generated_filepath(key)
  local generated = assert(read_generated_file(generated_filepath), "existing func")
  -- ... (rest unchanged)
```

REPLACE the first line and add `ensure_default_module()`:

```lua
function Generated:__newindex(key, value)
  ensure_default_module()
  local generated_filepath = module_to_path(DEFAULT_MODULE, key)
  local generated = assert(read_generated_file(generated_filepath), "existing func")
  -- ... (rest unchanged)
```

There's also a line further down in `Generated:__newindex` that calls `get_generated_filepath(key)` again when building `towrite`:

```lua
local towrite = {
  function_name = key,
  filepath = get_generated_filepath(key),
  history = history,
  implementation = updated.implementation,
}
```

REPLACE:

```lua
local towrite = {
  function_name = key,
  filepath = module_to_path(DEFAULT_MODULE, key),
  history = history,
  implementation = updated.implementation,
}
```

- [ ] **Step 3: Re-run spec suites — no regressions**

```bash
nvim --headless --noplugin -u NONE -l test/storage_spec.lua 2>&1 | grep -oE 'PASS:' | wc -l
nvim --headless --noplugin -u NONE -l test/telescope_spec.lua 2>&1 | grep -oE 'PASS:' | wc -l
```

Expected: 2 and 9.

- [ ] **Step 4: Commit**

```bash
git add lua/luai.lua
git commit -m "feat(luai): generate.fn writes to luai.default module"
```

---

## Task 5: Migrate `M.improve` and `update_existing_generation`

**Files:**
- Modify: `lua/luai.lua`

- [ ] **Step 1: Update `M.improve`**

Find `M.improve` in `lua/luai.lua`. It currently reads:

```lua
M.improve = function(module)
  return setmetatable({}, {
    __newindex = function(_, function_name, value)
      local generated_filepath = find_module(module, function_name)
      assert(vim.uv.fs_stat(generated_filepath), "generated function file must exist already")

      update_existing_generation(generated_filepath, function_name, value)
    end,
  })
end
```

REPLACE with:

```lua
M.improve = function(module)
  local norm = normalize_module(module)
  return setmetatable({}, {
    __newindex = function(_, function_name, value)
      local generated_filepath = module_to_path(norm, function_name)
      assert(vim.uv.fs_stat(generated_filepath), "generated function file must exist already")

      update_existing_generation(generated_filepath, function_name, value)
    end,
  })
end
```

`update_existing_generation` is called with an already-resolved absolute filepath, so it doesn't need to know about the module — it stays as-is.

- [ ] **Step 2: Re-run spec suites**

```bash
nvim --headless --noplugin -u NONE -l test/storage_spec.lua 2>&1 | grep -oE 'PASS:' | wc -l
nvim --headless --noplugin -u NONE -l test/telescope_spec.lua 2>&1 | grep -oE 'PASS:' | wc -l
```

Expected: 2 and 9.

- [ ] **Step 3: Commit**

```bash
git add lua/luai.lua
git commit -m "feat(luai): improve uses module_to_path + auto-prefix"
```

---

## Task 6: Rewrite `get_generated_modules` to walk `<luai_root>` directly

**Files:**
- Modify: `lua/luai.lua`

- [ ] **Step 1: Replace `get_generated_modules`**

Find `get_generated_modules` in `lua/luai.lua`. It currently reads:

```lua
local generated_module_pattern = '^return require%("luai"%)%._require_init%("([^"]+)"%)'

---@return table[]
local get_generated_modules = function()
  local possible_inits = vim.api.nvim_get_runtime_file("lua/**/init.lua", true)
  local items = {}
  for _, file in ipairs(possible_inits) do
    local lines = vim.fn.readfile(file)
    local module = lines[1] and lines[1]:match(generated_module_pattern)
    if module then
      table.insert(items, {
        module = module,
        dir = vim.fn.fnamemodify(file, ":h"),
        init = file,
      })
    end
  end

  table.sort(items, function(left, right)
    return left.module < right.module
  end)

  return items
end
```

REPLACE the body of `get_generated_modules` (keep `generated_module_pattern` exactly as-is):

```lua
local generated_module_pattern = '^return require%("luai"%)%._require_init%("([^"]+)"%)'

---@return table[]
local get_generated_modules = function()
  local root = luai_root()
  local items = {}
  for name, type_ in vim.fs.dir(root) do
    if type_ == "directory" then
      local init_path = vim.fs.joinpath(root, name, "init.lua")
      if vim.uv.fs_stat(init_path) then
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

  table.sort(items, function(left, right)
    return left.module < right.module
  end)

  return items
end
```

Note: `vim.fs.dir(root)` is non-recursive and only walks immediate subdirectories. The current code looks at `<root>/<name>/init.lua` — i.e., one level deep. That matches the canonical pattern of modules being a single segment under luai (e.g., `luai.demo`, `luai.omarchy`, `luai.default`).

If you have multi-segment modules (e.g., `luai.foo.bar`), the picker won't surface them — but `demand("foo.bar")` would have written `<root>/foo/bar/init.lua`, not `<root>/foo/init.lua`. This is acceptable for v1; document the limitation in the README if it matters. (Existing demos use only single-segment modules, so no current functionality regresses.)

- [ ] **Step 2: Re-run all spec suites**

```bash
nvim --headless --noplugin -u NONE -l test/storage_spec.lua 2>&1 | grep -oE 'PASS:' | wc -l
nvim --headless --noplugin -u NONE -l test/stream_win_spec.lua 2>&1 | grep -oE 'PASS:' | wc -l
nvim --headless --noplugin -u NONE -l test/providers_spec.lua 2>&1 | grep -oE 'PASS:' | wc -l
nvim --headless --noplugin -u NONE -l test/dispatch_spec.lua 2>&1 | grep -oE 'PASS:' | wc -l
nvim --headless --noplugin -u NONE -l test/agent_spec.lua 2>&1 | grep -oE 'PASS:' | wc -l
nvim --headless --noplugin -u NONE -l test/telescope_spec.lua 2>&1 | grep -oE 'PASS:' | wc -l
```

Expected: 2, 12, 17, 7, 7, 9.

- [ ] **Step 3: Sanity-check discovery against the real repo**

```bash
nvim --headless --noplugin -u NONE -l /tmp/luai_telescope_smoke.lua 2>&1 | grep -E "^Found|^\[1\]|^\[5\]"
```

(`/tmp/luai_telescope_smoke.lua` was created in a previous session. If it's gone, recreate by inspecting `test/telescope_spec.lua`'s structure or skip this step. The point is: confirm `_get_generated_modules()` still finds `luai.demo` and `luai.omarchy` after the rewrite.)

Expected: `Found 9 generated functions` and entries `[1] luai.demo.change_omarchy_theme` plus similar.

- [ ] **Step 4: Commit**

```bash
git add lua/luai.lua
git commit -m "feat(luai): discovery walks <luai_root> directly instead of rtp"
```

---

## Task 7: Delete dead code

**Files:**
- Modify: `lua/luai.lua`

- [ ] **Step 1: Confirm nothing references the dead symbols**

```bash
grep -n "find_module\|get_generated_filepath\|basepath" lua/luai.lua
```

Expected output (only the definitions themselves, no callers):
- one line defining `local basepath = ...`
- one `vim.fn.mkdir(basepath, "p")` line
- one block `local function find_module(module, file) ... end`
- one `local function get_module_path(module) end` (pre-existing dead stub — leave or remove your call)
- one block `local get_generated_filepath = function(name) ... end`

If any caller still references these symbols, go back and migrate it before continuing. The above lines must be the ONLY occurrences.

- [ ] **Step 2: Delete `basepath` + its mkdir**

In `lua/luai.lua`, find:

```lua
-- Basepath for generated functions from luai, that are not from `demand(...)`
local basepath = vim.fs.joinpath(vim.fn.stdpath "data" --[[@as string]], "luai", "generated")
vim.fn.mkdir(basepath, "p")
```

Delete those three lines (the comment, the assignment, the mkdir).

- [ ] **Step 3: Delete `find_module`**

Find and delete the entire `find_module` function:

```lua
local function find_module(module, file)
  local parts = vim.split(module, ".", { plain = true })
  local paths = vim.api.nvim_get_runtime_file(vim.fs.joinpath("lua", parts[1]), true)
  if #paths == 1 then
    -- Replace the basepath
    parts[1] = paths[1]

    -- Append the file
    table.insert(parts, file .. ".lua")
    return vim.fs.joinpath(unpack(parts))
  end

  error "could not find module"
end
```

While you're there, also delete the pre-existing dead stub immediately below it:

```lua
local function get_module_path(module) end
```

- [ ] **Step 4: Delete `get_generated_filepath`**

Find and delete:

```lua
--- Get the generated file
---@param name string
---@return string
local get_generated_filepath = function(name)
  ---@diagnostic disable-next-line: param-type-mismatch
  return vim.fs.joinpath(basepath, name .. ".lua")
end
```

- [ ] **Step 5: Run all spec suites to confirm no regression**

```bash
nvim --headless --noplugin -u NONE -l test/storage_spec.lua 2>&1 | grep -oE 'PASS:' | wc -l
nvim --headless --noplugin -u NONE -l test/stream_win_spec.lua 2>&1 | grep -oE 'PASS:' | wc -l
nvim --headless --noplugin -u NONE -l test/providers_spec.lua 2>&1 | grep -oE 'PASS:' | wc -l
nvim --headless --noplugin -u NONE -l test/dispatch_spec.lua 2>&1 | grep -oE 'PASS:' | wc -l
nvim --headless --noplugin -u NONE -l test/agent_spec.lua 2>&1 | grep -oE 'PASS:' | wc -l
nvim --headless --noplugin -u NONE -l test/telescope_spec.lua 2>&1 | grep -oE 'PASS:' | wc -l
```

Expected: 2, 12, 17, 7, 7, 9.

- [ ] **Step 6: Re-grep to confirm dead code is gone**

```bash
grep -n "find_module\|get_generated_filepath\|basepath\|get_module_path" lua/luai.lua
```

Expected: no output.

- [ ] **Step 7: Commit**

```bash
git add lua/luai.lua
git commit -m "refactor(luai): drop find_module, get_generated_filepath, basepath"
```

---

## Task 8: README — storage path + migration note

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Find a sensible insertion point**

Open `README.md`. Find the `## Setup` section. After its last subsection (which is currently `### Per-call overrides`, ending with the paragraph about response normalisation), insert a new subsection.

- [ ] **Step 2: Insert the storage subsection**

Add this block immediately after the existing Setup subsections, BEFORE `## Usage`:

````markdown
### Where generated functions live

All generated functions are stored under the active luai.nvim install directory at `<install>/lua/luai/<module>/<function>.lua`. luai resolves the install dir at runtime via `nvim_get_runtime_file("lua/luai.lua", false)`, so this works whether luai is loaded from a lazy.nvim clone, a manual `:set rtp+=` from a development checkout, or anywhere else on the runtimepath.

Module names passed to `demand(...)` are auto-prefixed with `luai.` if absent:
- `demand("demo")` → `<install>/lua/luai/demo/`
- `demand("luai.demo")` → same path (no double-prefix)
- `demand("foo.bar")` → `<install>/lua/luai/foo/bar/`

The `M.generate.fn(...)` API has no module, so its files land under the fallback module `luai.default` at `<install>/lua/luai/default/<fn>.lua`.

#### Migrating older files

If you used a luai release that wrote `M.generate` files to `~/.local/share/nvim/luai/generated/`, those files are still on disk but no longer surfaced by luai. To bring them under the new root:

```bash
mkdir -p "<install>/lua/luai/default"
cp ~/.local/share/nvim/luai/generated/*.lua "<install>/lua/luai/default/"
```

You can find `<install>` by running this in Neovim:

```vim
:echo fnamemodify(nvim_get_runtime_file("lua/luai.lua", v:false)[0], ":h:h")
```

After copying, the picker and `M.generate.<name>` resolve normally.
````

- [ ] **Step 3: Commit**

```bash
git add README.md
git commit -m "docs: unified storage path + migration note"
```

---

## Task 9: Final verification

**Files:** none

- [ ] **Step 1: Run every spec suite**

```bash
nvim --headless --noplugin -u NONE -l test/storage_spec.lua 2>&1 | grep -oE 'PASS:' | wc -l
nvim --headless --noplugin -u NONE -l test/stream_win_spec.lua 2>&1 | grep -oE 'PASS:' | wc -l
nvim --headless --noplugin -u NONE -l test/providers_spec.lua 2>&1 | grep -oE 'PASS:' | wc -l
nvim --headless --noplugin -u NONE -l test/dispatch_spec.lua 2>&1 | grep -oE 'PASS:' | wc -l
nvim --headless --noplugin -u NONE -l test/agent_spec.lua 2>&1 | grep -oE 'PASS:' | wc -l
nvim --headless --noplugin -u NONE -l test/telescope_spec.lua 2>&1 | grep -oE 'PASS:' | wc -l
```

Expected counts: 2, 12, 17, 7, 7, 9. Total 54 PASS.

- [ ] **Step 2: Confirm `lua/luai.lua` no longer references stdpath('data')/luai**

```bash
grep -n 'stdpath.*luai\|basepath\|find_module\|get_generated_filepath' lua/luai.lua
```

Expected: no output.

- [ ] **Step 3: Parse-check `test/manual.lua`**

```bash
nvim --headless --noplugin -u NONE \
  -c 'lua local f, err = loadfile("test/manual.lua"); print(err and ("ERROR: " .. err) or "OK")' \
  -c 'qa'
```

Expected: `OK`.

- [ ] **Step 4: Branch history**

```bash
git log --oneline master..HEAD
git diff master --stat
```

Expected: 7 commits, file impact:
- `lua/luai.lua` modified (multiple commits)
- `test/storage_spec.lua` new
- `README.md` modified

- [ ] **Step 5: Smoke test — discover real demos via the migrated picker**

```bash
nvim --headless --noplugin -u NONE -l - <<'EOF'
vim.opt.rtp:append "."
local luai = require "luai"
local modules = luai._get_generated_modules()
print("Found " .. #modules .. " modules")
for _, m in ipairs(modules) do
  print("  " .. m.module .. " at " .. m.dir)
end
EOF
```

Expected: at least `luai.demo` and `luai.omarchy` listed (each at `<repo>/lua/luai/<sub>`). After Task 4's first `generate.fn` invocation `luai.default` would also appear, but no spec suite triggers a real generation so it might not exist yet.
