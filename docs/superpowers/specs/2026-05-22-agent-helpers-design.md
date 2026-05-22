# Agent Helpers for Generated Functions

**Status:** approved
**Date:** 2026-05-22

## Problem

Generated `luai.nvim` functions occasionally need to call the LLM agent themselves — for sub-tasks, refinements, or follow-up generations from within their own body. Today they have two unappealing options:

1. Call `vim.system(...)` directly with `claude`/`agent` — duplicates argv construction, JSON parsing, and error handling; no visibility into what's happening.
2. Use the existing `luai.providers.*` registry — works, but each call opens the full 80%×80% `stream_win`, which is too intrusive for nested calls.

We want a high-level helper that wraps the existing provider infrastructure with a small, passive notification-style window. We also want nested LLM-driven functions to be able to ask the user follow-up questions mid-execution.

## Goals

- A single `luai.agent.call{...}` helper that any generated function can use to call the configured LLM, with live output streamed into a small corner window.
- A `luai.agent.ask_user(question, choices?)` helper that prompts the user (text or multi-choice) and returns their answer synchronously.
- Reuse `luai.providers`, `dispatch_to_provider`, and `stream_win` — no parallel pipeline.
- Non-invasive UI: small corner-positioned floating window that doesn't steal focus.

## Non-goals

- LLM-emitted "ask user" markers parsed from output (the agent itself triggering a feedback prompt). v1 uses explicit Lua-API calls from generated code.
- Configurable corner-window geometry or position. v1 hard-codes 70×12 bottom-right.
- Persistent log of all `agent.call` invocations. Each call gets its own ephemeral window.
- Normalising the response into Lua code via `normalize_generated_code` — `agent.call` returns the raw model text since callers typically want free-form output (summaries, explanations, suggestions), not executable Lua.
- Configurable `ask_user` timeout (hard-coded 60 seconds in v1).

## Design

### Public API surface

```lua
local agent = require "luai.agent"

-- LLM call with a small corner window showing the live stream.
-- Returns the raw response string. Errors propagate from the provider.
---@param opts { prompt: string, provider?: string, __model?: string, [string]: any }
---@return string
agent.call(opts)

-- User-feedback prompt. Returns the user's answer, or nil on cancel/timeout.
---@param question string
---@param choices? string[]
---@return string?
agent.ask_user(question, choices)
```

`opts` for `agent.call` mirrors what providers expect: `prompt` is required; `provider` (string, optional) selects from the registry; any `__` prefixed keys (e.g., `__model`) are forwarded to the provider unchanged.

### `lua/luai/agent.lua` (new module)

```lua
local M = {}

local function map_provider_key(opts)
  if opts.provider then
    opts.__provider = opts.provider
    opts.provider = nil
  end
  return opts
end

---@param opts { prompt: string, provider?: string, [string]: any }
---@return string
function M.call(opts)
  assert(type(opts) == "table", "luai.agent.call: opts table required")
  assert(type(opts.prompt) == "string", "luai.agent.call: `prompt` is required")

  local call_opts = map_provider_key(vim.deepcopy(opts))
  call_opts.__window = { size = "corner", focus = false, winblend = 10 }

  local luai = require "luai"
  local result, stream = luai._dispatch_to_provider(opts.prompt, call_opts)
  stream.close()
  return result
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

Note: `opts.prompt` is left in `call_opts` even though providers don't read it. Dispatch takes the prompt as its first positional arg; the `prompt` key in opts is harmless and skipping a delete keeps the code simpler.

### `lua/luai/stream_win.lua` — geometry opts

`stream_win.open` grows an optional `geometry` field:

```lua
---@param opts? { title?: string, geometry?: { size?: "fullsize" | "corner" | { width: integer, height: integer, col: integer, row: integer } }, focus?: boolean, winblend?: integer }
---@return luai.StreamWin
function M.open(opts)
  opts = opts or {}
  local geometry = opts.geometry or { size = "fullsize" }

  local width, height, col, row
  if geometry.size == "corner" then
    width, height = 70, 12
    col = math.max(0, vim.o.columns - width - 2)
    row = math.max(0, vim.o.lines - height - 2)
  elseif type(geometry.size) == "table" then
    width = geometry.size.width
    height = geometry.size.height
    col = geometry.size.col
    row = geometry.size.row
  else  -- "fullsize" or any unknown -> fall back to current behaviour
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

  -- append/replace/close unchanged from current implementation
  ...
end
```

`replace` continues to lock `nomodifiable` after morph (existing spec compliance). For `agent.call` we never call `replace` (the window is ephemeral) so the lock is moot.

### `lua/luai.lua` `dispatch_to_provider` — forward `__window`

Tiny extension. Current code:

```lua
local stream = require("luai.stream_win").open { title = "luai: generating" }
```

Becomes:

```lua
local window_opts = opts.__window or {}
local stream = require("luai.stream_win").open(vim.tbl_extend("force", { title = "luai: generating" }, window_opts))
```

Existing callers don't set `__window`, so behaviour is unchanged. `agent.call` sets it explicitly to the corner preset.

### Data flow

```
generated_function(opts)
  require("luai.agent").call { prompt = "..." }
    deepcopy opts, set __window = corner preset
    luai._dispatch_to_provider(prompt, call_opts)
      stream_win.open { ...corner geometry, no focus, winblend=10 }
      provider(prompt, call_opts) → streams chunks → stream.append
      returns (result, stream)
    stream.close()                    ← agent.call closes
    returns raw result string

  agent.ask_user("?", {...})
    vim.ui.select(choices, opts, callback)
    vim.wait until done OR 60s
    returns user choice OR nil
```

### Error handling

| Case | Behaviour |
|---|---|
| `agent.call` missing `prompt` | `assert` fails: `luai.agent.call: prompt is required` |
| `agent.call` provider not configured | dispatch raises `[luai] no providers configured...`; agent.call propagates |
| `agent.call` unknown provider name | dispatch raises `[luai] unknown provider: X...`; agent.call propagates |
| `agent.call` provider runtime error | dispatch's pcall closes the stream and re-errors; agent.call propagates |
| `agent.call` provider timeout (5min) | dispatch's vim.wait timeout → SIGTERM + error; agent.call propagates |
| `ask_user` 60s timeout | Returns `nil` (no error — caller decides what to do) |
| `ask_user` user cancels (Esc in vim.ui.input) | Callback fires with `nil`; `done=true`; returns `nil` |

### Testing

`test/agent_spec.lua` (new) covers:
1. `agent.call` happy path — stub `luai._dispatch_to_provider` to capture `__window`, return `("ok", { close = fn })`. Assert call returns `"ok"`, `__window.size == "corner"`, `__window.focus == false`, and `stream.close` was called.
2. `agent.call` missing prompt — pcall, assert error matches "prompt is required".
3. `agent.call` provider key conversion — assert `opts.provider = "fast"` becomes `__provider = "fast"` in the call_opts forwarded to dispatch.
4. `agent.ask_user` free-text — stub `vim.ui.input` to invoke its callback with `"my answer"`. Assert function returns `"my answer"`.
5. `agent.ask_user` choices — stub `vim.ui.select` to invoke callback with selected choice. Assert function returns that choice.
6. `agent.ask_user` timeout — stub `vim.wait` to return false. Assert function returns `nil`.

`test/stream_win_spec.lua` (modify) adds one block:
7. `stream_win.open { geometry = { size = "corner" } }` opens a window with width=70, height=12. Verify via `vim.api.nvim_win_get_config(win)`.

### File-impact summary

| File | Action | Approx. lines |
|---|---|---|
| `lua/luai/agent.lua` | New | ~50 |
| `lua/luai/stream_win.lua` | Modify (geometry opts, focus, winblend) | +25 |
| `lua/luai.lua` | Modify (dispatch forwards `__window`) | +3 |
| `test/agent_spec.lua` | New | ~100 |
| `test/stream_win_spec.lua` | Modify (corner geometry test) | +15 |
| `README.md` | Add Agent helpers section | +30 |

### Backward compatibility

None broken. `stream_win.open` keeps its default geometry for callers that don't pass `geometry`. `dispatch_to_provider` keeps its default window for callers that don't pass `__window`. The new `luai.agent` module is opt-in via explicit `require`.

### Open questions

None. All three open points raised during brainstorming were approved:
- 60-second `ask_user` timeout is hard-coded in v1.
- Corner window sits bottom-right.
- `agent.call` returns raw provider response (no `normalize_generated_code`).
