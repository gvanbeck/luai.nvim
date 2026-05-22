# Run Functions Ergonomically Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a `:LuaiRun <name>` ex-command (with `-range` support and tab-completion) plus a `luai.context.build_opts()` helper so generated functions can be invoked by name with auto-populated context (selection, cursor, filetype, buffer, …).

**Architecture:** A new `lua/luai/context.lua` module owns the auto-context bag — pure mapping from `{range_start, range_end, range_present}` plus current vim state to an `opts` table with the documented convention keys. `lua/luai.lua` gains `M.run(name, ctx)` (resolves shorthand → `<namespace>.default.<name>` or normalises `module.fn` → `<namespace>.module.fn`, calls the function with `context.build_opts(ctx)`) and `M.complete_function_names(arglead)` (walks discovered modules to produce `<sub>.<fn>` candidates plus bare names for the default module). `plugin/luai.lua` registers the user command with `-range` + tab-completion.

**Tech Stack:** Lua 5.1, Neovim runtime (`vim.api.nvim_get_current_buf/win`, `vim.api.nvim_win_get_cursor`, `vim.api.nvim_buf_get_lines`, `vim.bo`, `vim.fn.expand`, `vim.uv.cwd`, `vim.startswith`). Tests stub `package.loaded` modules where needed; the context helper uses real buffer/window APIs which work in headless mode.

**Spec:** `docs/superpowers/specs/2026-05-22-run-functions-design.md`

---

## File Structure

| File | Action | Responsibility |
|---|---|---|
| `lua/luai/context.lua` | **Create** | `M.build_opts(ctx)` — produces the auto-context opts table. Convention keys (bufnr, win, cwd, cword, cfile, cursor, line_number, line, filetype; plus range + selection when ctx says so). ~30 lines. |
| `lua/luai.lua` | **Modify** | Add `M.run(name, ctx)` orchestrator and `M.complete_function_names(arglead)` for tab-completion. Both call existing `M._get_generated_modules` / `M._get_generated_functions_for_module` / `M._namespace` so they're testable via package.loaded stubs. ~35 lines added. |
| `plugin/luai.lua` | **Modify** | Add `:LuaiRun` ex-command with `nargs=1, range=true, complete=…`. ~10 lines added. |
| `test/context_spec.lua` | **Create** | 4 tests covering empty ctx, range present, line_number alignment, filetype propagation. |
| `test/run_spec.lua` | **Create** | 6 tests covering shorthand resolution, module.fn split, fully-qualified pass-through, missing-function error, complete_function_names filtering. |
| `README.md` | **Modify** | New "Running generated functions" subsection under `## Usage` + a "Writing selection-aware functions" paragraph. |

---

## Task 1: `lua/luai/context.lua` + tests

**Files:**
- Create: `lua/luai/context.lua`
- Create: `test/context_spec.lua`

- [ ] **Step 1: Write the failing tests**

Create `test/context_spec.lua`:

```lua
-- Run with: nvim --headless --noplugin -u NONE -l test/context_spec.lua
vim.opt.rtp:append "."

local ctx = require "luai.context"

-- Test: build_opts({}) returns the basic context keys, no range/selection.
do
  -- Set up a known buffer state.
  local buf = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "alpha", "beta", "gamma", "delta", "epsilon" })
  vim.api.nvim_set_current_buf(buf)
  vim.bo[buf].filetype = "lua"
  vim.api.nvim_win_set_cursor(0, { 3, 1 })

  local opts = ctx.build_opts {}
  assert(opts.bufnr == buf, "bufnr matches current")
  assert(type(opts.win) == "number", "win is a number")
  assert(type(opts.cwd) == "string" and opts.cwd ~= "", "cwd populated")
  assert(opts.cword == "gamma", "cword from line 3, got: " .. tostring(opts.cword))
  assert(opts.cursor[1] == 3, "cursor row 3")
  assert(opts.line_number == 3, "line_number 3")
  assert(opts.line == "gamma", "line text matches, got: " .. tostring(opts.line))
  assert(opts.filetype == "lua", "filetype lua")
  assert(opts.range == nil, "no range when not requested")
  assert(opts.selection == nil, "no selection when no range")
  print "PASS: build_opts populates basic context"
end

-- Test: with range present, range and selection are populated from the buffer.
do
  local buf = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "one", "two", "three", "four", "five" })
  vim.api.nvim_set_current_buf(buf)
  vim.api.nvim_win_set_cursor(0, { 1, 0 })

  local opts = ctx.build_opts { range_present = true, range_start = 2, range_end = 4 }
  assert(opts.range and opts.range[1] == 2 and opts.range[2] == 4, "range = {2,4}")
  assert(opts.selection == "two\nthree\nfour", "selection joined, got: " .. tostring(opts.selection))
  print "PASS: build_opts populates range + selection"
end

-- Test: line_number always equals cursor[1].
do
  local buf = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "x", "y", "z" })
  vim.api.nvim_set_current_buf(buf)
  vim.api.nvim_win_set_cursor(0, { 2, 0 })

  local opts = ctx.build_opts {}
  assert(opts.line_number == opts.cursor[1], "line_number == cursor[1]")
  print "PASS: line_number == cursor[1]"
end

-- Test: range_present = false (or absent) does not populate range/selection
-- even if range_start/range_end are provided.
do
  local buf = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "a", "b" })
  vim.api.nvim_set_current_buf(buf)

  local opts = ctx.build_opts { range_start = 1, range_end = 2, range_present = false }
  assert(opts.range == nil, "range absent when range_present=false")
  assert(opts.selection == nil, "selection absent when range_present=false")
  print "PASS: range_present=false suppresses range/selection"
end
```

- [ ] **Step 2: Run, confirm failure**

```bash
nvim --headless --noplugin -u NONE -l test/context_spec.lua
```

Expected: error `module 'luai.context' not found`.

- [ ] **Step 3: Create `lua/luai/context.lua`**

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

- [ ] **Step 4: Verify 4 PASS lines**

```bash
nvim --headless --noplugin -u NONE -l test/context_spec.lua 2>&1 | grep -oE 'PASS:' | wc -l
```

Expected: 4.

- [ ] **Step 5: Re-run all other suites for regression check**

```bash
nvim --headless --noplugin -u NONE -l test/storage_spec.lua 2>&1 | grep -oE 'PASS:' | wc -l
nvim --headless --noplugin -u NONE -l test/stream_win_spec.lua 2>&1 | grep -oE 'PASS:' | wc -l
nvim --headless --noplugin -u NONE -l test/providers_spec.lua 2>&1 | grep -oE 'PASS:' | wc -l
nvim --headless --noplugin -u NONE -l test/dispatch_spec.lua 2>&1 | grep -oE 'PASS:' | wc -l
nvim --headless --noplugin -u NONE -l test/agent_spec.lua 2>&1 | grep -oE 'PASS:' | wc -l
nvim --headless --noplugin -u NONE -l test/telescope_spec.lua 2>&1 | grep -oE 'PASS:' | wc -l
```

Expected: 6, 12, 17, 7, 7, 9. No regressions.

- [ ] **Step 6: Commit**

```bash
git add lua/luai/context.lua test/context_spec.lua
git commit -m "feat(context): build_opts populates auto-context bag"
```

---

## Task 2: `M.run` + `M.complete_function_names` + tests

**Files:**
- Modify: `lua/luai.lua`
- Create: `test/run_spec.lua`

- [ ] **Step 1: Write the failing tests**

Create `test/run_spec.lua`:

```lua
-- Run with: nvim --headless --noplugin -u NONE -l test/run_spec.lua
vim.opt.rtp:append "."

local luai = require "luai"
luai.setup { user_storage = "/tmp/luai_run_spec/lua/luai_user" }

-- Test: shorthand "foo" resolves to <ns>.default.foo
do
  local captured_opts
  package.loaded["luai_user.default"] = {
    foo = function(opts) captured_opts = opts end,
  }

  luai.run("foo", {})

  assert(captured_opts ~= nil, "function was called")
  assert(type(captured_opts.bufnr) == "number", "auto-context was built")
  print "PASS: run shorthand routes to <ns>.default.<fn>"
end

-- Test: "module.fn" form routes to <ns>.module.fn
do
  local captured_opts
  package.loaded["luai_user.demo"] = {
    bar = function(opts) captured_opts = opts end,
  }

  luai.run("demo.bar", {})

  assert(captured_opts ~= nil, "demo.bar called")
  print "PASS: run module.fn routes to <ns>.module.fn"
end

-- Test: fully-qualified name (already namespaced) does not double-prefix
do
  local captured_opts
  package.loaded["luai_user.demo"] = {
    baz = function(opts) captured_opts = opts end,
  }

  luai.run("luai_user.demo.baz", {})

  assert(captured_opts ~= nil, "luai_user.demo.baz called")
  print "PASS: run does not double-prefix fully-qualified names"
end

-- Test: missing function raises a clear error.
do
  package.loaded["luai_user.default"] = { something_else = function() end }
  local ok, err = pcall(luai.run, "does_not_exist", {})
  assert(not ok)
  assert(err:match "function not found", "error mentions missing function: " .. tostring(err))
  assert(err:match "luai_user%.default%.does_not_exist", "error names the resolved path: " .. tostring(err))
  print "PASS: run raises clear error on missing function"
end

-- Test: range_present is forwarded to context.build_opts (i.e., opts.range gets set).
do
  -- Make sure there's a buffer with enough lines.
  local buf = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "L1", "L2", "L3", "L4" })
  vim.api.nvim_set_current_buf(buf)

  local captured_opts
  package.loaded["luai_user.default"] = {
    selrun = function(opts) captured_opts = opts end,
  }

  luai.run("selrun", { range_start = 2, range_end = 4, range_present = true })
  assert(captured_opts.range and captured_opts.range[1] == 2 and captured_opts.range[2] == 4, "range forwarded")
  assert(captured_opts.selection == "L2\nL3\nL4", "selection populated, got: " .. tostring(captured_opts.selection))
  print "PASS: run forwards range/selection via context.build_opts"
end

-- Test: complete_function_names returns sorted, filtered candidates.
do
  -- Stub the discovery helpers directly on luai.
  luai._get_generated_modules = function()
    return {
      { module = "luai_user.default", dir = "/p/default", init = "/p/default/init.lua" },
      { module = "luai_user.demo", dir = "/p/demo", init = "/p/demo/init.lua" },
    }
  end
  luai._get_generated_functions_for_module = function(m)
    if m.module == "luai_user.default" then
      return { { module = "luai_user.default", fn = "make_readme", path = "/p/default/make_readme.lua" } }
    end
    return {
      { module = "luai_user.demo", fn = "alpha", path = "/p/demo/alpha.lua" },
      { module = "luai_user.demo", fn = "beta", path = "/p/demo/beta.lua" },
    }
  end

  local all = luai.complete_function_names ""
  -- Expect demo.alpha, demo.beta, default.make_readme, make_readme (bare for default).
  table.sort(all)
  assert(#all == 4, "four candidates, got: " .. #all)
  assert(all[1] == "default.make_readme")
  assert(all[2] == "demo.alpha")
  assert(all[3] == "demo.beta")
  assert(all[4] == "make_readme")

  local dem = luai.complete_function_names "dem"
  assert(#dem == 2, "two candidates with prefix 'dem': " .. #dem)
  assert(dem[1] == "demo.alpha" or dem[1] == "demo.beta")

  print "PASS: complete_function_names returns sorted, filtered candidates"
end
```

- [ ] **Step 2: Run, confirm failure**

```bash
nvim --headless --noplugin -u NONE -l test/run_spec.lua
```

Expected: error `attempt to call a nil value (method 'run')` from the first test block.

- [ ] **Step 3: Add `M.run` and `M.complete_function_names` to `lua/luai.lua`**

Open `lua/luai.lua`. Find the existing `M._dispatch_to_provider` or `M.demand` exports. Just before `return M` at the bottom of the file (next to other `M.*` assignments), add:

```lua
---Run a generated function by name with auto-populated context opts.
---@param name string: "fn" (shorthand for "<ns>.default.fn"), "module.fn", or fully-qualified "<ns>.module.fn"
---@param ctx? { range_start?: integer, range_end?: integer, range_present?: boolean }
M.run = function(name, ctx)
  local module, fn = name:match "^(.+)%.([^.]+)$"
  if not module then
    module = normalize_module(nil) -- <ns>.default
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

---@param arglead string: the partial argument the user is completing
---@return string[]
M.complete_function_names = function(arglead)
  local ns = M._namespace()
  local items = {}
  for _, module_item in ipairs(M._get_generated_modules()) do
    local module_sub = module_item.module:sub(#ns + 2) -- strip "<ns>." prefix
    for _, fn_item in ipairs(M._get_generated_functions_for_module(module_item)) do
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

- [ ] **Step 4: Verify 6 PASS lines in run_spec**

```bash
nvim --headless --noplugin -u NONE -l test/run_spec.lua 2>&1 | grep -oE 'PASS:' | wc -l
```

Expected: 6.

- [ ] **Step 5: Re-run all other suites**

```bash
nvim --headless --noplugin -u NONE -l test/context_spec.lua 2>&1 | grep -oE 'PASS:' | wc -l
nvim --headless --noplugin -u NONE -l test/storage_spec.lua 2>&1 | grep -oE 'PASS:' | wc -l
nvim --headless --noplugin -u NONE -l test/stream_win_spec.lua 2>&1 | grep -oE 'PASS:' | wc -l
nvim --headless --noplugin -u NONE -l test/providers_spec.lua 2>&1 | grep -oE 'PASS:' | wc -l
nvim --headless --noplugin -u NONE -l test/dispatch_spec.lua 2>&1 | grep -oE 'PASS:' | wc -l
nvim --headless --noplugin -u NONE -l test/agent_spec.lua 2>&1 | grep -oE 'PASS:' | wc -l
nvim --headless --noplugin -u NONE -l test/telescope_spec.lua 2>&1 | grep -oE 'PASS:' | wc -l
```

Expected: 4, 6, 12, 17, 7, 7, 9.

- [ ] **Step 6: Commit**

```bash
git add lua/luai.lua test/run_spec.lua
git commit -m "feat(luai): M.run + M.complete_function_names"
```

---

## Task 3: `:LuaiRun` ex-command

**Files:**
- Modify: `plugin/luai.lua`

(No new test file — the user-command wiring is small enough to verify by registering it and checking `vim.fn.exists(":LuaiRun")`.)

- [ ] **Step 1: Add the command to `plugin/luai.lua`**

Open `plugin/luai.lua`. After the existing `:LuaiImprove` command definition, append:

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

- [ ] **Step 2: Verify the command registers**

```bash
nvim --headless --noplugin -u NONE \
  -c 'set rtp+=.' \
  -c 'runtime! plugin/luai.lua' \
  -c 'lua print("LuaiRun exists:", vim.fn.exists(":LuaiRun") == 2)' \
  -c 'qa'
```

Expected: `LuaiRun exists: true`.

- [ ] **Step 3: Verify completion plumbing works (with stubs)**

```bash
nvim --headless --noplugin -u NONE \
  -c 'set rtp+=.' \
  -c 'runtime! plugin/luai.lua' \
  -c 'lua require("luai").setup{ user_storage = "/tmp/luai_run_cmd/lua/luai_user" }' \
  -c 'lua require("luai")._get_generated_modules = function() return { { module = "luai_user.default", dir = "/p", init = "/p/init.lua" } } end' \
  -c 'lua require("luai")._get_generated_functions_for_module = function(_) return { { module = "luai_user.default", fn = "make_readme", path = "/p/make_readme.lua" } } end' \
  -c 'lua local list = vim.fn.getcompletion("LuaiRun ", "cmdline"); print("completions: " .. table.concat(list, ", "))' \
  -c 'qa'
```

Expected: `completions: default.make_readme, make_readme` (order may vary; both should appear).

- [ ] **Step 4: Commit**

```bash
git add plugin/luai.lua
git commit -m "feat(plugin): :LuaiRun ex-command with -range + completion"
```

---

## Task 4: README — running section + convention

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Add a "Running generated functions" subsection under Usage**

Open `README.md`. Find the `## Usage` heading and its existing subsections (`### demand`, `### generate`, `### improve`, `### agent`, `### Telescope picker`). After the `### Telescope picker` subsection (currently the last under Usage), append:

````markdown

### Running generated functions

The most direct way to invoke a function is the `:LuaiRun` ex-command, which auto-populates an `opts` table with your current editor context and forwards it to the function:

```vim
:LuaiRun make_readme
:LuaiRun demo.print_all_odd_values_in_table
:'<,'>LuaiRun summarize
:5,15LuaiRun reformat
```

Bare names (`:LuaiRun make_readme`) resolve to `<namespace>.default.<name>`. Module-prefixed names (`:LuaiRun demo.foo`) resolve to `<namespace>.demo.foo`. Tab-completion lists every discovered combination plus bare-name shortcuts for the default module.

The function receives a single `opts` table with these convention keys:

| Key | Type | Contents |
|---|---|---|
| `opts.bufnr` | integer | Current buffer. |
| `opts.win` | integer | Current window id. |
| `opts.cwd` | string | Working directory. |
| `opts.cword` | string | Word under cursor (`<cword>`). |
| `opts.cfile` | string | File under cursor (`<cfile>`). |
| `opts.cursor` | `{row,col}` | 1-indexed line, 0-indexed col. |
| `opts.line_number` | integer | Cursor line. |
| `opts.line` | string | Text of the current line. |
| `opts.filetype` | string | Buffer's filetype. |
| `opts.range` | `{start,end}` | Line range. Present only when invoked with a range. |
| `opts.selection` | string | `\n`-joined text of the range. Present only when invoked with a range. |

Functions read whatever subset they care about — none of the keys are required.

#### Writing selection-aware functions

When you generate a function that should operate on the visual selection, describe the convention in `__description` so the LLM knows which keys to read:

```lua
demand("default").summarize {
  __description = [[
    Read opts.selection. Call require('luai.agent').call { prompt = "Summarize in 2 sentences:\n" .. opts.selection } and replace lines [opts.range[1], opts.range[2]] in opts.bufnr with the response via vim.api.nvim_buf_set_lines.
  ]],
}
```

After generation, invoke with `:'<,'>LuaiRun summarize` from visual mode. The function gets `opts.selection` + `opts.range` + `opts.bufnr` automatically.

The `agent.ask_user(question, choices?)` helper from the `agent` module is the right tool when a function needs follow-up confirmation from the user mid-execution.
````

- [ ] **Step 2: Commit**

```bash
git add README.md
git commit -m "docs: :LuaiRun ex-command + selection-aware convention"
```

---

## Task 5: Final verification

**Files:** none

- [ ] **Step 1: All spec suites pass**

```bash
nvim --headless --noplugin -u NONE -l test/context_spec.lua 2>&1 | grep -oE 'PASS:' | wc -l
nvim --headless --noplugin -u NONE -l test/run_spec.lua 2>&1 | grep -oE 'PASS:' | wc -l
nvim --headless --noplugin -u NONE -l test/storage_spec.lua 2>&1 | grep -oE 'PASS:' | wc -l
nvim --headless --noplugin -u NONE -l test/stream_win_spec.lua 2>&1 | grep -oE 'PASS:' | wc -l
nvim --headless --noplugin -u NONE -l test/providers_spec.lua 2>&1 | grep -oE 'PASS:' | wc -l
nvim --headless --noplugin -u NONE -l test/dispatch_spec.lua 2>&1 | grep -oE 'PASS:' | wc -l
nvim --headless --noplugin -u NONE -l test/agent_spec.lua 2>&1 | grep -oE 'PASS:' | wc -l
nvim --headless --noplugin -u NONE -l test/telescope_spec.lua 2>&1 | grep -oE 'PASS:' | wc -l
```

Expected counts: 4, 6, 6, 12, 17, 7, 7, 9. Total 68 PASS.

- [ ] **Step 2: `:LuaiRun` is registered + completion delivers**

```bash
nvim --headless --noplugin -u NONE \
  -c 'set rtp+=.' \
  -c 'runtime! plugin/luai.lua' \
  -c 'lua print("LuaiRun:", vim.fn.exists(":LuaiRun") == 2 and "yes" or "NO")' \
  -c 'qa'
```

Expected: `LuaiRun: yes`.

- [ ] **Step 3: Parse-check `test/manual.lua`**

```bash
nvim --headless --noplugin -u NONE \
  -c 'lua local f, err = loadfile("test/manual.lua"); print(err and ("ERROR: " .. err) or "OK")' \
  -c 'qa'
```

Expected: `OK`.

- [ ] **Step 4: Verify branch diff**

```bash
git log --oneline master..HEAD
git diff master --stat
```

Expected: 4 commits with the task subjects. Files touched:
- `lua/luai/context.lua` (new)
- `lua/luai.lua` (modified)
- `plugin/luai.lua` (modified)
- `test/context_spec.lua` (new)
- `test/run_spec.lua` (new)
- `README.md` (modified)
