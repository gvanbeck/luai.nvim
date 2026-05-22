# Agent Helpers Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add `luai.agent.call{...}` (LLM call with passive corner window) and `luai.agent.ask_user(question, choices?)` (sync user-feedback prompt) so generated functions can call the LLM themselves with non-invasive UI and bidirectional flow.

**Architecture:** A new `lua/luai/agent.lua` module exposes two helpers. `agent.call` deep-copies opts, sets `__window = { size = "corner", focus = false, winblend = 10 }`, and delegates to the existing `luai._dispatch_to_provider`, closing the returned stream after completion. `agent.ask_user` wraps `vim.ui.input` / `vim.ui.select` (callback-based) in a synchronous interface via `vim.wait`. `stream_win.open` is extended to accept geometry opts (`size`, `focus`, `winblend`); `dispatch_to_provider` forwards `opts.__window` through to it.

**Tech Stack:** Lua 5.1, Neovim runtime (`vim.api.nvim_open_win`, `vim.ui.input`, `vim.ui.select`, `vim.wait`, `vim.deepcopy`). Tests are headless via `nvim --headless --noplugin -u NONE -l <spec>.lua`.

**Spec:** `docs/superpowers/specs/2026-05-22-agent-helpers-design.md`

---

## File Structure

| File | Action | Responsibility |
|---|---|---|
| `lua/luai/stream_win.lua` | **Modify** | Grow `open(opts)` to accept `geometry` table (`size = "fullsize"` (default) / `"corner"` / `{ width, height, col, row }`), `focus` bool (default true), `winblend` int. Existing callers unchanged when no geometry/focus/winblend given. |
| `lua/luai.lua` | **Modify** | `dispatch_to_provider` reads `opts.__window` and merges it into the `stream_win.open` call. ~3 lines net delta. |
| `lua/luai/agent.lua` | **Create** | Two exports: `M.call(opts) -> string` and `M.ask_user(question, choices?) -> string?`. ~50 lines. |
| `test/stream_win_spec.lua` | **Modify** | One new block verifying corner geometry produces width=70, height=12 placed bottom-right. |
| `test/agent_spec.lua` | **Create** | Six new blocks: agent.call happy path, missing-prompt error, provider key conversion, ask_user free-text, ask_user choices, ask_user timeout. |
| `README.md` | **Modify** | Add a short "Agent helpers" subsection under Usage describing `agent.call` / `agent.ask_user`. |

---

## Task 1: `stream_win.open` accepts geometry, focus, winblend

**Files:**
- Modify: `lua/luai/stream_win.lua`
- Modify: `test/stream_win_spec.lua`

- [ ] **Step 1: Append the failing test**

Append to `test/stream_win_spec.lua`:
```lua
-- Test: open with geometry = { size = "corner" } opens a 70x12 window in bottom-right.
do
  local s = stream_win.open { geometry = { size = "corner" } }
  local cfg = vim.api.nvim_win_get_config(s.win)
  assert(cfg.width == 70, "width is 70, got: " .. tostring(cfg.width))
  assert(cfg.height == 12, "height is 12, got: " .. tostring(cfg.height))
  -- Bottom-right means col + width is near the right edge and row + height is near the bottom.
  assert(cfg.col + 70 <= vim.o.columns, "fits horizontally")
  assert(cfg.row + 12 <= vim.o.lines, "fits vertically")
  assert(cfg.col + 70 >= vim.o.columns - 4, "col is near right edge, got col: " .. tostring(cfg.col))
  assert(cfg.row + 12 >= vim.o.lines - 4, "row is near bottom edge, got row: " .. tostring(cfg.row))
  s.close()
  print "PASS: stream_win.open corner geometry"
end

-- Test: open with focus = false does not change the current window after opening.
do
  local before_win = vim.api.nvim_get_current_win()
  local s = stream_win.open { focus = false }
  local after_win = vim.api.nvim_get_current_win()
  assert(after_win == before_win, "focus=false leaves current window unchanged")
  s.close()
  print "PASS: stream_win.open focus=false leaves focus alone"
end

-- Test: open with winblend = 10 sets the win-local winblend option.
do
  local s = stream_win.open { winblend = 10 }
  assert(vim.wo[s.win].winblend == 10, "winblend applied, got: " .. tostring(vim.wo[s.win].winblend))
  s.close()
  print "PASS: stream_win.open winblend"
end

-- Test: open without geometry uses the existing fullsize default (80% x 80%).
do
  local s = stream_win.open {}
  local cfg = vim.api.nvim_win_get_config(s.win)
  local expected_width = math.floor(vim.o.columns * 0.8)
  local expected_height = math.floor(vim.o.lines * 0.8)
  assert(cfg.width == expected_width, "default width unchanged, got: " .. tostring(cfg.width))
  assert(cfg.height == expected_height, "default height unchanged, got: " .. tostring(cfg.height))
  s.close()
  print "PASS: stream_win.open fullsize default unchanged"
end
```

- [ ] **Step 2: Run, confirm the new blocks fail**

```bash
nvim --headless --noplugin -u NONE -l test/stream_win_spec.lua
```

Expected: the first new block fails (current `open` ignores `geometry` and always opens 80%×80%, so `cfg.width == 70` is false).

- [ ] **Step 3: Update `M.open` in `lua/luai/stream_win.lua`**

Find the current `function M.open(opts)` body. REPLACE the geometry/window-opening section (everything from `opts = opts or {}` down to the `local win = vim.api.nvim_open_win(...)` call inclusive) with:

```lua
  opts = opts or {}
  local geometry = opts.geometry or { size = "fullsize" }

  local width, height, col, row
  if geometry.size == "corner" then
    width = 70
    height = 12
    col = math.max(0, vim.o.columns - width - 2)
    row = math.max(0, vim.o.lines - height - 2)
  elseif type(geometry.size) == "table" then
    width = geometry.size.width
    height = geometry.size.height
    col = geometry.size.col
    row = geometry.size.row
  else
    width = math.floor(vim.o.columns * 0.8)
    height = math.floor(vim.o.lines * 0.8)
    col = math.floor((vim.o.columns - width) / 2)
    row = math.floor((vim.o.lines - height) / 2)
  end

  local focus = opts.focus
  if focus == nil then focus = true end

  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].filetype = "lua"

  local win = vim.api.nvim_open_win(buf, focus, {
    relative = "editor",
    width = width,
    height = height,
    col = col,
    row = row,
    style = "minimal",
    border = "rounded",
    title = opts.title or "luai",
    title_pos = "center",
  })

  if opts.winblend then
    vim.wo[win].winblend = opts.winblend
  end
```

Everything after this (`append`, `replace`, `close` and the `return` table) stays exactly the same.

Also update the LuaCATS annotation on `M.open` at the top of the function to:
```lua
---@param opts? { title?: string, geometry?: { size?: string|table }, focus?: boolean, winblend?: integer }
---@return luai.StreamWin
function M.open(opts)
```

- [ ] **Step 4: Run, verify 12 PASS lines**

```bash
nvim --headless --noplugin -u NONE -l test/stream_win_spec.lua
```

Expected: 12 `PASS:` lines (8 prior + 4 new), exit 0.

- [ ] **Step 5: Commit**

```bash
git add lua/luai/stream_win.lua test/stream_win_spec.lua
git commit -m "feat(stream_win): geometry, focus, and winblend opts for open()"
```

---

## Task 2: `dispatch_to_provider` forwards `opts.__window`

**Files:**
- Modify: `lua/luai.lua`
- Modify: `test/dispatch_spec.lua`

- [ ] **Step 1: Update the stream_win stub in `test/dispatch_spec.lua` to record open args**

Open `test/dispatch_spec.lua`. The file currently has at the top:
```lua
-- Stub stream_win for all tests in this file (real impl tested separately).
local stub_calls = { open = 0 }
package.loaded["luai.stream_win"] = {
  open = function(_opts)
    stub_calls.open = stub_calls.open + 1
    return {
      win = 0,
      buf = 0,
      append = function() end,
      replace = function() end,
      close = function() end,
    }
  end,
}
```

Replace it with a version that also captures the most recent opts:

```lua
-- Stub stream_win for all tests in this file (real impl tested separately).
local stub_calls = { open = 0, last_opts = nil }
package.loaded["luai.stream_win"] = {
  open = function(o)
    stub_calls.open = stub_calls.open + 1
    stub_calls.last_opts = o
    return {
      win = 0,
      buf = 0,
      append = function() end,
      replace = function() end,
      close = function() end,
    }
  end,
}
```

- [ ] **Step 2: Append the failing test**

Append to the bottom of `test/dispatch_spec.lua`:
```lua
-- Test: dispatch forwards opts.__window to stream_win.open.
do
  luai.setup {
    providers = {
      default = function(_, _) return "ok" end,
    },
    default_provider = "default",
  }

  stub_calls.last_opts = nil
  luai._dispatch_to_provider("prompt", {
    __window = { size = "corner", focus = false, winblend = 10 },
  })

  local opts = stub_calls.last_opts
  assert(type(opts) == "table", "stream_win.open received opts table")
  assert(opts.geometry and opts.geometry.size == "corner", "size = corner forwarded")
  assert(opts.focus == false, "focus = false forwarded")
  assert(opts.winblend == 10, "winblend = 10 forwarded")
  print "PASS: dispatch forwards __window to stream_win.open"
end
```

Note: the test refers to `opts.geometry`, `opts.focus`, `opts.winblend` — these are the fields `stream_win.open` expects. So `dispatch_to_provider` must translate `opts.__window = { size = ..., focus = ..., winblend = ... }` to `stream_win.open { geometry = { size = ... }, focus = ..., winblend = ... }`.

- [ ] **Step 3: Run, confirm the new block fails**

```bash
nvim --headless --noplugin -u NONE -l test/dispatch_spec.lua
```

Expected: `stub_calls.last_opts.geometry` is nil because dispatch doesn't pass `geometry` today.

- [ ] **Step 4: Update `dispatch_to_provider` in `lua/luai.lua`**

Find the line in `dispatch_to_provider`:
```lua
  local stream = require("luai.stream_win").open { title = "luai: generating" }
```

Replace it with:
```lua
  local window_opts = opts.__window or {}
  local stream = require("luai.stream_win").open {
    title = "luai: generating",
    geometry = { size = window_opts.size or "fullsize" },
    focus = window_opts.focus,
    winblend = window_opts.winblend,
  }
```

This translates the flat `__window` shape (`{ size, focus, winblend }`) into `stream_win.open`'s nested geometry shape, defaulting to `"fullsize"` when no `__window` is passed.

- [ ] **Step 5: Run, verify 7 PASS lines in dispatch_spec**

```bash
nvim --headless --noplugin -u NONE -l test/dispatch_spec.lua
```

Expected: 7 `PASS:` lines (6 prior + 1 new), exit 0.

- [ ] **Step 6: Re-run providers and stream_win specs for regression**

```bash
nvim --headless --noplugin -u NONE -l test/providers_spec.lua
nvim --headless --noplugin -u NONE -l test/stream_win_spec.lua
```

Expected: 17 PASS providers, 12 PASS stream_win. Exit 0 from each.

- [ ] **Step 7: Commit**

```bash
git add lua/luai.lua test/dispatch_spec.lua
git commit -m "feat(luai): dispatch forwards opts.__window to stream_win.open"
```

---

## Task 3: `lua/luai/agent.lua` skeleton + `ask_user` (free-text path)

**Files:**
- Create: `lua/luai/agent.lua`
- Create: `test/agent_spec.lua`

- [ ] **Step 1: Write the failing test**

Create `test/agent_spec.lua`:
```lua
-- Run with: nvim --headless --noplugin -u NONE -l test/agent_spec.lua
vim.opt.rtp:append "."

-- The agent module loads on-demand; no stubs needed for ask_user tests.
local agent = require "luai.agent"

assert(type(agent.call) == "function", "agent.call exported")
assert(type(agent.ask_user) == "function", "agent.ask_user exported")
print "PASS: luai.agent module exports"

-- Test: ask_user without choices uses vim.ui.input and returns the input value.
do
  local captured_prompt
  local original_input = vim.ui.input
  vim.ui.input = function(opts, cb)
    captured_prompt = opts.prompt
    cb "user typed this"
  end

  local result = agent.ask_user "What is your name?"

  vim.ui.input = original_input
  assert(captured_prompt == "What is your name?")
  assert(result == "user typed this", "got: " .. tostring(result))
  print "PASS: agent.ask_user free-text via vim.ui.input"
end
```

- [ ] **Step 2: Run, confirm failure (module doesn't exist)**

```bash
nvim --headless --noplugin -u NONE -l test/agent_spec.lua
```

Expected: error `module 'luai.agent' not found`.

- [ ] **Step 3: Create skeleton `lua/luai/agent.lua`**

Create `lua/luai/agent.lua`:
```lua
local M = {}

---@param opts table
---@return string
function M.call(opts)
  error "luai.agent.call: not implemented yet"
end

---@param question string
---@param choices? string[]
---@return string?
function M.ask_user(question, choices)
  assert(type(question) == "string", "luai.agent.ask_user: question must be a string")

  local response
  local done = false

  if choices then
    vim.ui.select(choices, { prompt = question }, function(choice)
      response = choice
      done = true
    end)
  else
    vim.ui.input({ prompt = question }, function(input)
      response = input
      done = true
    end)
  end

  local ok = vim.wait(60000, function() return done end, 50)
  if not ok then
    return nil
  end
  return response
end

return M
```

- [ ] **Step 4: Run, verify 2 PASS lines**

```bash
nvim --headless --noplugin -u NONE -l test/agent_spec.lua
```

Expected: 2 `PASS:` lines (module exports + free-text ask_user), exit 0.

- [ ] **Step 5: Commit**

```bash
git add lua/luai/agent.lua test/agent_spec.lua
git commit -m "feat(agent): ask_user free-text path with vim.ui.input"
```

---

## Task 4: `agent.ask_user` with choices

**Files:**
- Modify: `test/agent_spec.lua`

(`agent.ask_user`'s `choices` branch is already in place from Task 3 — this task adds the regression test.)

- [ ] **Step 1: Append the test**

Append to `test/agent_spec.lua`:
```lua
-- Test: ask_user with choices uses vim.ui.select and returns the selected choice.
do
  local captured_choices, captured_prompt
  local original_select = vim.ui.select
  vim.ui.select = function(items, opts, cb)
    captured_choices = items
    captured_prompt = opts.prompt
    cb(items[2])
  end

  local result = agent.ask_user("Pick a style:", { "concise", "detailed", "bullets" })

  vim.ui.select = original_select
  assert(captured_prompt == "Pick a style:")
  assert(captured_choices[1] == "concise")
  assert(captured_choices[3] == "bullets")
  assert(result == "detailed", "got: " .. tostring(result))
  print "PASS: agent.ask_user choices via vim.ui.select"
end
```

- [ ] **Step 2: Run, verify 3 PASS lines**

```bash
nvim --headless --noplugin -u NONE -l test/agent_spec.lua
```

Expected: 3 `PASS:` lines, exit 0.

- [ ] **Step 3: Commit**

```bash
git add test/agent_spec.lua
git commit -m "test(agent): ask_user choices via vim.ui.select"
```

---

## Task 5: `agent.ask_user` timeout

**Files:**
- Modify: `test/agent_spec.lua`

- [ ] **Step 1: Append the test**

Append to `test/agent_spec.lua`:
```lua
-- Test: ask_user returns nil when vim.wait times out (60s with no response).
do
  local original_input = vim.ui.input
  local original_wait = vim.wait
  vim.ui.input = function(_opts, _cb)
    -- Never invoke the callback so the predicate never becomes true.
  end
  vim.wait = function(_timeout, _predicate, _interval)
    return false
  end

  local result = agent.ask_user "ignored"

  vim.ui.input = original_input
  vim.wait = original_wait

  assert(result == nil, "timeout returns nil, got: " .. tostring(result))
  print "PASS: agent.ask_user timeout returns nil"
end
```

- [ ] **Step 2: Run, verify 4 PASS lines**

```bash
nvim --headless --noplugin -u NONE -l test/agent_spec.lua
```

Expected: 4 `PASS:` lines, exit 0.

- [ ] **Step 3: Commit**

```bash
git add test/agent_spec.lua
git commit -m "test(agent): ask_user returns nil on timeout"
```

---

## Task 6: `agent.call` happy path

**Files:**
- Modify: `lua/luai/agent.lua`
- Modify: `test/agent_spec.lua`

- [ ] **Step 1: Append the failing test**

Append to `test/agent_spec.lua`:
```lua
-- Test: agent.call delegates to luai._dispatch_to_provider with __window = corner preset
-- and closes the returned stream before returning the result.
do
  local captured_prompt, captured_opts, close_called
  -- Stub luai to intercept dispatch.
  package.loaded["luai"] = {
    _dispatch_to_provider = function(prompt, opts)
      captured_prompt = prompt
      captured_opts = opts
      return "model response", {
        close = function() close_called = true end,
      }
    end,
  }

  local result = agent.call { prompt = "summarize this", provider = "fast" }

  assert(result == "model response", "raw result returned, got: " .. tostring(result))
  assert(captured_prompt == "summarize this", "prompt forwarded")
  assert(captured_opts.__window, "__window opts present")
  assert(captured_opts.__window.size == "corner", "size = corner")
  assert(captured_opts.__window.focus == false, "focus = false")
  assert(captured_opts.__window.winblend == 10, "winblend = 10")
  assert(captured_opts.__provider == "fast", "provider key converted to __provider")
  assert(captured_opts.provider == nil, "user-friendly `provider` removed")
  assert(close_called, "stream.close was invoked")
  print "PASS: agent.call delegates with corner-window opts and closes stream"
end
```

- [ ] **Step 2: Run, confirm failure**

```bash
nvim --headless --noplugin -u NONE -l test/agent_spec.lua
```

Expected: error `luai.agent.call: not implemented yet` from the stub.

- [ ] **Step 3: Implement `M.call`**

In `lua/luai/agent.lua`, replace the stub `M.call` body:

```lua
---@param opts { prompt: string, provider?: string, [string]: any }
---@return string
function M.call(opts)
  assert(type(opts) == "table", "luai.agent.call: opts table required")
  assert(type(opts.prompt) == "string", "luai.agent.call: `prompt` is required")

  local call_opts = vim.deepcopy(opts)
  if call_opts.provider then
    call_opts.__provider = call_opts.provider
    call_opts.provider = nil
  end
  call_opts.__window = { size = "corner", focus = false, winblend = 10 }

  local luai = require "luai"
  local result, stream = luai._dispatch_to_provider(opts.prompt, call_opts)
  stream.close()
  return result
end
```

- [ ] **Step 4: Run, verify 5 PASS lines**

```bash
nvim --headless --noplugin -u NONE -l test/agent_spec.lua
```

Expected: 5 `PASS:` lines, exit 0.

- [ ] **Step 5: Commit**

```bash
git add lua/luai/agent.lua test/agent_spec.lua
git commit -m "feat(agent): call() delegates to dispatch with corner-window preset"
```

---

## Task 7: `agent.call` error paths

**Files:**
- Modify: `test/agent_spec.lua`

- [ ] **Step 1: Append two failing tests**

Append to `test/agent_spec.lua`:
```lua
-- Test: agent.call without `prompt` errors with a clear message.
do
  local ok, err = pcall(agent.call, {})
  assert(not ok, "should have errored")
  assert(err:match "prompt is required", "error mentions missing prompt: " .. tostring(err))
  print "PASS: agent.call requires prompt"
end

-- Test: agent.call propagates provider errors from dispatch.
do
  -- Override the stubbed luai module from the previous test with one that errors.
  package.loaded["luai"] = {
    _dispatch_to_provider = function(_prompt, _opts)
      error "[luai] simulated provider failure"
    end,
  }

  local ok, err = pcall(agent.call, { prompt = "x" })
  assert(not ok)
  assert(err:match "simulated provider failure", "error propagates: " .. tostring(err))
  print "PASS: agent.call propagates provider errors"
end
```

- [ ] **Step 2: Run, verify 7 PASS lines**

```bash
nvim --headless --noplugin -u NONE -l test/agent_spec.lua
```

Expected: 7 `PASS:` lines, exit 0.

- [ ] **Step 3: Commit**

```bash
git add test/agent_spec.lua
git commit -m "test(agent): call requires prompt and propagates provider errors"
```

---

## Task 8: README — add Agent helpers section

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Add a subsection under Usage**

Find the `## Usage` heading in `README.md`. Within it, after the `### improve` subsection (last one currently), append:

````markdown
### `agent` (for generated functions that call the LLM themselves)

Generated functions that need to make their own LLM calls — for sub-tasks, refinements, or follow-up questions — can use the `luai.agent` helpers:

```lua
local agent = require "luai.agent"

local result = agent.call {
  prompt = "summarize the following: " .. text,
  provider = "fast",   -- optional, defaults to your default_provider
}

-- Ask the user a follow-up before continuing.
local choice = agent.ask_user("Use that summary?", { "yes", "no" })
if choice == "no" then
  return agent.call { prompt = "try again, more concise" }
end
```

`agent.call` opens a small 70×12 floating window in the bottom-right corner showing the LLM's live stream. It does not steal focus and closes itself when the call completes. The returned string is the model's raw response (no Lua normalisation — use `M.generate` if you want code generated and stored on disk).

`agent.ask_user(question)` returns the user's free-text answer. Pass a second argument with a list of strings to get a selection prompt instead. Returns `nil` on cancel or after 60 seconds without a response.
````

- [ ] **Step 2: Commit**

```bash
git add README.md
git commit -m "docs: agent helpers — call() and ask_user() for nested LLM use"
```

---

## Task 9: Final verification

**Files:** none

- [ ] **Step 1: Run all four spec suites**

```bash
nvim --headless --noplugin -u NONE -l test/stream_win_spec.lua 2>&1 | grep -oE 'PASS:' | wc -l
nvim --headless --noplugin -u NONE -l test/providers_spec.lua 2>&1 | grep -oE 'PASS:' | wc -l
nvim --headless --noplugin -u NONE -l test/dispatch_spec.lua 2>&1 | grep -oE 'PASS:' | wc -l
nvim --headless --noplugin -u NONE -l test/agent_spec.lua 2>&1 | grep -oE 'PASS:' | wc -l
```

Expected:
- stream_win: 12 PASS
- providers: 17 PASS
- dispatch: 7 PASS
- agent: 7 PASS

All four exit 0.

- [ ] **Step 2: Parse-check `test/manual.lua`**

```bash
nvim --headless --noplugin -u NONE \
  -c 'lua local f, err = loadfile("test/manual.lua"); print(err and ("ERROR: " .. err) or "OK")' \
  -c 'qa'
```

Expected: `OK`.

- [ ] **Step 3: Verify branch history**

```bash
git log --oneline master..HEAD
git diff master --stat
```

Expected: 8 commits, file impact matches the File Structure table at the top of this plan.
