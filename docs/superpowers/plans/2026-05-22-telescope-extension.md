# Telescope Extension Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a Telescope extension at `lua/telescope/_extensions/luai.lua` so users can fuzzy-pick any previously-generated luai function via `:Telescope luai` and invoke it with the last-known opts.

**Architecture:** The extension reuses existing discovery (`get_generated_modules`, `get_generated_functions_for_module`, `read_generated_file`) by exposing them as `_`-prefixed aliases on `luai`. A `build_items()` helper hydrates each function with its latest `option_example` and `description` from the on-disk history. A `pick(opts)` function wires up `pickers.new` with finder, sorter, file-content previewer, and a select action that calls `require(module)[fn](option_example or {})`. Telescope stays a soft dependency — the extension file is only evaluated when Telescope itself loads it via `load_extension`.

**Tech Stack:** Lua 5.1, Telescope.nvim APIs (`pickers`, `finders`, `previewers`, `actions`, `actions.state`, `config.values`). Tests stub the entire telescope-* module tree via `package.loaded` so they pass without Telescope being installed.

**Spec:** `docs/superpowers/specs/2026-05-22-telescope-extension-design.md`

---

## File Structure

| File | Action | Responsibility |
|---|---|---|
| `lua/luai.lua` | **Modify** | Three new module-level exports — `M._get_generated_modules`, `M._get_generated_functions_for_module`, `M._read_generated_file` — each a plain alias for the existing local helper. ~6 lines. |
| `lua/telescope/_extensions/luai.lua` | **Create** | The extension. Defines `build_items()` (discovery + hydration) and `pick(opts)` (Telescope picker setup + action). Exports both as `run` and `luai` via `register_extension`. ~80 lines. |
| `test/telescope_spec.lua` | **Create** | Stubs the telescope-* tree in `package.loaded`, exercises module-load + build_items + selection action. ~120 lines. |
| `README.md` | **Modify** | Add `### Telescope` subsection under Usage with the `load_extension` snippet and the `:Telescope luai` command. ~25 lines. |

---

## Task 1: Expose `luai` discovery internals

**Files:**
- Modify: `lua/luai.lua`
- Create: `test/telescope_spec.lua`

- [ ] **Step 1: Write the failing import test**

Create `test/telescope_spec.lua`:
```lua
-- Run with: nvim --headless --noplugin -u NONE -l test/telescope_spec.lua
vim.opt.rtp:append "."

-- Confirm luai exposes the discovery helpers the extension needs.
local luai = require "luai"
assert(type(luai._get_generated_modules) == "function", "luai._get_generated_modules must be a function")
assert(type(luai._get_generated_functions_for_module) == "function", "luai._get_generated_functions_for_module must be a function")
assert(type(luai._read_generated_file) == "function", "luai._read_generated_file must be a function")
print "PASS: luai exposes telescope-extension discovery helpers"
```

- [ ] **Step 2: Run, confirm failure**

```bash
nvim --headless --noplugin -u NONE -l test/telescope_spec.lua
```

Expected: error that `_get_generated_modules` (or one of the three) is `nil`.

- [ ] **Step 3: Add three aliases to `lua/luai.lua`**

Open `lua/luai.lua`. Near the end of the file, just before the final `return M` (or in any logical spot near other `M._` assignments such as `M._dispatch_to_provider`), add:

```lua
M._get_generated_modules = get_generated_modules
M._get_generated_functions_for_module = get_generated_functions_for_module
M._read_generated_file = read_generated_file
```

These reference the existing local functions defined earlier in the file. No new logic — pure aliases.

- [ ] **Step 4: Verify the test passes**

```bash
nvim --headless --noplugin -u NONE -l test/telescope_spec.lua 2>&1 | grep -oE 'PASS:' | wc -l
```

Expected: 1 PASS line, exit 0.

- [ ] **Step 5: Re-run existing specs to confirm no regression**

```bash
nvim --headless --noplugin -u NONE -l test/stream_win_spec.lua 2>&1 | grep -oE 'PASS:' | wc -l
nvim --headless --noplugin -u NONE -l test/providers_spec.lua 2>&1 | grep -oE 'PASS:' | wc -l
nvim --headless --noplugin -u NONE -l test/dispatch_spec.lua 2>&1 | grep -oE 'PASS:' | wc -l
nvim --headless --noplugin -u NONE -l test/agent_spec.lua 2>&1 | grep -oE 'PASS:' | wc -l
```

Expected: 12, 17, 7, 7. No regression.

- [ ] **Step 6: Commit**

```bash
git add lua/luai.lua test/telescope_spec.lua
git commit -m "feat(luai): expose discovery helpers for extension use"
```

---

## Task 2: Extension skeleton — file exists, register_extension fires

**Files:**
- Create: `lua/telescope/_extensions/luai.lua`
- Modify: `test/telescope_spec.lua`

- [ ] **Step 1: Append the failing test**

Append to `test/telescope_spec.lua`:

```lua
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
```

- [ ] **Step 2: Run, confirm failure**

```bash
nvim --headless --noplugin -u NONE -l test/telescope_spec.lua
```

Expected: error `module 'telescope._extensions.luai' not found`.

- [ ] **Step 3: Create `lua/telescope/_extensions/luai.lua`**

Create the file with this skeleton (real implementations come in subsequent tasks):

```lua
local function build_items()
  return {}
end

local function pick(_opts)
  error "luai telescope extension: pick not implemented yet"
end

return require("telescope").register_extension {
  exports = {
    run = pick,
    luai = pick,
  },
}
```

- [ ] **Step 4: Verify the new block passes**

```bash
nvim --headless --noplugin -u NONE -l test/telescope_spec.lua 2>&1 | grep -oE 'PASS:' | wc -l
```

Expected: 2 PASS lines, exit 0.

- [ ] **Step 5: Commit**

```bash
git add lua/telescope/_extensions/luai.lua test/telescope_spec.lua
git commit -m "feat(telescope): extension skeleton with run/luai exports"
```

---

## Task 3: `build_items()` discovery and hydration

**Files:**
- Modify: `lua/telescope/_extensions/luai.lua`
- Modify: `test/telescope_spec.lua`

- [ ] **Step 1: Append the failing test**

Append to `test/telescope_spec.lua`:

```lua
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
  -- Access the build_items helper for direct test. Expose it via a top-level
  -- module local at the bottom of the extension file for testability:
  --   ext._build_items = build_items
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
```

- [ ] **Step 2: Run, confirm failure**

```bash
nvim --headless --noplugin -u NONE -l test/telescope_spec.lua
```

Expected: error `attempt to call a nil value (method 'find' or method '_build_items')` — the extension doesn't expose `_build_items` yet, and `build_items()` returns an empty table.

- [ ] **Step 3: Implement `build_items` and expose it**

Edit `lua/telescope/_extensions/luai.lua`. Replace the current contents with:

```lua
local function build_items()
  local luai = require "luai"
  local items = {}
  for _, module_item in ipairs(luai._get_generated_modules()) do
    for _, fn_item in ipairs(luai._get_generated_functions_for_module(module_item)) do
      local generated = luai._read_generated_file(fn_item.path)
      local latest = generated and generated.history and generated.history[#generated.history] or {}
      table.insert(items, {
        module = fn_item.module,
        fn = fn_item.fn,
        path = fn_item.path,
        option_example = latest.option_example,
        description = latest.description or "",
      })
    end
  end
  return items
end

local function pick(_opts)
  error "luai telescope extension: pick not implemented yet"
end

local ext = require("telescope").register_extension {
  exports = {
    run = pick,
    luai = pick,
  },
}

-- Internal hooks for tests; not part of the user-facing API.
ext._build_items = build_items

return ext
```

The `_build_items` underscore-prefixed export gives tests a direct entry point without going through the picker.

- [ ] **Step 4: Run, verify 3 PASS lines**

```bash
nvim --headless --noplugin -u NONE -l test/telescope_spec.lua 2>&1 | grep -oE 'PASS:' | wc -l
```

Expected: 3 (1 from Task 1 + 1 from Task 2 + 1 new).

- [ ] **Step 5: Commit**

```bash
git add lua/telescope/_extensions/luai.lua test/telescope_spec.lua
git commit -m "feat(telescope): build_items discovers and hydrates generated functions"
```

---

## Task 4: `pick()` constructs the Telescope picker

**Files:**
- Modify: `lua/telescope/_extensions/luai.lua`
- Modify: `test/telescope_spec.lua`

- [ ] **Step 1: Append the failing test**

Append to `test/telescope_spec.lua`:

```lua
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
```

- [ ] **Step 2: Run, confirm failure**

```bash
nvim --headless --noplugin -u NONE -l test/telescope_spec.lua
```

Expected: error from the current `pick` stub: `luai telescope extension: pick not implemented yet`.

- [ ] **Step 3: Implement `pick`**

Replace the current `pick` stub in `lua/telescope/_extensions/luai.lua` with the full implementation. The full file should now read:

```lua
local function build_items()
  local luai = require "luai"
  local items = {}
  for _, module_item in ipairs(luai._get_generated_modules()) do
    for _, fn_item in ipairs(luai._get_generated_functions_for_module(module_item)) do
      local generated = luai._read_generated_file(fn_item.path)
      local latest = generated and generated.history and generated.history[#generated.history] or {}
      table.insert(items, {
        module = fn_item.module,
        fn = fn_item.fn,
        path = fn_item.path,
        option_example = latest.option_example,
        description = latest.description or "",
      })
    end
  end
  return items
end

local function pick(opts)
  opts = opts or {}
  local pickers = require "telescope.pickers"
  local finders = require "telescope.finders"
  local conf = require("telescope.config").values
  local previewers = require "telescope.previewers"
  local actions = require "telescope.actions"
  local action_state = require "telescope.actions.state"

  local items = build_items()

  pickers.new(opts, {
    prompt_title = "luai functions",
    finder = finders.new_table {
      results = items,
      entry_maker = function(item)
        local desc_summary = (item.description:gsub("\n", " ")):sub(1, 60)
        local display = string.format("%s.%s", item.module, item.fn)
        if desc_summary ~= "" then
          display = display .. " — " .. desc_summary
        end
        return {
          value = item,
          display = display,
          ordinal = item.module .. "." .. item.fn,
          path = item.path,
        }
      end,
    },
    sorter = conf.generic_sorter(opts),
    previewer = previewers.new_buffer_previewer {
      title = "function source",
      define_preview = function(self, entry)
        local lines = vim.fn.readfile(entry.path)
        vim.api.nvim_buf_set_lines(self.state.bufnr, 0, -1, false, lines)
        vim.bo[self.state.bufnr].filetype = "lua"
      end,
    },
    attach_mappings = function(prompt_bufnr, _map)
      actions.select_default:replace(function()
        local entry = action_state.get_selected_entry()
        actions.close(prompt_bufnr)
        if not entry then return end
        local item = entry.value
        local mod = require(item.module)
        mod[item.fn](item.option_example or {})
      end)
      return true
    end,
  }):find()
end

local ext = require("telescope").register_extension {
  exports = {
    run = pick,
    luai = pick,
  },
}

ext._build_items = build_items

return ext
```

- [ ] **Step 4: Run, verify 5 PASS lines**

```bash
nvim --headless --noplugin -u NONE -l test/telescope_spec.lua 2>&1 | grep -oE 'PASS:' | wc -l
```

Expected: 5 (3 prior + 2 new), exit 0.

- [ ] **Step 5: Commit**

```bash
git add lua/telescope/_extensions/luai.lua test/telescope_spec.lua
git commit -m "feat(telescope): pick() wires Telescope picker for generated functions"
```

---

## Task 5: Selection action invokes the function

**Files:**
- Modify: `test/telescope_spec.lua`

(The implementation already does this — Task 5 adds the regression test.)

- [ ] **Step 1: Append two tests (with option_example + without option_example)**

Append to `test/telescope_spec.lua`:

```lua
-- Test: selecting an entry invokes require(module)[fn](option_example) when example is present.
do
  local invoked_with
  -- Stub the user-supplied module so we can capture the invocation.
  package.loaded["alpha"] = {
    do_thing = function(opts) invoked_with = opts end,
  }

  -- Capture the select_default action.
  local captured_action_fn
  package.loaded["telescope.actions"] = {
    select_default = { replace = function(_, fn) captured_action_fn = fn end },
    close = function() end,
  }
  -- Stub get_selected_entry to return a fake entry pointing at alpha.do_thing.
  package.loaded["telescope.actions.state"] = {
    get_selected_entry = function()
      return {
        value = {
          module = "alpha",
          fn = "do_thing",
          path = "/p/alpha/do_thing.lua",
          option_example = { x = 1, y = "two" },
        },
      }
    end,
  }

  -- Reset the rest of the telescope stubs (carry over from Task 4).
  package.loaded["telescope.pickers"] = {
    new = function(_, cfg)
      -- Trigger attach_mappings to install the action.
      cfg.attach_mappings(0, function() end)
      return { find = function() end }
    end,
  }
  package.loaded["telescope.finders"] = { new_table = function(o) return o end }
  package.loaded["telescope.config"] = { values = { generic_sorter = function() return "<sorter>" end } }
  package.loaded["telescope.previewers"] = { new_buffer_previewer = function(o) return o end }
  package.loaded["telescope"] = { register_extension = function(spec) return spec end }
  package.loaded["telescope._extensions.luai"] = nil
  local ext = require "telescope._extensions.luai"

  ext.exports.run {}

  assert(type(captured_action_fn) == "function", "select_default action captured")
  -- Fire the action as if the user pressed <CR>.
  captured_action_fn()

  assert(invoked_with ~= nil, "alpha.do_thing was invoked")
  assert(invoked_with.x == 1, "opts.x forwarded")
  assert(invoked_with.y == "two", "opts.y forwarded")
  print "PASS: selection invokes function with option_example"
end

-- Test: when option_example is nil, fall back to an empty table.
do
  local invoked_with
  package.loaded["alpha"] = {
    do_thing = function(opts) invoked_with = opts end,
  }

  local captured_action_fn
  package.loaded["telescope.actions"] = {
    select_default = { replace = function(_, fn) captured_action_fn = fn end },
    close = function() end,
  }
  package.loaded["telescope.actions.state"] = {
    get_selected_entry = function()
      return {
        value = {
          module = "alpha",
          fn = "do_thing",
          path = "/p/alpha/do_thing.lua",
          option_example = nil,
        },
      }
    end,
  }

  package.loaded["telescope.pickers"] = {
    new = function(_, cfg)
      cfg.attach_mappings(0, function() end)
      return { find = function() end }
    end,
  }
  package.loaded["telescope"] = { register_extension = function(spec) return spec end }
  package.loaded["telescope._extensions.luai"] = nil
  local ext = require "telescope._extensions.luai"
  ext.exports.run {}

  captured_action_fn()

  assert(type(invoked_with) == "table", "fallback opts is a table")
  assert(next(invoked_with) == nil, "fallback opts is empty")
  print "PASS: selection falls back to {} when option_example is nil"
end
```

- [ ] **Step 2: Run, verify 7 PASS lines**

```bash
nvim --headless --noplugin -u NONE -l test/telescope_spec.lua 2>&1 | grep -oE 'PASS:' | wc -l
```

Expected: 7 (5 prior + 2 new), exit 0.

- [ ] **Step 3: Commit**

```bash
git add test/telescope_spec.lua
git commit -m "test(telescope): selection action invokes function with option_example or {}"
```

---

## Task 6: README — add Telescope section

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Append a subsection under Usage**

Open `README.md`. Find the `### agent` subsection (added previously). After it, but still INSIDE the `## Usage` section (i.e., before any next top-level heading if one exists), append:

````markdown

### Telescope picker

`luai.nvim` ships a Telescope extension at `lua/telescope/_extensions/luai.lua` that lists every previously-generated function on your runtimepath and runs the one you pick.

Load it once in your Neovim config:

```lua
require("telescope").load_extension("luai")
```

Then:

```vim
:Telescope luai
```

The picker shows `module.function — first line of description` and a preview pane with the function's source file. Pressing `<CR>` invokes the selected function with the most recent `option_example` from its history (`{}` if there's no example yet). The selection happens before the picker closes, so any popup the function opens stays on top.

Telescope is a soft dependency — luai works fine without it; only this picker requires it.
````

- [ ] **Step 2: Commit**

```bash
git add README.md
git commit -m "docs: Telescope picker for fuzzy-finding generated functions"
```

---

## Task 7: Final verification

**Files:** none

- [ ] **Step 1: Run all five spec suites**

```bash
nvim --headless --noplugin -u NONE -l test/stream_win_spec.lua 2>&1 | grep -oE 'PASS:' | wc -l
nvim --headless --noplugin -u NONE -l test/providers_spec.lua 2>&1 | grep -oE 'PASS:' | wc -l
nvim --headless --noplugin -u NONE -l test/dispatch_spec.lua 2>&1 | grep -oE 'PASS:' | wc -l
nvim --headless --noplugin -u NONE -l test/agent_spec.lua 2>&1 | grep -oE 'PASS:' | wc -l
nvim --headless --noplugin -u NONE -l test/telescope_spec.lua 2>&1 | grep -oE 'PASS:' | wc -l
```

Expected: 12, 17, 7, 7, 7 — all five exit 0.

- [ ] **Step 2: Parse-check `test/manual.lua`**

```bash
nvim --headless --noplugin -u NONE \
  -c 'lua local f, err = loadfile("test/manual.lua"); print(err and ("ERROR: " .. err) or "OK")' \
  -c 'qa'
```

Expected: `OK`.

- [ ] **Step 3: Verify the extension file resolves via `require`**

```bash
nvim --headless --noplugin -u NONE \
  -c 'lua package.loaded["telescope"] = { register_extension = function(s) return s end }; local ext = require("telescope._extensions.luai"); print("ok:", type(ext.exports.run))' \
  -c 'qa'
```

Expected: `ok: function`.

- [ ] **Step 4: Verify branch history**

```bash
git log --oneline master..HEAD
git diff master --stat
```

Expected: 6 commits, file impact matches the File Structure table at the top of this plan.
