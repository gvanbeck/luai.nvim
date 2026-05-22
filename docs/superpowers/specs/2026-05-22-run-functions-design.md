# Running Generated Functions Ergonomically

**Status:** approved
**Date:** 2026-05-22

## Problem

There's no first-class way to invoke a generated luai function. Today's options:
- Hand-type `:lua require("luai_user.demo").foo{...}` — verbose, no completion.
- Use `:Telescope luai` — quick fuzzy pick, but always runs with the `option_example` from history; no awareness of current selection, cursor, or buffer.
- Call `demand("foo").bar(opts)` from Lua — programmatic, not a daily-driver UX.

We want a single command that runs a function by name with rich auto-populated context (selection, cursor, filetype, etc.), with tab-completion over function names and range support for visual-mode use.

## Goals

- New `:LuaiRun <name>` ex-command with `-range` support and tab-completion.
- Auto-context: every invocation receives a populated `opts` table with buffer/window/cursor/filetype/selection keys — generated functions read what they need.
- Shorthand: `:LuaiRun foo` resolves to `<namespace>.default.foo`. Multi-segment names are also accepted (`:LuaiRun demo.print_all_odd_values_in_table`, `:LuaiRun luai_user.demo.foo`).
- Tab-completion lists all `module.fn` combinations discovered under the user-storage root.
- Hands-off: luai doesn't process the function's return value. Functions are full Lua and do their own buffer/UI edits.

## Non-goals

- History-merge for `:LuaiRun`. The auto-context is the only data filled in; if a generated function needs richer opts (e.g., a model name override), the caller passes them via the picker (`option_example`) or calls the function programmatically. Keeps the two paths cleanly separated.
- Magic return-value handling (string-return → replace selection). Functions decide.
- Per-function declarative context schemas. All functions receive the same auto-context bag.
- Configurable bang-form (`:LuaiRun!`). v1 has one variant.

## Design

### Public API surface

Three new entry points on the `luai` module:

```lua
---@param name string: "fn" or "module.fn" or "<ns>.module.fn"
---@param ctx? { range_start?: integer, range_end?: integer, range_present?: boolean }
luai.run(name, ctx)

---@param arglead string: the partial argument the user is completing
---@return string[]: matching "module.fn" candidates
luai.complete_function_names(arglead)

-- New submodule:
local opts = require("luai.context").build_opts(ctx)
```

Plus a new ex-command in `plugin/luai.lua`:

```lua
vim.api.nvim_create_user_command("LuaiRun", function(c)
  require("luai").run(c.args, {
    range_start = c.line1,
    range_end = c.line2,
    range_present = c.range > 0,
  })
end, {
  nargs = 1,
  range = true,
  complete = function(arglead)
    return require("luai").complete_function_names(arglead)
  end,
  desc = "Run a generated luai function with auto-populated opts",
})
```

### `lua/luai/context.lua` (new module)

```lua
local M = {}

---@param ctx? { range_start?: integer, range_end?: integer, range_present?: boolean }
---@return table: opts with auto-context keys populated
function M.build_opts(ctx)
  ctx = ctx or {}
  local bufnr = vim.api.nvim_get_current_buf()
  local win = vim.api.nvim_get_current_win()
  local cursor = vim.api.nvim_win_get_cursor(win)

  local opts = {
    bufnr = bufnr,
    win = win,
    cwd = vim.uv.cwd() or vim.fn.getcwd(),
    cword = vim.fn.expand "<cword>",
    cfile = vim.fn.expand "<cfile>",
    cursor = cursor,
    line_number = cursor[1],
    line = vim.api.nvim_buf_get_lines(bufnr, cursor[1] - 1, cursor[1], false)[1] or "",
    filetype = vim.bo[bufnr].filetype,
  }

  if ctx.range_present and ctx.range_start and ctx.range_end then
    opts.range = { ctx.range_start, ctx.range_end }
    local lines = vim.api.nvim_buf_get_lines(bufnr, ctx.range_start - 1, ctx.range_end, false)
    opts.selection = table.concat(lines, "\n")
  end

  return opts
end

return M
```

Convention keys (full list):

| Key | Type | Meaning |
|---|---|---|
| `opts.bufnr` | integer | Current buffer. |
| `opts.win` | integer | Current window id. |
| `opts.cwd` | string | Working directory (`vim.uv.cwd()` with `vim.fn.getcwd()` fallback). |
| `opts.cword` | string | Word under cursor (`<cword>`). |
| `opts.cfile` | string | File name under cursor (`<cfile>`). |
| `opts.cursor` | `{row, col}` | 1-indexed line, 0-indexed col (vim convention). |
| `opts.line_number` | integer | Line containing the cursor. |
| `opts.line` | string | Text of the current line. |
| `opts.filetype` | string | `vim.bo[bufnr].filetype`. |
| `opts.range` | `{start, end}` | 1-indexed line range. Present only when invoked with a range. |
| `opts.selection` | string | `\n`-joined text of the range. Present only when invoked with a range. |

Functions read whatever subset they care about. No required keys.

### `M.run(name, ctx)` orchestrator

```lua
M.run = function(name, ctx)
  local module, fn = name:match "^(.+)%.([^.]+)$"
  if not module then
    -- No dot: treat as <ns>.default.<fn> shorthand.
    module = normalize_module(nil) -- = "<ns>.default"
    fn = name
  else
    module = normalize_module(module)
  end

  local opts = require("luai.context").build_opts(ctx)
  local mod = require(module)
  if type(mod[fn]) ~= "function" then
    error(string.format("[luai] function not found: %s.%s", module, fn))
  end
  mod[fn](opts)
end
```

Resolution table:

| User types | Resolved module | Resolved fn | Final require |
|---|---|---|---|
| `:LuaiRun make_readme` | `luai_user.default` | `make_readme` | `require("luai_user.default").make_readme` |
| `:LuaiRun demo.foo` | `luai_user.demo` | `foo` | `require("luai_user.demo").foo` |
| `:LuaiRun luai_user.demo.foo` | `luai_user.demo` | `foo` | `require("luai_user.demo").foo` (no double-prefix) |
| `:LuaiRun team.utils.fmt` | `luai_user.team.utils` (under custom namespace) | `fmt` | `require("<ns>.team.utils").fmt` |

The match pattern `^(.+)%.([^.]+)$` is greedy on the dot before the last segment, so `a.b.c` splits into module `a.b` + fn `c`.

### `M.complete_function_names(arglead)`

```lua
M.complete_function_names = function(arglead)
  local items = {}
  for _, module_item in ipairs(get_generated_modules()) do
    local module_sub = module_item.module:sub(#namespace() + 2) -- strip "<ns>." prefix
    for _, fn_item in ipairs(get_generated_functions_for_module(module_item)) do
      -- Two completion forms: with submodule prefix, and (for the default module) the bare fn.
      table.insert(items, module_sub .. "." .. fn_item.fn)
      if module_sub == "default" then
        table.insert(items, fn_item.fn)
      end
    end
  end
  table.sort(items)

  if arglead == "" then return items end

  local filtered = {}
  for _, candidate in ipairs(items) do
    if vim.startswith(candidate, arglead) then
      table.insert(filtered, candidate)
    end
  end
  return filtered
end
```

So tab-completion offers:
- Bare names for functions under the default module: `make_readme`, `summarize`.
- `<sub>.<fn>` for all modules: `demo.create_floating_window`, `omarchy.next_omarchy_background`.

### Selection-aware convention (documentation)

README adds a "Writing selection-aware functions" subsection. When you generate a function meant to operate on a visual selection, describe it so the LLM knows which keys to read:

```lua
demand("default").summarize {
  __description = "Read opts.selection. Call require('luai.agent').call { prompt = 'Summarize: ' .. opts.selection } and replace lines [opts.range[1], opts.range[2]] in opts.bufnr with the response.",
}
```

The LLM gets the convention spelled out in the prompt + the description, then writes a function that reads the right keys.

### Result handling

luai discards the return value. Generated functions do all editor side effects themselves.

### Data flow

```
:'<,'>LuaiRun summarize
  user-command callback fires with c.line1=3, c.line2=12, c.range=2, c.args="summarize"
  luai.run("summarize", { range_start=3, range_end=12, range_present=true })
    name has no dot -> module = "luai_user.default", fn = "summarize"
    context.build_opts(ctx)
      opts.bufnr = <current>, opts.win = <current>
      opts.range = {3, 12}
      opts.selection = "lines 3-12 joined with \n"
      opts.cursor, opts.line_number, opts.line, opts.filetype, opts.cwd, opts.cword, opts.cfile filled
    require("luai_user.default").summarize(opts)
      function reads opts.selection, etc, does its work.
```

### Error handling

| Case | Behaviour |
|---|---|
| `:LuaiRun foo` where `<ns>.default.foo` doesn't exist | `error("[luai] function not found: luai_user.default.foo")`. Surfaces in nvim's message area as a red error. |
| `:LuaiRun demo.missing` | Module loads, function key absent → same `function not found` error. |
| Function raises inside its body | Error propagates with full traceback. luai does no pcall wrapping. |
| `:LuaiRun` with empty arg | `nargs = 1` is enforced by nvim itself; user gets `E471: Argument required`. |
| Empty function-list (nothing generated yet) | Tab-completion returns `{}`. `:LuaiRun <anything>` fails at require time with a clear module-not-found error. |

### Testing

`test/context_spec.lua` (new):
1. `build_opts({})` returns table with `bufnr`, `win`, `cwd`, `cword`, `cfile`, `cursor`, `line_number`, `line`, `filetype`. No `range`, no `selection`.
2. `build_opts({ range_present = true, range_start = 2, range_end = 4 })` populates `range = {2, 4}` and `selection` from the buffer lines.
3. `opts.line_number` equals `opts.cursor[1]`.
4. With a known current-buffer filetype, `opts.filetype` reflects it.

`test/run_spec.lua` (new):
1. `luai.run("foo")` with no dot resolves to `<ns>.default.foo` (stub `require` to capture).
2. `luai.run("demo.bar")` resolves to `<ns>.demo.bar`.
3. `luai.run("luai_user.demo.foo")` doesn't double-prefix.
4. Missing function → `function not found` error.
5. `luai.complete_function_names("dem")` returns entries starting with `dem`.
6. `luai.complete_function_names("")` returns ALL entries.

The picker spec and other suites are unaffected.

### File-impact summary

| File | Action | Approx. lines |
|---|---|---|
| `lua/luai/context.lua` | New | ~30 |
| `lua/luai.lua` | Modify (add `M.run`, `M.complete_function_names`; expose `M.context`) | +35 |
| `plugin/luai.lua` | Modify (add `:LuaiRun` user command) | +10 |
| `test/context_spec.lua` | New | ~60 |
| `test/run_spec.lua` | New | ~80 |
| `README.md` | New subsection "Running generated functions" + selection-aware convention paragraph | +30 |

## Open questions

None. All three open points from brainstorming were approved:
- Bare `:LuaiRun foo` resolves to `<namespace>.default.foo`.
- No history-merge in `:LuaiRun`; auto-context is the only data fed in.
- Auto-context keys finalized: `bufnr`, `win`, `cwd`, `cword`, `cfile`, `cursor`, `line_number`, `line`, `filetype`, `range`, `selection`.
