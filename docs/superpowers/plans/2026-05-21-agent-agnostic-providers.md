# Agent-Agnostic Providers Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the hard-coded Cursor Agent invocation in `luai.nvim` with a pluggable provider interface so any CLI agent can drive generation; ship `cursor_agent` + `claude_code` + a generic `cli` builder.

**Architecture:** A provider is a Lua function `(prompt, opts) -> raw_text`. Users register a named registry in `setup{}` and pick one per-call via `opts.__provider`. The two built-in providers are thin wrappers around a single `cli` builder that handles `vim.system` invocation, executable checks, and error formatting. The rest of the plugin (prompt construction, normalisation, on-disk file format, caching) is untouched.

**Tech Stack:** Lua 5.1, Neovim runtime (`vim.system`, `vim.json`, `vim.fn.executable`). No external test framework — verification uses `nvim --headless --noplugin -u NONE -l <spec>.lua` with stubbed `vim.system`, plus an end-to-end manual block in `test/manual.lua`.

**Spec:** `docs/superpowers/specs/2026-05-21-agent-agnostic-providers-design.md`

---

## File Structure

| File | Action | Responsibility |
|---|---|---|
| `lua/luai/providers.lua` | **Create** | `cli{name,cmd,parse_response,env}` builder + `cursor_agent{model}` + `claude_code{model}` thin wrappers. Single file, ~100 lines. |
| `lua/luai.lua` | **Modify** | Drop `request_generation` and `config.model`. Add `config.providers` + `config.default_provider`. Add internal `dispatch_to_provider`; expose as `M._dispatch_to_provider` for tests. Rewire `generate_new_function` to call dispatch. |
| `test/providers_spec.lua` | **Create** | Headless smoke tests for the providers module — stub `vim.system` and `vim.fn.executable` to verify argv construction, error paths, and JSON parsing. |
| `test/dispatch_spec.lua` | **Create** | Headless smoke tests for `luai._dispatch_to_provider` — verify default routing, per-call override, and error messages. |
| `test/manual.lua` | **Modify** | Add a new fold-marked block that wires up real `cursor_agent` + `claude_code` providers and runs a fresh `demand(...)` to exercise the end-to-end path interactively. |
| `README.md` | **Modify** | Rewrite Setup section to show the named-registry config and add a Claude Code example. Update the per-call override note (`__provider` and `__model`). |

---

## Task 1: Skeleton providers module and import smoke test

**Files:**
- Create: `lua/luai/providers.lua`
- Create: `test/providers_spec.lua`

- [ ] **Step 1: Write the failing import test**

Create `test/providers_spec.lua`:
```lua
-- Run with: nvim --headless --noplugin -u NONE -l test/providers_spec.lua
vim.opt.rtp:append "."

local providers = require "luai.providers"

assert(type(providers.cli) == "function", "providers.cli must be a function")
assert(type(providers.cursor_agent) == "function", "providers.cursor_agent must be a function")
assert(type(providers.claude_code) == "function", "providers.claude_code must be a function")
print "PASS: providers module exports"
```

- [ ] **Step 2: Run, confirm it fails because the module doesn't exist**

```bash
nvim --headless --noplugin -u NONE -l test/providers_spec.lua
```

Expected: error along the lines of `module 'luai.providers' not found`, non-zero exit.

- [ ] **Step 3: Create the skeleton module**

Create `lua/luai/providers.lua`:
```lua
---@alias luai.Provider fun(prompt: string, opts: table): string

local M = {}

---@param _spec table
---@return luai.Provider
function M.cli(_spec)
  error "luai.providers.cli: not implemented yet"
end

---@param _spec table
---@return luai.Provider
function M.cursor_agent(_spec)
  error "luai.providers.cursor_agent: not implemented yet"
end

---@param _spec table
---@return luai.Provider
function M.claude_code(_spec)
  error "luai.providers.claude_code: not implemented yet"
end

return M
```

- [ ] **Step 4: Re-run and verify the import test now passes**

```bash
nvim --headless --noplugin -u NONE -l test/providers_spec.lua
```

Expected stdout contains `PASS: providers module exports` and exit code 0.

- [ ] **Step 5: Commit**

```bash
git add lua/luai/providers.lua test/providers_spec.lua
git commit -m "feat(providers): skeleton module with cli/cursor_agent/claude_code exports"
```

---

## Task 2: `cli` builder — static argv happy path

**Files:**
- Modify: `lua/luai/providers.lua`
- Modify: `test/providers_spec.lua`

- [ ] **Step 1: Append the failing test**

Append to `test/providers_spec.lua`:
```lua
-- Test: cli with a static argv list invokes vim.system with that argv and
-- returns stdout unchanged when no parse_response is given.
do
  local captured_argv, captured_opts
  vim.system = function(argv, opts)
    captured_argv = argv
    captured_opts = opts
    return {
      wait = function()
        return { code = 0, stdout = "raw response text", stderr = "" }
      end,
    }
  end
  vim.fn.executable = function(_) return 1 end

  local p = providers.cli {
    name = "test",
    cmd = { "fake-cli", "--flag", "value" },
  }

  local result = p("my prompt", { foo = 1 })
  assert(result == "raw response text", "expected stdout returned unchanged, got: " .. tostring(result))
  assert(captured_argv[1] == "fake-cli")
  assert(captured_argv[2] == "--flag")
  assert(captured_argv[3] == "value")
  assert(captured_opts.text == true, "vim.system called with text=true")
  print "PASS: cli static argv"
end
```

- [ ] **Step 2: Run, confirm the new block fails**

```bash
nvim --headless --noplugin -u NONE -l test/providers_spec.lua
```

Expected: error from inside the new block (`cli: not implemented yet`), exit non-zero.

- [ ] **Step 3: Implement `M.cli`**

Replace the `M.cli` body in `lua/luai/providers.lua`:
```lua
---@param spec { name: string, cmd: string[]|fun(prompt: string, opts: table): string[], parse_response?: fun(stdout: string, stderr: string, exit_code: integer): string, env?: table }
---@return luai.Provider
function M.cli(spec)
  assert(spec and type(spec.name) == "string", "luai.providers.cli: `name` is required")
  assert(spec and spec.cmd, "luai.providers.cli: `cmd` is required")

  return function(prompt, opts)
    local argv = type(spec.cmd) == "function" and spec.cmd(prompt, opts) or spec.cmd
    assert(type(argv) == "table" and argv[1], "luai.providers.cli: cmd must produce a non-empty argv list")

    if vim.fn.executable(argv[1]) ~= 1 then
      error(string.format("[luai] %s: command not on PATH: %s", spec.name, argv[1]))
    end

    local result = vim.system(argv, { text = true, env = spec.env }):wait()
    local stdout = result.stdout or ""
    local stderr = result.stderr or ""

    if result.code ~= 0 then
      local trimmed_err = vim.trim(stderr)
      local trimmed_out = vim.trim(stdout)
      local details = trimmed_err ~= "" and trimmed_err or trimmed_out
      if details == "" then
        details = "exit code " .. tostring(result.code)
      end
      error(string.format("[luai] %s failed: %s", spec.name, details))
    end

    if spec.parse_response then
      return spec.parse_response(stdout, stderr, result.code)
    end

    return stdout
  end
end
```

- [ ] **Step 4: Re-run, verify both PASS lines print**

```bash
nvim --headless --noplugin -u NONE -l test/providers_spec.lua
```

Expected: stdout contains `PASS: providers module exports` and `PASS: cli static argv`, exit 0.

- [ ] **Step 5: Commit**

```bash
git add lua/luai/providers.lua test/providers_spec.lua
git commit -m "feat(providers): cli builder with static argv"
```

---

## Task 3: `cli` builder — `cmd` as a function

**Files:**
- Modify: `test/providers_spec.lua`

(No source change — the implementation already branches on `type(spec.cmd) == "function"`. We add the test to lock that contract in.)

- [ ] **Step 1: Append the test**

Append to `test/providers_spec.lua`:
```lua
-- Test: cmd as function receives (prompt, opts) and its return value is the argv.
do
  local seen_prompt, seen_opts, captured_argv
  vim.system = function(argv, _)
    captured_argv = argv
    return {
      wait = function()
        return { code = 0, stdout = "ok", stderr = "" }
      end,
    }
  end
  vim.fn.executable = function(_) return 1 end

  local p = providers.cli {
    name = "dyn",
    cmd = function(prompt, opts)
      seen_prompt = prompt
      seen_opts = opts
      return { "tool", "--prompt", prompt }
    end,
  }

  p("hello", { x = 1 })
  assert(seen_prompt == "hello", "prompt forwarded to cmd fn")
  assert(seen_opts.x == 1, "opts forwarded to cmd fn")
  assert(captured_argv[1] == "tool")
  assert(captured_argv[3] == "hello")
  print "PASS: cli dynamic argv"
end
```

- [ ] **Step 2: Run and verify all three blocks pass**

```bash
nvim --headless --noplugin -u NONE -l test/providers_spec.lua
```

Expected: three `PASS:` lines, exit 0.

- [ ] **Step 3: Commit**

```bash
git add test/providers_spec.lua
git commit -m "test(providers): cli builder accepts cmd as function"
```

---

## Task 4: `cli` builder — error paths and `parse_response`

**Files:**
- Modify: `test/providers_spec.lua`

- [ ] **Step 1: Append three error-path tests + parse_response test**

Append to `test/providers_spec.lua`:
```lua
-- Test: missing executable errors with provider name and missing command.
do
  vim.fn.executable = function(_) return 0 end
  vim.system = function(_, _)
    error "vim.system should not be called when executable is missing"
  end

  local p = providers.cli { name = "nope", cmd = { "missing-binary" } }
  local ok, err = pcall(p, "", {})
  assert(not ok, "should have errored")
  assert(err:match "nope", "error mentions provider name: " .. tostring(err))
  assert(err:match "missing%-binary", "error mentions missing command: " .. tostring(err))
  print "PASS: cli missing executable errors"
end

-- Test: non-zero exit code surfaces stderr in the error.
do
  vim.fn.executable = function(_) return 1 end
  vim.system = function(_, _)
    return {
      wait = function()
        return { code = 2, stdout = "", stderr = "boom" }
      end,
    }
  end

  local p = providers.cli { name = "fail", cmd = { "x" } }
  local ok, err = pcall(p, "", {})
  assert(not ok)
  assert(err:match "fail failed", "error mentions <name> failed: " .. tostring(err))
  assert(err:match "boom", "error includes stderr: " .. tostring(err))
  print "PASS: cli non-zero exit errors"
end

-- Test: non-zero exit with empty stderr falls back to stdout.
do
  vim.fn.executable = function(_) return 1 end
  vim.system = function(_, _)
    return {
      wait = function()
        return { code = 3, stdout = "out-only", stderr = "" }
      end,
    }
  end

  local p = providers.cli { name = "f2", cmd = { "x" } }
  local ok, err = pcall(p, "", {})
  assert(not ok)
  assert(err:match "out%-only", "error falls back to stdout when stderr empty: " .. tostring(err))
  print "PASS: cli non-zero exit falls back to stdout"
end

-- Test: parse_response transforms stdout into the returned value.
do
  vim.fn.executable = function(_) return 1 end
  vim.system = function(_, _)
    return {
      wait = function()
        return { code = 0, stdout = '{"result":"parsed"}', stderr = "" }
      end,
    }
  end

  local p = providers.cli {
    name = "p",
    cmd = { "x" },
    parse_response = function(stdout)
      return vim.json.decode(stdout).result
    end,
  }
  assert(p("", {}) == "parsed", "parse_response result returned")
  print "PASS: cli parse_response"
end
```

- [ ] **Step 2: Run and verify 7 PASS lines**

```bash
nvim --headless --noplugin -u NONE -l test/providers_spec.lua
```

Expected: 7 `PASS:` lines, exit 0.

- [ ] **Step 3: Commit**

```bash
git add test/providers_spec.lua
git commit -m "test(providers): cli error paths and parse_response"
```

---

## Task 5: `cursor_agent` provider

**Files:**
- Modify: `lua/luai/providers.lua`
- Modify: `test/providers_spec.lua`

- [ ] **Step 1: Append two cursor_agent tests**

Append to `test/providers_spec.lua`:
```lua
-- Test: cursor_agent builds the documented argv and extracts .result.
do
  local captured_argv
  vim.fn.executable = function(_) return 1 end
  vim.system = function(argv, _)
    captured_argv = argv
    return {
      wait = function()
        return {
          code = 0,
          stdout = '{"result": "return function(opts) end"}',
          stderr = "",
        }
      end,
    }
  end

  local p = providers.cursor_agent { model = "composer-2-fast" }
  local result = p("my prompt", {})
  assert(result == "return function(opts) end", "extracts .result")

  assert(captured_argv[1] == "agent", "argv[1] == 'agent'")
  assert(vim.list_contains(captured_argv, "-p"))
  assert(vim.list_contains(captured_argv, "--mode"))
  assert(vim.list_contains(captured_argv, "ask"))
  assert(vim.list_contains(captured_argv, "--output-format"))
  assert(vim.list_contains(captured_argv, "json"))
  assert(vim.list_contains(captured_argv, "--model"))
  assert(vim.list_contains(captured_argv, "composer-2-fast"))
  assert(vim.list_contains(captured_argv, "--trust"))
  assert(vim.list_contains(captured_argv, "--workspace"))
  assert(captured_argv[#captured_argv] == "my prompt", "prompt is the last argv element")
  print "PASS: cursor_agent argv + JSON parse"
end

-- Test: opts.__model overrides the default model.
do
  local captured_argv
  vim.fn.executable = function(_) return 1 end
  vim.system = function(argv, _)
    captured_argv = argv
    return {
      wait = function()
        return { code = 0, stdout = '{"result":"x"}', stderr = "" }
      end,
    }
  end

  local p = providers.cursor_agent { model = "composer-2-fast" }
  p("prompt", { __model = "gpt-5.4-medium-fast" })
  assert(vim.list_contains(captured_argv, "gpt-5.4-medium-fast"))
  assert(not vim.list_contains(captured_argv, "composer-2-fast"))
  print "PASS: cursor_agent __model override"
end

-- Test: invalid JSON from the agent surfaces a clear provider-named error.
do
  vim.fn.executable = function(_) return 1 end
  vim.system = function(_, _)
    return {
      wait = function()
        return { code = 0, stdout = "not json at all", stderr = "" }
      end,
    }
  end

  local p = providers.cursor_agent { model = "composer-2-fast" }
  local ok, err = pcall(p, "", {})
  assert(not ok)
  assert(err:match "cursor_agent: invalid JSON", "error names provider + says invalid JSON: " .. tostring(err))
  print "PASS: cursor_agent invalid JSON errors"
end

-- Test: JSON without a string `.result` field surfaces a clear error.
do
  vim.fn.executable = function(_) return 1 end
  vim.system = function(_, _)
    return {
      wait = function()
        return { code = 0, stdout = '{"other":"x"}', stderr = "" }
      end,
    }
  end

  local p = providers.cursor_agent { model = "composer-2-fast" }
  local ok, err = pcall(p, "", {})
  assert(not ok)
  assert(err:match "result", "error mentions the missing field: " .. tostring(err))
  print "PASS: cursor_agent missing .result errors"
end
```

- [ ] **Step 2: Run, confirm cursor_agent blocks fail**

```bash
nvim --headless --noplugin -u NONE -l test/providers_spec.lua
```

Expected: error `cursor_agent: not implemented yet`.

- [ ] **Step 3: Add the `json_result` helper and implement `M.cursor_agent`**

In `lua/luai/providers.lua`, add a helper above `M.cli` (or below — order does not matter since both are inside the module):
```lua
local function json_result(provider_name)
  return function(stdout, _stderr, _code)
    local ok, decoded = pcall(vim.json.decode, stdout)
    if not ok then
      error(string.format("[luai] %s: invalid JSON response:\n%s", provider_name, stdout))
    end
    if type(decoded) ~= "table" or type(decoded.result) ~= "string" then
      error(string.format("[luai] %s: JSON did not contain a string `result` field:\n%s", provider_name, stdout))
    end
    return decoded.result
  end
end
```

Replace `M.cursor_agent` with:
```lua
---@param spec { model: string }
---@return luai.Provider
function M.cursor_agent(spec)
  assert(spec and type(spec.model) == "string", "luai.providers.cursor_agent: `model` is required")

  return M.cli {
    name = "cursor_agent",
    cmd = function(prompt, opts)
      local model = opts.__model or spec.model
      local workspace = vim.uv.cwd() or vim.fn.getcwd()
      return {
        "agent",
        "-p",
        "--mode", "ask",
        "--output-format", "json",
        "--model", model,
        "--trust",
        "--workspace", workspace,
        prompt,
      }
    end,
    parse_response = json_result "cursor_agent",
  }
end
```

- [ ] **Step 4: Re-run, verify 11 PASS lines**

```bash
nvim --headless --noplugin -u NONE -l test/providers_spec.lua
```

Expected: 11 `PASS:` lines, exit 0.

- [ ] **Step 5: Commit**

```bash
git add lua/luai/providers.lua test/providers_spec.lua
git commit -m "feat(providers): cursor_agent as thin wrapper over cli"
```

---

## Task 6: `claude_code` provider

**Files:**
- Modify: `lua/luai/providers.lua`
- Modify: `test/providers_spec.lua`

- [ ] **Step 1: Append two claude_code tests**

Append to `test/providers_spec.lua`:
```lua
-- Test: claude_code builds expected argv and extracts .result.
do
  local captured_argv
  vim.fn.executable = function(_) return 1 end
  vim.system = function(argv, _)
    captured_argv = argv
    return {
      wait = function()
        return {
          code = 0,
          stdout = '{"result":"return function(opts) end"}',
          stderr = "",
        }
      end,
    }
  end

  local p = providers.claude_code { model = "sonnet" }
  local result = p("my prompt", {})
  assert(result == "return function(opts) end")

  assert(captured_argv[1] == "claude")
  assert(vim.list_contains(captured_argv, "-p"))
  assert(vim.list_contains(captured_argv, "--output-format"))
  assert(vim.list_contains(captured_argv, "json"))
  assert(vim.list_contains(captured_argv, "--model"))
  assert(vim.list_contains(captured_argv, "sonnet"))
  assert(captured_argv[#captured_argv] == "my prompt", "prompt is last argv element")
  print "PASS: claude_code argv + JSON parse"
end

-- Test: opts.__model overrides default model.
do
  local captured_argv
  vim.fn.executable = function(_) return 1 end
  vim.system = function(argv, _)
    captured_argv = argv
    return {
      wait = function()
        return { code = 0, stdout = '{"result":"x"}', stderr = "" }
      end,
    }
  end

  local p = providers.claude_code { model = "sonnet" }
  p("prompt", { __model = "opus" })
  assert(vim.list_contains(captured_argv, "opus"))
  assert(not vim.list_contains(captured_argv, "sonnet"))
  print "PASS: claude_code __model override"
end
```

- [ ] **Step 2: Run, confirm claude_code blocks fail**

```bash
nvim --headless --noplugin -u NONE -l test/providers_spec.lua
```

Expected: error `claude_code: not implemented yet`.

- [ ] **Step 3: Implement `M.claude_code`**

In `lua/luai/providers.lua`, replace the `M.claude_code` body:
```lua
---@param spec { model: string }
---@return luai.Provider
function M.claude_code(spec)
  assert(spec and type(spec.model) == "string", "luai.providers.claude_code: `model` is required")

  return M.cli {
    name = "claude_code",
    cmd = function(prompt, opts)
      local model = opts.__model or spec.model
      return {
        "claude",
        "-p",
        "--output-format", "json",
        "--model", model,
        prompt,
      }
    end,
    parse_response = json_result "claude_code",
  }
end
```

- [ ] **Step 4: Re-run, verify 13 PASS lines**

```bash
nvim --headless --noplugin -u NONE -l test/providers_spec.lua
```

Expected: 13 `PASS:` lines, exit 0.

- [ ] **Step 5: Commit**

```bash
git add lua/luai/providers.lua test/providers_spec.lua
git commit -m "feat(providers): claude_code as thin wrapper over cli"
```

---

## Task 7: Rewire `lua/luai.lua` to dispatch through providers

**Files:**
- Modify: `lua/luai.lua`
- Create: `test/dispatch_spec.lua`

This is the cutover: drop `request_generation`, drop `config.model`, add `dispatch_to_provider`, and route `generate_new_function` through it. After this task the plugin no longer touches `agent` directly.

- [ ] **Step 1: Write the failing dispatch test**

Create `test/dispatch_spec.lua`:
```lua
-- Run with: nvim --headless --noplugin -u NONE -l test/dispatch_spec.lua
vim.opt.rtp:append "."

package.loaded["luai"] = nil
local luai = require "luai"

-- Test: no providers configured -> clear error.
do
  luai.setup {}
  local ok, err = pcall(luai._dispatch_to_provider, "prompt", {})
  assert(not ok, "dispatch must error when no providers configured")
  assert(err:match "no providers configured", "error mentions missing providers: " .. tostring(err))
  print "PASS: dispatch errors when no providers configured"
end

-- Test: default routing picks `default_provider`.
do
  local seen_name
  luai.setup {
    providers = {
      default = function(prompt, opts) seen_name = "default"; return "from-default" end,
      other = function(prompt, opts) seen_name = "other"; return "from-other" end,
    },
    default_provider = "default",
  }

  local result = luai._dispatch_to_provider("prompt", {})
  assert(result == "from-default")
  assert(seen_name == "default")
  print "PASS: dispatch picks default_provider"
end

-- Test: opts.__provider overrides default.
do
  luai.setup {
    providers = {
      default = function(_, _) return "from-default" end,
      fast = function(_, _) return "from-fast" end,
    },
    default_provider = "default",
  }

  local result = luai._dispatch_to_provider("prompt", { __provider = "fast" })
  assert(result == "from-fast", "got: " .. tostring(result))
  print "PASS: dispatch honors opts.__provider"
end

-- Test: unknown provider name -> clear error listing configured names.
do
  luai.setup {
    providers = {
      a = function(_, _) return "" end,
      b = function(_, _) return "" end,
    },
    default_provider = "a",
  }

  local ok, err = pcall(luai._dispatch_to_provider, "prompt", { __provider = "ghost" })
  assert(not ok)
  assert(err:match "unknown provider: ghost", "error names the bad provider: " .. tostring(err))
  -- Configured list is unordered; check both names are mentioned.
  assert(err:match "a" and err:match "b", "error lists configured providers: " .. tostring(err))
  print "PASS: dispatch errors on unknown provider"
end

-- Test: provider receives (prompt, opts) unchanged.
do
  local seen_prompt, seen_opts
  luai.setup {
    providers = {
      default = function(prompt, opts)
        seen_prompt = prompt
        seen_opts = opts
        return "ok"
      end,
    },
    default_provider = "default",
  }

  luai._dispatch_to_provider("the prompt", { __model = "x", foo = 1 })
  assert(seen_prompt == "the prompt")
  assert(seen_opts.__model == "x")
  assert(seen_opts.foo == 1)
  print "PASS: dispatch forwards prompt and opts unchanged"
end
```

- [ ] **Step 2: Run, confirm it fails (`_dispatch_to_provider` not exposed yet)**

```bash
nvim --headless --noplugin -u NONE -l test/dispatch_spec.lua
```

Expected: error `attempt to call a nil value (field '_dispatch_to_provider')` or similar.

- [ ] **Step 3: Update `config` shape in `lua/luai.lua`**

Open `lua/luai.lua`. Replace the existing config block (currently at the top of the module):

```lua
local config = {
  model = "composer-2-fast",
}
```

with:

```lua
local config = {
  ---@type table<string, luai.Provider>
  providers = {},
  ---@type string
  default_provider = "default",
}
```

Update the `luai.Settings` LuaCATS class definition (just below) from:

```lua
---@class luai.Settings
---@field model? string: Default Cursor Agent model. Defaults to `composer-2-fast`.
```

to:

```lua
---@class luai.Settings
---@field providers? table<string, luai.Provider>: Named provider registry. Required for generation.
---@field default_provider? string: Key into `providers` used when `opts.__provider` is not set. Defaults to `"default"`.
```

- [ ] **Step 4: Delete the `request_generation` function from `lua/luai.lua`**

Remove the entire block:

```lua
---@param prompt string
---@param model string
---@return string
local request_generation = function(prompt, model)
  if vim.fn.executable "agent" ~= 1 then
    error "[luai] Could not find `agent` on PATH. Install Cursor Agent CLI and make sure it is available in your shell."
  end

  local workspace = vim.uv.cwd() or vim.fn.getcwd()
  local result = vim.system({
    "agent",
    "-p",
    "--mode",
    "ask",
    "--output-format",
    "json",
    "--model",
    model,
    "--trust",
    "--workspace",
    workspace,
    prompt,
  }, { text = true }):wait()

  local stdout = result.stdout or ""
  local stderr = result.stderr or ""

  if result.code ~= 0 then
    stderr = vim.trim(stderr)
    stdout = vim.trim(stdout)
    local details = stderr ~= "" and stderr or stdout
    if details ~= "" then
      error(string.format("[luai] Cursor Agent request failed: %s", details))
    end

    error(string.format("[luai] Cursor Agent request failed with exit code %s", result.code))
  end

  local ok, decoded = pcall(vim.json.decode, stdout)
  if not ok then
    error(string.format("[luai] Cursor Agent returned invalid JSON:\n%s", stdout))
  end

  if type(decoded) ~= "table" or type(decoded.result) ~= "string" then
    error(string.format("[luai] Cursor Agent JSON did not contain a string `result` field:\n%s", stdout))
  end

  return decoded.result
end
```

- [ ] **Step 5: Add `dispatch_to_provider` in its place**

In the same spot in `lua/luai.lua`, insert:

```lua
---@param prompt string
---@param opts table: The user opts table, including `__provider` and other `__` control keys.
---@return string
local dispatch_to_provider = function(prompt, opts)
  if not config.providers or next(config.providers) == nil then
    error "[luai] no providers configured. Pass providers = {...} to setup()."
  end

  local name = opts.__provider or config.default_provider
  local provider = config.providers[name]
  if type(provider) ~= "function" then
    local available = table.concat(vim.tbl_keys(config.providers), ", ")
    error(string.format("[luai] unknown provider: %s. Configured: %s", tostring(name), available))
  end

  return provider(prompt, opts)
end

M._dispatch_to_provider = dispatch_to_provider
```

- [ ] **Step 6: Rewire `generate_new_function`**

Find this block in `lua/luai.lua`:
```lua
local generate_new_function = function(opts)
  print("[luai] generating new function:", opts.function_name)

  local new_prompt = require "luai.prompt"(opts)
  local model = opts.options.__model or config.model
  local response_text = request_generation(new_prompt.prompt, model)
  local implementation = normalize_generated_code(response_text)
  -- ...
end
```

Replace the two `request_generation`-related lines with a single dispatch call:
```lua
local generate_new_function = function(opts)
  print("[luai] generating new function:", opts.function_name)

  local new_prompt = require "luai.prompt"(opts)
  local response_text = dispatch_to_provider(new_prompt.prompt, opts.options)
  local implementation = normalize_generated_code(response_text)
  -- ...
end
```

- [ ] **Step 7: Run the dispatch spec, verify all PASS**

```bash
nvim --headless --noplugin -u NONE -l test/dispatch_spec.lua
```

Expected: 5 `PASS:` lines, exit 0.

- [ ] **Step 8: Re-run the providers spec to confirm nothing regressed**

```bash
nvim --headless --noplugin -u NONE -l test/providers_spec.lua
```

Expected: 13 `PASS:` lines, exit 0.

- [ ] **Step 9: Commit**

```bash
git add lua/luai.lua test/dispatch_spec.lua
git commit -m "feat(luai): dispatch generation through a named provider registry"
```

---

## Task 8: Update `README.md` with the new config + Claude Code example

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Replace the Setup section**

Find the current Setup section (lines 5-23 of README.md) and replace it entirely with:

````markdown
## Setup

`luai.nvim` no longer talks to any single CLI agent. You configure one or more **providers** in `setup{}`, give one a default key, and `luai` will dispatch generation through them.

### Example — Claude Code

```lua
local providers = require "luai.providers"

require("luai").setup {
  providers = {
    default = providers.claude_code { model = "sonnet" },
    fast    = providers.claude_code { model = "haiku" },
  },
  default_provider = "default",
}
```

This shells out to:

```bash
claude -p --output-format json --model sonnet "<prompt>"
```

and reads `.result` from the JSON response, which must contain Lua code that starts with `return function(opts)` and ends with `end`.

### Example — Cursor Agent

```lua
local providers = require "luai.providers"

require("luai").setup {
  providers = {
    default = providers.cursor_agent { model = "composer-2-fast" },
  },
  default_provider = "default",
}
```

This shells out to:

```bash
agent -p --mode ask --output-format json --model composer-2-fast --trust --workspace "$PWD" "<prompt>"
```

### Example — any other CLI agent

`luai.providers.cli` wraps any CLI that takes a prompt as an argv element and prints the response on stdout:

```lua
local providers = require "luai.providers"

local aichat = providers.cli {
  name = "aichat",
  cmd = function(prompt, _opts) return { "aichat", "--no-stream", prompt } end,
  -- parse_response is optional; default returns stdout unchanged.
}

require("luai").setup {
  providers = { default = aichat },
  default_provider = "default",
}
```

A provider is just a function `(prompt, opts) -> raw_text`, so you can write one inline if you prefer.

### Per-call overrides

- `__provider = "fast"` in an opts table switches to a named provider for one call.
- `__model = "opus"` is forwarded to the provider; the built-in `cursor_agent` and `claude_code` honour it.

```lua
demand("custom.utils").create_floating_window {
  __provider = "fast",
  __model = "haiku",
  title = "Hello",
}
```

If you call any luai entry point before configuring providers, you'll get `[luai] no providers configured. Pass providers = {...} to setup().`

`luai.nvim` normalises and validates the provider's response — code fences, `<lua_function>` tags, and small amounts of leading prose are tolerated as long as the body parses with `loadstring`.
````

- [ ] **Step 2: Sanity-check the rest of the README**

Open `README.md` and confirm the `demand`, `generate`, and `improve` sections still match the code (they don't reference `model` or `agent` directly, so they should be fine as-is).

- [ ] **Step 3: Commit**

```bash
git add README.md
git commit -m "docs: rewrite Setup for the provider registry + Claude Code example"
```

---

## Task 9: Update `test/manual.lua` with a provider-config block

**Files:**
- Modify: `test/manual.lua`

- [ ] **Step 1: Add a setup-and-smoke-test block at the top of the file**

Open `test/manual.lua`. The current top of the file looks like:

```lua
--{{{ Demand an implementation!!
local rtp = vim.split(vim.o.rtp, ";")
if not vim.list_contains(rtp, ".") then
  vim.opt.rtp:append "."
end

local reload = require("plenary.reload").reload_module
reload "luai"
reload "luai.prompt"
reload "luai.prompt.nvim_api"
reload "luai.path"
--}}}
local demand = require("luai").demand
```

Insert a new fold-marked block immediately after the closing `--}}}` of the reload block and before the `local demand = ...` line:

```lua
--{{{ Configure providers (NEW: agent-agnostic setup)
reload "luai.providers"
local providers = require "luai.providers"

require("luai").setup {
  providers = {
    default = providers.claude_code { model = "sonnet" },
    fast    = providers.claude_code { model = "haiku" },
    cursor  = providers.cursor_agent { model = "composer-2-fast" },
  },
  default_provider = "default",
}
--}}}
```

Then, lower in the file, add a new fold block that exercises the per-call provider override. Add it as a sibling of the existing demo blocks, somewhere in the empty space between the existing demos (the exact location doesn't matter — `test/manual.lua` is a scratchpad full of fold-marked snippets, this is just another one). The block:

```lua
--{{{ Per-call provider override (uses `fast` model just for this call)
-- demand("luai.demo").say_hello_with_fast_provider {
--   __provider = "fast",
--   __description = "Print 'hello from fast provider' using vim.notify",
-- }
--}}}
```

Keep the call commented out by default — `test/manual.lua` is read top-to-bottom on `:luafile %` and only the active (un-commented) demand call should run at a time. Uncommenting this block lets the user explicitly verify the override path.

- [ ] **Step 2: Verify the file still parses (no execution — `test/manual.lua` has side effects)**

```bash
nvim --headless --noplugin -u NONE \
  -c 'lua local f, err = loadfile("test/manual.lua"); print(err and ("ERROR: " .. err) or "OK")' \
  -c 'qa'
```

Expected: prints `OK`. If you see `ERROR: ...`, fix the syntax issue (line number is in the error). This only parses — it does not run any `demand(...)` calls, so no agent CLI is invoked and no theme/window side effects happen.

- [ ] **Step 3: Commit**

```bash
git add test/manual.lua
git commit -m "test(manual): exercise the new provider registry config"
```

---

## Task 10: Final verification pass

**Files:** none

- [ ] **Step 1: Run both spec suites one more time**

```bash
nvim --headless --noplugin -u NONE -l test/providers_spec.lua && \
nvim --headless --noplugin -u NONE -l test/dispatch_spec.lua
```

Expected: 13 PASS lines from providers, 5 PASS lines from dispatch, exit 0 from both.

- [ ] **Step 2: Grep for any lingering references to the old config or CLI**

```bash
grep -n 'config.model\|request_generation\|composer-2-fast' lua/ README.md 2>/dev/null
```

Expected: only the `composer-2-fast` string survives, exclusively as the example model in the README's `cursor_agent` example. No live code reference to `config.model` or `request_generation`.

- [ ] **Step 3: Verify the diff against `master` is coherent**

```bash
git log --oneline master..HEAD
git diff master --stat
```

Expected: 9 commits roughly matching the task names; touched files match the File Structure table at the top of this plan.
