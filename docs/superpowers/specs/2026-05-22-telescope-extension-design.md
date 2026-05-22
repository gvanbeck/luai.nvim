# Telescope Extension for `luai.nvim`

**Status:** approved
**Date:** 2026-05-22

## Problem

Users accumulate generated `luai.nvim` functions over time across `lua/<module>/` directories on their runtimepath. There's no fast way to fuzzy-find one and run it — they have to remember the module + function name and type `:lua require("foo").bar{...}` by hand. The existing `:LuaiImprove` flow uses `vim.ui.select` for module/function picking but only routes into the improve path, not invocation.

We want a dedicated Telescope picker that lists every generated function on the runtimepath and runs the selected one with its last-known opts.

## Goals

- One command (`:Telescope luai`) opens a fuzzy picker of all generated functions on the runtimepath.
- Selecting an item invokes that function with the `option_example` from its history (or `{}` if none).
- Preview pane shows the function's source file for at-a-glance verification.
- Telescope stays a soft dependency — luai works fine without it; only the picker is gated on Telescope being installed.

## Non-goals

- Editing opts before invocation. v1 just runs with the last-known example. Users who want different opts use `:LuaiImprove` to update the function or edit the file directly.
- A new `:LuaiPick` user command. v1 wires only the Telescope-side; `:Telescope luai` is the entry point.
- Multi-select, batch invocation, or any "favorite functions" UX.
- A custom previewer that strips the `setmetatable({history=...,implementation=...})` wrapper. The raw file is shown as-is.

## Design

### Extension location

`lua/telescope/_extensions/luai.lua` — Telescope's standard auto-detection path. Telescope walks the runtimepath looking for these files when `require("telescope").load_extension("luai")` runs.

### Public API

The extension exposes a single picker function via Telescope's `register_extension`:

```lua
return require("telescope").register_extension {
  exports = {
    run = function(opts) ... end,
    -- Also bind as the default action so `:Telescope luai` works without args:
    luai = function(opts) ... end,
  },
}
```

User config:
```lua
require("telescope").load_extension("luai")
```

After that, `:Telescope luai` (or `:Telescope luai run`) opens the picker.

### Exposed `luai` internals

Three new module-level exports on `lua/luai.lua`, each a plain alias for an existing local helper:
```lua
M._get_generated_modules = get_generated_modules
M._get_generated_functions_for_module = get_generated_functions_for_module
M._read_generated_file = read_generated_file
```

These are private-by-convention (`_` prefix) but reachable by the extension. Same pattern as `M._dispatch_to_provider`.

### Picker construction

Inside `lua/telescope/_extensions/luai.lua`:

```lua
local pickers = require "telescope.pickers"
local finders = require "telescope.finders"
local previewers = require "telescope.previewers"
local conf = require("telescope.config").values
local actions = require "telescope.actions"
local action_state = require "telescope.actions.state"
local luai = require "luai"

local function build_items()
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

return require("telescope").register_extension {
  exports = {
    run = pick,
    luai = pick,
  },
}
```

### Picker UX

- **Display per entry**: `module.fn — <description first 60 chars, single-lined>`. Entries without a description show just `module.fn`.
- **Ordinal** (used for fuzzy matching): `module.fn`.
- **Preview**: the function's full file (`return setmetatable({history=...,implementation=...},...)` wrapper included), filetype `lua`. The wrapper carries useful context — history of all generations, descriptions, the actual closure — so users see everything at once.

### Data flow

```
:Telescope luai
  exports.run(opts)
    build_items()
      luai._get_generated_modules()  -- scans rtp for `_require_init` marker
      per module:
        luai._get_generated_functions_for_module(mod)
        per fn: luai._read_generated_file(path) -> { history, ... }
                pick latest history[#history] -> { option_example, description }
    pickers.new(opts, { finder, sorter, previewer, attach_mappings })
    :find()  -- Telescope takes over

User presses <CR>:
  actions.select_default fires the replaced action
  -> actions.close(prompt_bufnr)
  -> entry = action_state.get_selected_entry()
  -> require(entry.value.module)[entry.value.fn](entry.value.option_example or {})
```

### Error handling

| Case | Behaviour |
|---|---|
| Telescope not installed and user runs `:Telescope luai` | Telescope's own error — out of scope. |
| `_get_generated_modules()` returns `{}` (nothing generated yet) | Picker opens with an empty list. Standard Telescope behaviour. |
| `_read_generated_file` errors on a corrupt file | The function with that path is silently skipped; the others still appear. |
| `option_example` is nil for an entry | Pass `{}` as opts. The invoked function decides what to do. |
| Invocation raises | Error propagates to Neovim's message area. The picker has already closed (we call `actions.close` before invoking). |

### Testing

`test/telescope_spec.lua` (new). Uses `package.loaded` stubs to intercept the Telescope module tree, so the test runs without Telescope being installed.

Test fixtures the spec verifies:
1. **Module loads** — extension's `register_extension` returns an exports table with `run` and `luai` both callable. To do this the test stubs `package.loaded["telescope"] = { register_extension = function(spec) return spec end }`.
2. **`build_items` discovers and hydrates** — stub `luai._get_generated_modules` and friends to return canned data, call `pick({})`, assert the finder received the expected items.
3. **Selection action invokes the function** — stub `actions.select_default.replace` to capture the action, stub `action_state.get_selected_entry` to return a known entry. Stub `require(module_name)` via `package.loaded[module_name] = { fn = spy_fn }`. Trigger the action and assert `spy_fn` was called with the right opts.
4. **`option_example == nil` falls back to `{}`** — same as test 3 but `option_example` is nil; assert `spy_fn(({})` with an empty table.

### File-impact summary

| File | Action | Approx. lines |
|---|---|---|
| `lua/luai.lua` | Modify (3 underscore-exposed helpers) | +6 |
| `lua/telescope/_extensions/luai.lua` | New (picker + finder + previewer + action) | ~80 |
| `test/telescope_spec.lua` | New (4 stubbed tests) | ~120 |
| `README.md` | Modify (Telescope subsection under Usage) | +25 |

### Backward compatibility

None broken. The exposed `_get_*` / `_read_generated_file` are new exports; existing functionality is unchanged. The Telescope extension file only runs when Telescope explicitly loads it.

## Open questions

None. All three points raised during brainstorming were approved:
- `option_example` string-vs-table decoding is already handled by `_read_generated_file`.
- Preview shows the full file as-is (including the setmetatable wrapper).
- No `:LuaiPick` user command in v1 — `:Telescope luai` is the entry point.
