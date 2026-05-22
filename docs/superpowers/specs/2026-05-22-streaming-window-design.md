# Live Streaming Window During Generation

**Status:** approved
**Date:** 2026-05-22

## Problem

`luai.nvim`'s generation pipeline blocks Neovim for the entire duration of an agent call (`vim.system(...):wait()` on `claude` or `agent`, which routinely runs 5–30 seconds). The user sees nothing happen until the result lands, and the UI is frozen during the wait. We want a non-blocking, live view of the model's output while it's generating.

## Goals

- Open a floating window the instant generation starts, stream the agent's stdout into it as the model writes, and morph the same window into the existing accept/review popup when generation completes.
- Keep Neovim's UI responsive during generation — no `:wait()` blocking the Lua thread.
- Cached `demand(...)` calls (no generation happens) do not open a window.
- No breaking changes to the existing public API.

## Non-goals

- Structured stream-event UX (separate panes for "thinking" / tool calls / text). v1 streams raw text chunks only.
- Streaming for `cursor_agent`. v1 leaves it sync (window stays empty until completion, then morphs).
- Configurable timeout (hard-coded 5 minutes in v1).
- Backwards compatibility shims for an old `__stream` flag — there is no old flag.

## Design

### Provider contract addition

Providers may honour an optional opts key:

```lua
opts.__on_chunk = function(chunk: string) ... end
```

When the dispatcher passes it, the provider SHOULD stream stdout text deltas to the callback as they arrive and still return the final consolidated result at the end. Providers that don't honour it stay silent during generation — they just behave synchronously. The dispatcher always opens a window; non-streaming providers leave it empty until the morph at completion.

### `lua/luai/stream_win.lua` (new module)

A single-purpose helper that opens a floating window and exposes an append/replace API.

```lua
---@class luai.StreamWin
---@field win integer
---@field buf integer
---@field append fun(chunk: string)
---@field replace fun(lines: string[])
---@field close fun()

local M = {}

---@param opts? { title?: string }
---@return luai.StreamWin
function M.open(opts)
  -- creates an unlisted scratch buffer, opens a floating window via luai.win.popup
  -- returns { win, buf, append(text), replace(lines), close() }
end

return M
```

Implementation details:
- Reuses `lua/luai/win.lua`'s `popup` helper for window geometry (same 80%×80% floating window the review popup uses today).
- Buffer is `nofile`, `nomodifiable` set to false during streaming, set to true after morph completes.
- `append(chunk)` splits on `\n`, appends to the buffer's last line, redraws via `vim.cmd.redraw()` so the user sees updates within the polling tick.
- `replace(lines)` wipes buffer content and writes the array of lines (used for the morph).
- `close()` deletes the buffer and closes the window.

### `lua/luai/providers.lua` `M.cli` — async streaming path

The `cli` builder's returned closure branches on whether `opts.__on_chunk` is present:

**`opts.__on_chunk == nil`** — sync path, unchanged from today.

**`opts.__on_chunk ~= nil`** — async path:

```lua
local stdout_chunks = {}
local stderr_chunks = {}
local done = false
local exit_code

local sys = vim.system(argv, {
  text = true,
  env = spec.env,
  stdout = function(_, chunk)
    if chunk then
      table.insert(stdout_chunks, chunk)
      vim.schedule(function() opts.__on_chunk(chunk) end)
    end
  end,
  stderr = function(_, chunk)
    if chunk then table.insert(stderr_chunks, chunk) end
  end,
}, function(result)
  exit_code = result.code
  done = true
end)

local ok = vim.wait(300000, function() return done end, 50)

if not ok then
  pcall(function() sys:kill(15) end) -- SIGTERM
  error(string.format("[luai] %s: generation timed out after 5m", spec.name))
end

local stdout = table.concat(stdout_chunks)
local stderr = table.concat(stderr_chunks)
-- same error handling as sync path (non-zero exit code, parse_response, etc.)
```

`vim.schedule` is used inside the stdout callback because `vim.system`'s callback runs in a libuv context where most Neovim API calls are unsafe. Scheduling pushes the actual UI write to the main thread.

### `lua/luai/providers.lua` `M.claude_code` — stream-json branch

When `opts.__on_chunk` is present, `claude_code` switches its argv:

```lua
return {
  "claude",
  "-p",
  "--output-format", "stream-json",
  "--verbose",
  "--model", model,
  prompt,
}
```

(`stream-json` requires `--verbose`. The user sees the model's text appear one assistant turn at a time — not strictly token-by-token, but visibly streaming for any non-trivial generation. If the user's Claude Code version doesn't support these flags, the CLI exits non-zero and the existing error path surfaces a clear message; no auto-fallback in v1.)

The `parse_response` callback for the streaming path parses each line as JSON:
- Events with `type = "assistant"` and a `message.content[*].type = "text"` carry the model's text — extract `text` and feed it to `__on_chunk` (this is what the user sees streaming in).
- The final event with `type = "result"` carries the consolidated `result` string — this is what `parse_response` returns.

If a line fails to parse as JSON, it's logged but skipped (best-effort parsing — stream-json is documented as one-event-per-line but pathological cases shouldn't crash the run).

For the non-streaming path, `claude_code`'s argv stays the same as today (`--output-format json` returning a single blob).

### `lua/luai/providers.lua` `M.cursor_agent` — unchanged

`cursor_agent` does not opt into streaming in v1. If `opts.__on_chunk` is present, the provider ignores it; the cli builder still runs synchronously (sync path runs when the cmd-function-returned argv produces a non-streaming `vim.system` call without a stdout callback). User sees an empty window until completion, then the morph.

Future: when/if Cursor Agent CLI gains a documented streaming mode, add an analogous branch.

### `lua/luai.lua` `dispatch_to_provider` — window orchestration

The dispatch function gains window lifecycle:

```lua
local dispatch_to_provider = function(prompt, opts)
  -- existing validation (no providers, unknown name) ...
  local provider = config.providers[name]

  local stream = require("luai.stream_win").open { title = "luai: generating" }
  opts.__on_chunk = function(chunk) stream.append(chunk) end

  local ok, result_or_err = pcall(provider, prompt, opts)

  if not ok then
    stream.close()
    error(result_or_err)
  end

  -- caller (generate_new_function) is responsible for morphing the buffer
  -- with normalized code and running the accept prompt. We return the
  -- stream handle so the caller can morph and close.
  return result_or_err, stream
end
```

The dispatch function now returns `(string, luai.StreamWin)`. `generate_new_function` is updated to consume both:

```lua
local generate_new_function = function(opts)
  local new_prompt = require "luai.prompt"(opts)
  local response_text, stream = dispatch_to_provider(new_prompt.prompt, opts.options)
  local implementation = normalize_generated_code(response_text)

  stream.replace(vim.split(implementation, "\n"))

  -- existing __prompt accept flow uses stream.win/stream.buf as the popup window
  -- on accept or completion: stream.close()
  ...
end
```

The existing review-popup code in `Generated:__index` is also updated to reuse the stream window instead of opening a fresh one. The accept-prompt uses `vim.fn.input` exactly as today.

### `M.improve` / cached `M.generate[name](opts)`

- `M.improve` runs through the same generation pipeline (calls `generate_new_function`), so it picks up the streaming window for free.
- Cached `M.generate[name](opts)` returns from `read_generated_file` without entering `generate_new_function` — no window opens. This matches the goal.

### Non-blocking mechanics

`vim.wait(300000, predicate, 50)` blocks the calling Lua execution but yields to the Neovim event loop every 50 ms. Effects:
- Stdout chunks flowing in via `vim.system`'s callback fire `vim.schedule(...)` → executed at the next event tick → buffer updates and `redraw` happen.
- The user can scroll, switch windows, etc. The polling cost (50 ms tick) is negligible.
- If the user kills the process externally or the system exits, the predicate becomes true and `vim.wait` returns.

Trade-off: this is still "synchronous to the caller" — `dispatch_to_provider(...)` doesn't return until the agent completes or times out. A truly async API (callback-based) would require restructuring the whole `demand(...).fn(opts)` contract, which is out of scope.

### Error handling

| Case | Behaviour |
|---|---|
| `vim.wait` times out at 5m | Kill child (SIGTERM via `sys:kill(15)`), close stream window, `error("[luai] <name>: generation timed out after 5m")` |
| Non-zero exit code | Same as sync path: `error("[luai] <name> failed: <stderr>")`. Window closes via the error-path branch in `dispatch_to_provider`. |
| stream-json parse failure on a single line | Log via `vim.notify` at WARN, skip the line, continue accumulating. The full stdout text is still returned at the end. |
| `claude` doesn't support `stream-json` (old version) | The non-zero exit code path catches it. v1 doesn't auto-fallback; the user gets a clear error pointing at the flag. |
| Provider doesn't honour `__on_chunk` | Window opens, stays empty, morphs at completion. Functionally correct. |

### Testing

Two new blocks in `test/providers_spec.lua`:
1. **cli with `__on_chunk` streams chunks.** Stub `vim.system` to invoke its `stdout` callback with a sequence of fake chunks and then complete. Assert the `__on_chunk` callback was called with each chunk and the final return matches the concatenated stdout.
2. **cli without `__on_chunk` still uses sync path.** Regression check — the existing 13 tests already cover this, but add one explicit assertion that `vim.system` is called WITHOUT a `stdout` callback when `__on_chunk` is absent.

One new block in `test/dispatch_spec.lua`:
3. **`dispatch_to_provider` opens a stream window and passes `__on_chunk` to the provider.** Stub `luai.stream_win.open` with a recorder. Set up a fake provider that captures `opts.__on_chunk` and returns "ok". Assert the recorder saw `open(...)` and the provider received a callable `__on_chunk`. Assert the dispatcher returns `(result, stream_handle)`.

End-to-end smoke test stays manual via `test/manual.lua` — the new fold block from Task 9 already covers it; users uncomment a demand call and watch the window.

### Backward compatibility

- Existing provider functions (user-written closures that accept only `(prompt, opts)`) continue to work. Lua silently accepts extra positional args that aren't taken (none here, since we pass via opts).
- Existing return value of `dispatch_to_provider` changes from `string` to `(string, luai.StreamWin)`. Only one caller exists (`generate_new_function`), updated in the same change. `M._dispatch_to_provider` is for tests only — those tests get updated to handle the second return.
- No new public config knobs. The window opens whenever generation runs.

### File-impact summary

| File | Action | Approximate lines |
|---|---|---|
| `lua/luai/stream_win.lua` | New | ~30 |
| `lua/luai/providers.lua` | Modify (async cli path + claude_code stream-json branch) | +50 |
| `lua/luai.lua` | Modify (window orchestration in dispatch + generate_new_function + Generated:__index) | +25 net |
| `test/providers_spec.lua` | Modify (2 new blocks) | +60 |
| `test/dispatch_spec.lua` | Modify (1 new block) | +25 |

### Open questions

None. All three open points raised during brainstorming were approved:
- `__on_chunk` lives alongside the other `__`-keys.
- 5-minute timeout is hard-coded (no config knob in v1).
- Cursor Agent stays non-streaming in v1.
