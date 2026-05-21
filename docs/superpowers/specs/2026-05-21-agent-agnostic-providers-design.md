# Agent-Agnostic Providers for `luai.nvim`

**Status:** approved
**Date:** 2026-05-21

## Problem

`luai.nvim` is currently hard-coded to the Cursor Agent CLI. `request_generation` in `lua/luai.lua:124-169` spawns `agent -p --mode ask ...` and reads `.result` from its JSON response. The only knob is `config.model`. To use any other agent (Claude Code, Gemini CLI, Aider, a local Ollama bridge, …) the user has to fork the plugin.

We want a pluggable provider interface so any CLI agent can drive the generation, with `cursor_agent` and `claude_code` shipping as built-ins.

## Goals

- Decouple the agent invocation from the rest of the generation pipeline.
- Allow multiple providers to be configured side-by-side and switched per-call.
- Ship a `claude_code` provider example out of the box.
- Keep the surface area small — a function is the provider, full stop.

## Non-goals

- Async generation (still tracked in the TODO at the top of `lua/luai.lua`).
- Backward compatibility with the existing `model = "..."` config shape.
- Streaming response handling.
- Provider auto-discovery from `PATH`.

## Design

### Provider contract

A provider is a Lua function:

```lua
---@alias luai.Provider fun(prompt: string, opts: table): string
```

- `prompt`: the fully-rendered prompt string built by `lua/luai/prompt.lua`.
- `opts`: the opts table the user passed to the generated function, including `__`-prefixed control keys.
- Return value: **raw response text**, expected to contain Lua code that starts with `return function(opts)`. The plugin normalises and validates this downstream — providers should not pre-process.
- On failure: `error(...)` with a message prefixed `[luai] <provider-name>: ...`. The plugin propagates errors unchanged.

The `__model` key in `opts` is a hint that providers MAY honour as a per-call model override (matching today's behaviour). Providers that don't care about models can ignore it.

### Configuration

`setup{}` takes a named registry plus a default selector:

```lua
require("luai").setup {
  providers = {
    default = require("luai.providers").claude_code { model = "sonnet" },
    fast    = require("luai.providers").claude_code { model = "haiku" },
    cursor  = require("luai.providers").cursor_agent { model = "composer-2-fast" },
  },
  default_provider = "default",
}
```

- `providers`: `{ [name] = luai.Provider }` table. Required.
- `default_provider`: string key into `providers`. Defaults to `"default"`. If neither `default_provider` nor a key named `"default"` exists, generation errors with a clear message.
- Per-call override: `opts.__provider = "fast"` switches provider for one call.

### Components

New file: `lua/luai/providers.lua` (single file, all three exports). Roughly 80–100 lines total.

#### `providers.cli{ name, cmd, parse_response?, env? }`

Generic builder. Returns a `luai.Provider`.

- `name`: string used in error messages.
- `cmd`: either `string[]` (static argv) or `fun(prompt: string, opts: table): string[]` (dynamic argv). The prompt is the last argv element by convention; builders typically end with `..., prompt`.
- `parse_response`: optional `fun(stdout: string, stderr: string, exit_code: integer): string`. Default: returns stdout unchanged (the plugin's `normalize_generated_code` trims and strips fences downstream).
- `env`: optional table merged into the child env.

Responsibilities:
- Resolve `cmd` (call it with `(prompt, opts)` if it's a function).
- Verify the executable exists (`vim.fn.executable(argv[1]) == 1`), error with provider name if not.
- Call `vim.system(argv, { text = true, env = ... }):wait()`.
- On non-zero exit, error with stderr (or stdout if stderr is empty) and the provider name.
- Otherwise, run `parse_response` and return its result.

#### `providers.cursor_agent{ model }`

Thin wrapper around `cli`:

```
agent -p --mode ask --output-format json --model <model> --trust --workspace <cwd> <prompt>
```

- `model`: default model, overridable via `opts.__model`.
- `parse_response`: `vim.json.decode(stdout).result` (error if the field is missing or not a string).
- Name: `"cursor_agent"`.

#### `providers.claude_code{ model }`

Thin wrapper around `cli`:

```
claude -p --output-format json --model <model> <prompt>
```

- `model`: default model (e.g. `"sonnet"`), overridable via `opts.__model`.
- `parse_response`: `vim.json.decode(stdout).result`. Claude Code's headless JSON output uses the same `.result` field.
- Name: `"claude_code"`.

### Wiring in `lua/luai.lua`

- `config` shape changes from `{ model = string }` to `{ providers = table, default_provider = string }`.
- `request_generation` is deleted.
- New helper `dispatch_to_provider(prompt, opts)`:
  - Reads `opts.__provider or config.default_provider`.
  - Looks the name up in `config.providers`.
  - Errors clearly if the name is unknown or no providers are configured.
  - Calls the provider with `(prompt, opts)` and returns the result.
- `generate_new_function` replaces its `request_generation(...)` call with `dispatch_to_provider(new_prompt.prompt, opts.options)`.

The rest of the file (prompt construction, `normalize_generated_code`, `validate_generated_code`, on-disk file format, caching, `demand` / `improve` / `M.generate`) is untouched.

### Data flow

```
generate_new_function(opts)
  build prompt via lua/luai/prompt.lua
  dispatch_to_provider(prompt, opts.options)
    pick provider by opts.__provider or config.default_provider
    provider(prompt, opts)
      build argv (static or dynamic)
      vim.system(argv):wait()
      parse_response(stdout, stderr, code)
  normalize_generated_code(...)
  validate via loadstring
  store on disk
```

### Error handling

| Case | Error message |
|---|---|
| No providers configured | `[luai] no providers configured. Pass providers = {...} to setup().` |
| Unknown `__provider` name | `[luai] unknown provider: <name>. Configured: <a, b, c>` |
| Executable missing | `[luai] <provider-name>: command not on PATH: <argv[0]>` |
| Non-zero exit | `[luai] <provider-name> failed: <stderr or stdout>` |
| JSON decode failure | `[luai] <provider-name>: invalid JSON response:\n<stdout>` |
| Missing `.result` field | `[luai] <provider-name>: JSON did not contain a string \`result\` field:\n<stdout>` |
| Generic provider error from `cli` | error inside the provider, prefixed with provider name |

Errors are raised at generation time, not at `setup{}` — so calling `setup{}` with bad config won't break unrelated init order.

### Backward compatibility

None. Clean break. The old `setup { model = "..." }` form is removed; calling it errors when a `demand`/`generate`/`improve` runs because no providers are configured. The README and `test/manual.lua` are updated to show the new form.

The on-disk format of generated function files does not change; existing files in `lua/luai/demo/` keep working without modification.

## Testing

The project has no test runner. Verification stays in `test/manual.lua` (the `:luafile` scratchpad).

A new fold block is added that:
1. Calls `setup{}` with both `cursor_agent` and `claude_code` providers.
2. Runs a trivial `demand("luai.demo").something { ... }` to confirm the default provider path.
3. Runs the same call with `__provider = "fast"` to confirm per-call override.

The existing demo blocks in `test/manual.lua` continue to be the smoke-test for the rest of the pipeline.

## File-impact summary

| File | Change |
|---|---|
| `lua/luai.lua` | Remove `request_generation`. Replace with `dispatch_to_provider`. Update `config` shape. ~30 lines net delta. |
| `lua/luai/providers.lua` | New. `cli` builder + `cursor_agent` + `claude_code`. ~80–100 lines. |
| `README.md` | Rewrite Setup section and the per-call model override note. Add Claude Code example. |
| `test/manual.lua` | New folded block exercising the provider config. |

## Open questions

None. All design decisions resolved during brainstorming.
