# Live Streaming Window Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Open a non-blocking floating window the moment `dispatch_to_provider` runs, stream the agent's stdout into it live, and morph the same window into the existing accept/review flow at completion.

**Architecture:** A new `lua/luai/stream_win.lua` module owns the floating window + buffer (open/append/replace/close API). The `cli` builder in `lua/luai/providers.lua` grows an async branch that triggers when `opts.__on_chunk` is present, using `vim.system`'s callback form + `vim.wait` polling to stay non-blocking. The dispatch layer in `lua/luai.lua` always opens a stream window when actual generation runs, wires a chunk-handler into `opts.__on_chunk`, and returns the stream handle alongside the response so the caller can morph and close it. `claude_code` opts into streaming by switching its argv to `--output-format stream-json` and parsing assistant text deltas; `cursor_agent` stays sync in v1.

**Tech Stack:** Lua 5.1, Neovim runtime (`vim.system` async form, `vim.wait`, `vim.api.nvim_open_win`, `vim.json`, `vim.schedule`). Tests are headless via `nvim --headless --noplugin -u NONE -l <spec>.lua`.

**Spec:** `docs/superpowers/specs/2026-05-22-streaming-window-design.md`

---

## File Structure

| File | Action | Responsibility |
|---|---|---|
| `lua/luai/stream_win.lua` | **Create** | `open(opts) -> { win, buf, append, replace, close }`. Owns floating window geometry, scratch buffer, partial-line append logic, and redraw on each chunk. ~40 lines. |
| `lua/luai/providers.lua` | **Modify** | `M.cli` grows an async branch when `opts.__on_chunk` is set (uses `vim.system` callback form + `vim.wait`). `M.claude_code` switches argv to `--output-format stream-json --verbose` when streaming and parses events. `M.cursor_agent` unchanged. ~80 lines added. |
| `lua/luai.lua` | **Modify** | `dispatch_to_provider` opens the stream window, sets `opts.__on_chunk`, returns `(string, stream)`. `generate_new_function` consumes the second return, morphs the buffer with normalised code, returns `(impl_table, stream)`. Three callers updated (`Generated:__index` review-popup branch, `update_existing_generation`, `Generated:__newindex`, `_require_init` closure) to close the stream at the right moment. ~30 net lines delta. |
| `test/providers_spec.lua` | **Modify** | Three new blocks: cli async happy path with `__on_chunk`, cli async timeout, claude_code stream-json argv + parsing. |
| `test/dispatch_spec.lua` | **Modify** | Stub `luai.stream_win` at the top of the file so all existing tests run unchanged. Add one new block verifying dispatch opens a stream and passes `__on_chunk` to the provider, plus that dispatch returns `(result, stream)`. |

---

## Task 1: `stream_win.lua` skeleton + import smoke test

**Files:**
- Create: `lua/luai/stream_win.lua`
- Create: `test/stream_win_spec.lua`

- [ ] **Step 1: Write the failing import test**

Create `test/stream_win_spec.lua`:
```lua
-- Run with: nvim --headless --noplugin -u NONE -l test/stream_win_spec.lua
vim.opt.rtp:append "."

local stream_win = require "luai.stream_win"
assert(type(stream_win.open) == "function", "stream_win.open must be a function")
print "PASS: stream_win module exports"
```

- [ ] **Step 2: Run, confirm it fails (module doesn't exist)**

```bash
nvim --headless --noplugin -u NONE -l test/stream_win_spec.lua
```

Expected: error `module 'luai.stream_win' not found`, non-zero exit.

- [ ] **Step 3: Create the skeleton module**

Create `lua/luai/stream_win.lua`:
```lua
---@class luai.StreamWin
---@field win integer
---@field buf integer
---@field append fun(chunk: string)
---@field replace fun(lines: string[])
---@field close fun()

local M = {}

---@param _opts? { title?: string }
---@return luai.StreamWin
function M.open(_opts)
  error "luai.stream_win.open: not implemented yet"
end

return M
```

- [ ] **Step 4: Re-run, verify import test passes**

```bash
nvim --headless --noplugin -u NONE -l test/stream_win_spec.lua
```

Expected: `PASS: stream_win module exports`, exit 0.

- [ ] **Step 5: Commit**

```bash
git add lua/luai/stream_win.lua test/stream_win_spec.lua
git commit -m "feat(stream_win): skeleton module with open() export"
```

---

## Task 2: `stream_win.lua` functional implementation

**Files:**
- Modify: `lua/luai/stream_win.lua`
- Modify: `test/stream_win_spec.lua`

- [ ] **Step 1: Append behavior tests**

Append to `test/stream_win_spec.lua`:
```lua
-- Test: open() returns a table with win, buf, and 3 functions; buf starts with one empty line.
do
  local s = stream_win.open { title = "test" }
  assert(type(s.win) == "number", "win is a number")
  assert(type(s.buf) == "number", "buf is a number")
  assert(type(s.append) == "function")
  assert(type(s.replace) == "function")
  assert(type(s.close) == "function")
  assert(vim.api.nvim_buf_line_count(s.buf) == 1, "fresh buffer has one empty line")
  s.close()
  print "PASS: stream_win.open shape"
end

-- Test: append handles partial line (no trailing newline) — appends to the last line in place.
do
  local s = stream_win.open {}
  s.append "hello"
  local lines = vim.api.nvim_buf_get_lines(s.buf, 0, -1, false)
  assert(#lines == 1, "one line after partial chunk")
  assert(lines[1] == "hello", "got: " .. tostring(lines[1]))
  s.close()
  print "PASS: stream_win.append partial line"
end

-- Test: append concatenates further partials onto the same line.
do
  local s = stream_win.open {}
  s.append "hello "
  s.append "world"
  local lines = vim.api.nvim_buf_get_lines(s.buf, 0, -1, false)
  assert(#lines == 1)
  assert(lines[1] == "hello world", "got: " .. tostring(lines[1]))
  s.close()
  print "PASS: stream_win.append concatenates partials"
end

-- Test: append with embedded newline splits into new lines.
do
  local s = stream_win.open {}
  s.append "first\nsecond\nthird"
  local lines = vim.api.nvim_buf_get_lines(s.buf, 0, -1, false)
  assert(#lines == 3, "got " .. #lines .. " lines")
  assert(lines[1] == "first")
  assert(lines[2] == "second")
  assert(lines[3] == "third")
  s.close()
  print "PASS: stream_win.append splits on newline"
end

-- Test: replace overwrites the entire buffer with the given lines array.
do
  local s = stream_win.open {}
  s.append "garbage"
  s.replace { "clean", "code", "here" }
  local lines = vim.api.nvim_buf_get_lines(s.buf, 0, -1, false)
  assert(#lines == 3)
  assert(lines[1] == "clean")
  assert(lines[2] == "code")
  assert(lines[3] == "here")
  s.close()
  print "PASS: stream_win.replace overwrites"
end

-- Test: close deletes the window and buffer.
do
  local s = stream_win.open {}
  s.close()
  assert(not vim.api.nvim_win_is_valid(s.win), "window is invalid after close")
  assert(not vim.api.nvim_buf_is_valid(s.buf), "buffer is invalid after close")
  print "PASS: stream_win.close destroys win and buf"
end
```

- [ ] **Step 2: Run, confirm new blocks fail**

```bash
nvim --headless --noplugin -u NONE -l test/stream_win_spec.lua
```

Expected: error `luai.stream_win.open: not implemented yet` in the second block.

- [ ] **Step 3: Implement `M.open`**

Replace the contents of `lua/luai/stream_win.lua` with:
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
  opts = opts or {}

  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].filetype = "lua"

  local width = math.floor(vim.o.columns * 0.8)
  local height = math.floor(vim.o.lines * 0.8)
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width,
    height = height,
    col = math.floor((vim.o.columns - width) / 2),
    row = math.floor((vim.o.lines - height) / 2),
    style = "minimal",
    border = "rounded",
    title = opts.title or "luai",
    title_pos = "center",
  })

  local function append(chunk)
    if chunk == nil or chunk == "" then
      return
    end
    local last_idx = vim.api.nvim_buf_line_count(buf) - 1
    local current_last = vim.api.nvim_buf_get_lines(buf, last_idx, last_idx + 1, false)[1] or ""
    local combined = current_last .. chunk
    local new_lines = vim.split(combined, "\n", { plain = true })
    vim.api.nvim_buf_set_lines(buf, last_idx, last_idx + 1, false, new_lines)
    pcall(vim.cmd.redraw)
  end

  local function replace(lines)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    pcall(vim.cmd.redraw)
  end

  local function close()
    pcall(vim.api.nvim_win_close, win, true)
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
  end

  return {
    win = win,
    buf = buf,
    append = append,
    replace = replace,
    close = close,
  }
end

return M
```

- [ ] **Step 4: Run, verify all 7 PASS lines**

```bash
nvim --headless --noplugin -u NONE -l test/stream_win_spec.lua
```

Expected: 7 `PASS:` lines (1 import + 6 behavior), exit 0.

- [ ] **Step 5: Commit**

```bash
git add lua/luai/stream_win.lua test/stream_win_spec.lua
git commit -m "feat(stream_win): floating window with append/replace/close API"
```

---

## Task 3: `cli` async path — happy path with `__on_chunk`

**Files:**
- Modify: `lua/luai/providers.lua`
- Modify: `test/providers_spec.lua`

- [ ] **Step 1: Append the failing test**

Append to `test/providers_spec.lua`:
```lua
-- Test: cli with opts.__on_chunk uses vim.system's async/callback form
-- and forwards stdout chunks to __on_chunk; the final return is the concatenated stdout.
do
  local captured_argv, captured_stdout_cb, captured_on_complete
  vim.fn.executable = function(_) return 1 end
  vim.system = function(argv, sys_opts, on_complete)
    captured_argv = argv
    captured_stdout_cb = sys_opts.stdout
    captured_on_complete = on_complete
    vim.schedule(function()
      sys_opts.stdout(nil, "hello ")
      sys_opts.stdout(nil, "world")
      on_complete { code = 0, stdout = "", stderr = "" }
    end)
    return { kill = function(_) end }
  end

  local chunks = {}
  local p = providers.cli {
    name = "stream-test",
    cmd = { "x" },
  }
  local result = p("prompt", {
    __on_chunk = function(c) table.insert(chunks, c) end,
  })

  assert(result == "hello world", "concatenated stdout returned, got: " .. tostring(result))
  assert(#chunks == 2, "two chunks forwarded, got: " .. #chunks)
  assert(chunks[1] == "hello ")
  assert(chunks[2] == "world")
  assert(captured_argv[1] == "x")
  assert(type(captured_on_complete) == "function", "vim.system called in async form (3rd arg)")
  print "PASS: cli async with __on_chunk"
end
```

- [ ] **Step 2: Run, confirm failure**

```bash
nvim --headless --noplugin -u NONE -l test/providers_spec.lua
```

Expected: the new block fails because the cli implementation still uses `:wait()` (sync form), so `vim.system` is called with two args, not three, and `on_complete` is nil. The test asserts `type(captured_on_complete) == "function"` which will fail.

- [ ] **Step 3: Implement the async branch in `M.cli`**

In `lua/luai/providers.lua`, locate the `function M.cli(spec)` body. The returned closure currently looks like:

```lua
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
```

Replace it with:

```lua
return function(prompt, opts)
  local argv = type(spec.cmd) == "function" and spec.cmd(prompt, opts) or spec.cmd
  assert(type(argv) == "table" and argv[1], "luai.providers.cli: cmd must produce a non-empty argv list")

  if vim.fn.executable(argv[1]) ~= 1 then
    error(string.format("[luai] %s: command not on PATH: %s", spec.name, argv[1]))
  end

  local on_chunk = opts.__on_chunk
  local stdout, stderr, code

  if on_chunk then
    local stdout_chunks = {}
    local stderr_chunks = {}
    local done = false

    local sys = vim.system(argv, {
      text = true,
      env = spec.env,
      stdout = function(_, chunk)
        if chunk then
          table.insert(stdout_chunks, chunk)
          vim.schedule(function() on_chunk(chunk) end)
        end
      end,
      stderr = function(_, chunk)
        if chunk then table.insert(stderr_chunks, chunk) end
      end,
    }, function(result)
      code = result.code
      done = true
    end)

    local ok = vim.wait(300000, function() return done end, 50)
    if not ok then
      pcall(function() sys:kill(15) end)
      error(string.format("[luai] %s: generation timed out after 5m", spec.name))
    end

    stdout = table.concat(stdout_chunks)
    stderr = table.concat(stderr_chunks)
  else
    local result = vim.system(argv, { text = true, env = spec.env }):wait()
    stdout = result.stdout or ""
    stderr = result.stderr or ""
    code = result.code
  end

  if code ~= 0 then
    local trimmed_err = vim.trim(stderr)
    local trimmed_out = vim.trim(stdout)
    local details = trimmed_err ~= "" and trimmed_err or trimmed_out
    if details == "" then
      details = "exit code " .. tostring(code)
    end
    error(string.format("[luai] %s failed: %s", spec.name, details))
  end

  if spec.parse_response then
    return spec.parse_response(stdout, stderr, code)
  end

  return stdout
end
```

- [ ] **Step 4: Run, verify all 14 PASS lines**

```bash
nvim --headless --noplugin -u NONE -l test/providers_spec.lua
```

Expected: 14 `PASS:` lines (13 prior + 1 new), exit 0.

- [ ] **Step 5: Commit**

```bash
git add lua/luai/providers.lua test/providers_spec.lua
git commit -m "feat(providers): cli async path forwards stdout chunks via __on_chunk"
```

---

## Task 4: `cli` async path — timeout handling

**Files:**
- Modify: `test/providers_spec.lua`

(Implementation already supports timeout via `vim.wait`; this task adds the regression test.)

- [ ] **Step 1: Append the test**

Append to `test/providers_spec.lua`:
```lua
-- Test: when vim.wait times out, sys:kill is called and an error is raised.
do
  vim.fn.executable = function(_) return 1 end
  local kill_called = false
  vim.system = function(_, _, _on_complete)
    -- Never call on_complete so vim.wait will time out
    return { kill = function(_sig) kill_called = true end }
  end

  -- Monkey-patch vim.wait to return false (timeout) immediately for the test.
  local original_wait = vim.wait
  vim.wait = function(_timeout_ms, _predicate, _interval)
    return false
  end

  local p = providers.cli { name = "slow", cmd = { "x" } }
  local ok, err = pcall(p, "", { __on_chunk = function() end })

  vim.wait = original_wait

  assert(not ok)
  assert(err:match "slow: generation timed out", "error mentions timeout: " .. tostring(err))
  assert(kill_called, "sys:kill should have been called")
  print "PASS: cli async timeout kills child"
end
```

- [ ] **Step 2: Run, verify 15 PASS lines**

```bash
nvim --headless --noplugin -u NONE -l test/providers_spec.lua
```

Expected: 15 `PASS:` lines, exit 0.

- [ ] **Step 3: Commit**

```bash
git add test/providers_spec.lua
git commit -m "test(providers): cli async path kills child on timeout"
```

---

## Task 5: `claude_code` stream-json branch

**Files:**
- Modify: `lua/luai/providers.lua`
- Modify: `test/providers_spec.lua`

- [ ] **Step 1: Append failing tests**

Append to `test/providers_spec.lua`:
```lua
-- Test: claude_code with __on_chunk switches argv to --output-format stream-json --verbose
-- and forwards model text deltas (extracted from assistant events) to user's on_chunk.
do
  local captured_argv
  vim.fn.executable = function(_) return 1 end
  vim.system = function(argv, sys_opts, on_complete)
    captured_argv = argv
    vim.schedule(function()
      -- Emit two assistant events with text and one final result event.
      sys_opts.stdout(nil, '{"type":"assistant","message":{"content":[{"type":"text","text":"hello "}]}}\n')
      sys_opts.stdout(nil, '{"type":"assistant","message":{"content":[{"type":"text","text":"world"}]}}\n')
      sys_opts.stdout(nil, '{"type":"result","result":"return function(opts) end"}\n')
      on_complete { code = 0, stdout = "", stderr = "" }
    end)
    return { kill = function() end }
  end

  local user_chunks = {}
  local p = providers.claude_code { model = "sonnet" }
  local result = p("my prompt", {
    __on_chunk = function(t) table.insert(user_chunks, t) end,
  })

  assert(result == "return function(opts) end", "extracts result from final stream-json event")
  assert(vim.list_contains(captured_argv, "stream-json"), "argv uses stream-json output format")
  assert(vim.list_contains(captured_argv, "--verbose"), "argv includes --verbose")
  assert(vim.list_contains(captured_argv, "sonnet"))
  assert(captured_argv[#captured_argv] == "my prompt")
  assert(#user_chunks == 2, "two text deltas forwarded, got: " .. #user_chunks)
  assert(user_chunks[1] == "hello ")
  assert(user_chunks[2] == "world")
  print "PASS: claude_code stream-json argv + text-delta forwarding"
end

-- Test: claude_code WITHOUT __on_chunk still uses --output-format json (sync path unchanged).
do
  local captured_argv
  vim.fn.executable = function(_) return 1 end
  vim.system = function(argv, _sys_opts)
    captured_argv = argv
    return {
      wait = function()
        return { code = 0, stdout = '{"result":"x"}', stderr = "" }
      end,
    }
  end

  local p = providers.claude_code { model = "sonnet" }
  local result = p("prompt", {})
  assert(result == "x")
  assert(vim.list_contains(captured_argv, "json"))
  assert(not vim.list_contains(captured_argv, "stream-json"))
  print "PASS: claude_code without __on_chunk stays on json path"
end
```

- [ ] **Step 2: Run, confirm failures**

```bash
nvim --headless --noplugin -u NONE -l test/providers_spec.lua
```

Expected: failure inside the new stream-json block (current `claude_code` always uses `--output-format json`, never `stream-json`, and doesn't parse assistant deltas).

- [ ] **Step 3: Implement stream-json branch in `M.claude_code`**

In `lua/luai/providers.lua`, add a helper above `M.claude_code` (or anywhere above its definition):

```lua
local function make_stream_json_parser(user_on_chunk)
  local pending = ""
  local final_result

  local function process_line(line)
    if line == "" then return end
    local ok, event = pcall(vim.json.decode, line)
    if not ok or type(event) ~= "table" then return end

    if event.type == "assistant" and type(event.message) == "table" and type(event.message.content) == "table" then
      for _, content in ipairs(event.message.content) do
        if type(content) == "table" and content.type == "text" and type(content.text) == "string" then
          user_on_chunk(content.text)
        end
      end
    elseif event.type == "result" and type(event.result) == "string" then
      final_result = event.result
    end
  end

  local function consume(raw_chunk)
    pending = pending .. raw_chunk
    while true do
      local nl = pending:find "\n"
      if not nl then break end
      local line = pending:sub(1, nl - 1)
      pending = pending:sub(nl + 1)
      process_line(line)
    end
  end

  local function finalize()
    -- Flush any unterminated trailing line without re-processing what consume
    -- already handled during streaming.
    if pending ~= "" then
      process_line(pending)
      pending = ""
    end
    if final_result == nil then
      error "[luai] claude_code: no result event in stream-json output"
    end
    return final_result
  end

  return {
    consume = consume,
    finalize = finalize,
  }
end
```

Then replace the existing `M.claude_code` body with:

```lua
---@param spec { model: string }
---@return luai.Provider
function M.claude_code(spec)
  assert(spec and type(spec.model) == "string", "luai.providers.claude_code: `model` is required")

  return function(prompt, opts)
    local user_on_chunk = opts.__on_chunk
    local stream = user_on_chunk and make_stream_json_parser(user_on_chunk) or nil

    local provider = M.cli {
      name = "claude_code",
      cmd = function(_prompt, _opts)
        local model = _opts.__model or spec.model
        if stream then
          return {
            "claude",
            "-p",
            "--output-format", "stream-json",
            "--verbose",
            "--model", model,
            _prompt,
          }
        end
        return {
          "claude",
          "-p",
          "--output-format", "json",
          "--model", model,
          _prompt,
        }
      end,
      parse_response = function(stdout, stderr, code)
        if stream then
          return stream.finalize()
        end
        return json_result "claude_code"(stdout, stderr, code)
      end,
    }

    local call_opts = opts
    if stream then
      call_opts = vim.tbl_extend("force", opts, { __on_chunk = stream.consume })
    end

    return provider(prompt, call_opts)
  end
end
```

- [ ] **Step 4: Run, verify 17 PASS lines**

```bash
nvim --headless --noplugin -u NONE -l test/providers_spec.lua
```

Expected: 17 `PASS:` lines (15 prior + 2 new), exit 0.

- [ ] **Step 5: Commit**

```bash
git add lua/luai/providers.lua test/providers_spec.lua
git commit -m "feat(providers): claude_code streams via --output-format stream-json"
```

---

## Task 6: `dispatch_to_provider` opens stream window + returns it

**Files:**
- Modify: `lua/luai.lua`
- Modify: `test/dispatch_spec.lua`

- [ ] **Step 1: Stub `luai.stream_win` at the top of `test/dispatch_spec.lua` and update the existing assertion that ignores the second return**

Open `test/dispatch_spec.lua`. The file currently starts with:
```lua
-- Run with: nvim --headless --noplugin -u NONE -l test/dispatch_spec.lua
vim.opt.rtp:append "."

package.loaded["luai"] = nil
local luai = require "luai"
```

Insert a stub for `luai.stream_win` BEFORE the `require "luai"`:

```lua
-- Run with: nvim --headless --noplugin -u NONE -l test/dispatch_spec.lua
vim.opt.rtp:append "."

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

package.loaded["luai"] = nil
local luai = require "luai"
```

The existing 5 tests will continue to pass since they don't check stream-related return values.

- [ ] **Step 2: Append a new test asserting stream lifecycle**

Append to the end of `test/dispatch_spec.lua`:
```lua
-- Test: dispatch opens a stream window, sets opts.__on_chunk, and returns (result, stream).
do
  local seen_on_chunk
  luai.setup {
    providers = {
      default = function(prompt, opts)
        seen_on_chunk = opts.__on_chunk
        return "ok"
      end,
    },
    default_provider = "default",
  }

  local opens_before = stub_calls.open
  local result, stream = luai._dispatch_to_provider("prompt", {})

  assert(stub_calls.open == opens_before + 1, "stream_win.open was called")
  assert(result == "ok")
  assert(type(seen_on_chunk) == "function", "provider received a callable __on_chunk")
  assert(type(stream) == "table", "second return is the stream handle table")
  assert(type(stream.append) == "function")
  assert(type(stream.replace) == "function")
  assert(type(stream.close) == "function")
  print "PASS: dispatch opens stream and forwards __on_chunk"
end
```

- [ ] **Step 3: Run, confirm failure**

```bash
nvim --headless --noplugin -u NONE -l test/dispatch_spec.lua
```

Expected: failure — the existing dispatch doesn't open a stream, doesn't pass `__on_chunk`, and returns a single value.

- [ ] **Step 4: Update `dispatch_to_provider` in `lua/luai.lua`**

Find `dispatch_to_provider` in `lua/luai.lua`. It currently looks like:

```lua
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
```

Replace it with:

```lua
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

  local stream = require("luai.stream_win").open { title = "luai: generating" }
  opts.__on_chunk = function(chunk) stream.append(chunk) end

  local ok, result = pcall(provider, prompt, opts)
  if not ok then
    stream.close()
    error(result)
  end

  return result, stream
end
```

- [ ] **Step 5: Run the dispatch spec, verify 6 PASS lines**

```bash
nvim --headless --noplugin -u NONE -l test/dispatch_spec.lua
```

Expected: 6 `PASS:` lines (5 prior + 1 new), exit 0.

- [ ] **Step 6: Re-run the providers spec to confirm no regression**

```bash
nvim --headless --noplugin -u NONE -l test/providers_spec.lua
```

Expected: 17 `PASS:` lines, exit 0.

- [ ] **Step 7: Commit**

```bash
git add lua/luai.lua test/dispatch_spec.lua
git commit -m "feat(luai): dispatch opens stream window and returns it alongside result"
```

---

## Task 7: `generate_new_function` consumes the stream and morphs it

**Files:**
- Modify: `lua/luai.lua`

(No new test — existing dispatch tests cover the routing; the morph behaviour is exercised end-to-end via `test/manual.lua`. The callers updated in this task either always discard the stream or pass it up; the discard path is direct, the pass-up is consumed in Task 8.)

- [ ] **Step 1: Update `generate_new_function` to multi-return `(impl, stream)`**

Find `generate_new_function` in `lua/luai.lua`. It currently looks like:

```lua
local generate_new_function = function(opts)
  print("[luai] generating new function:", opts.function_name)

  local new_prompt = require "luai.prompt"(opts)
  local response_text = dispatch_to_provider(new_prompt.prompt, opts.options)
  local implementation = normalize_generated_code(response_text)

  return {
    implementation = implementation,
    description = new_prompt.description,
    option_list = new_prompt.option_list,
    option_example = new_prompt.option_example,
  }
end
```

Replace it with:

```lua
local generate_new_function = function(opts)
  print("[luai] generating new function:", opts.function_name)

  local new_prompt = require "luai.prompt"(opts)
  local response_text, stream = dispatch_to_provider(new_prompt.prompt, opts.options)
  local implementation = normalize_generated_code(response_text)

  stream.replace(vim.split(implementation, "\n"))

  return {
    implementation = implementation,
    description = new_prompt.description,
    option_list = new_prompt.option_list,
    option_example = new_prompt.option_example,
  }, stream
end
```

- [ ] **Step 2: Update `update_existing_generation` to consume and close the stream**

Find `update_existing_generation` in `lua/luai.lua`. Locate the call:

```lua
local updated = generate_new_function {
  function_name = function_name,
  options = options,
}
```

Replace with:

```lua
local updated, stream = generate_new_function {
  function_name = function_name,
  options = options,
}
```

And at the very bottom of the function (after the final `write_generate_file(towrite)` call), add:

```lua
stream.close()
```

So the function ends with:
```lua
  ...
  write_generate_file(towrite)
  stream.close()
end
```

- [ ] **Step 3: Update `Generated:__newindex` (near-duplicate of `update_existing_generation`)**

Find `Generated:__newindex` in `lua/luai.lua`. Apply the same change as Step 2: capture `stream` as a second return from `generate_new_function`, and call `stream.close()` after the final `write_generate_file(towrite)` line.

- [ ] **Step 4: Update the `_require_init` closure**

Find `M._require_init` in `lua/luai.lua`. The inner generation closure currently looks like:

```lua
return function(options)
  local filepath = find_module(module, key)

  local new_function = generate_new_function {
    function_name = key,
    options = options,
  }
  store_new_function(filepath, key, new_function)

  return require(path_fn)(options)
end
```

Replace with:

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

- [ ] **Step 5: Run both spec suites — they should still pass**

```bash
nvim --headless --noplugin -u NONE -l test/providers_spec.lua
nvim --headless --noplugin -u NONE -l test/dispatch_spec.lua
```

Expected: 17 PASS lines from providers, 6 PASS lines from dispatch. No regressions.

- [ ] **Step 6: Commit**

```bash
git add lua/luai.lua
git commit -m "feat(luai): generate_new_function returns stream alongside impl"
```

---

## Task 8: `Generated:__index` review-popup reuses the stream window

**Files:**
- Modify: `lua/luai.lua`

- [ ] **Step 1: Update the review-popup branch**

Find `Generated:__index` in `lua/luai.lua`. The generation closure currently looks like:

```lua
return function(opts)
  local prompt = opts.__prompt

  local new_function = generate_new_function {
    function_name = key,
    options = opts,
  }

  if prompt then
    local win = require("luai.win").popup {
      name = "luai-implementation.lua",
      filetype = "lua",
    }

    vim.api.nvim_buf_set_lines(0, 0, -1, false, vim.split(new_function.implementation, "\n"))
    vim.cmd.redraw()

    local accept = vim.fn.input { prompt = "Accept (y/n)? ", default = "y", cancelreturn = "n" }
    pcall(vim.api.nvim_buf_delete, vim.api.nvim_win_get_buf(win), { force = true })
    pcall(vim.api.nvim_win_close, win, true)

    if accept ~= "y" then
      -- TODO: Re-request it
      return
    end
  end

  store_new_function(filepath, key, new_function)

  -- Load via cache mechanisms
  return M.generate[key](opts)
end
```

Replace it with:

```lua
return function(opts)
  local prompt = opts.__prompt

  local new_function, stream = generate_new_function {
    function_name = key,
    options = opts,
  }

  if prompt then
    local accept = vim.fn.input { prompt = "Accept (y/n)? ", default = "y", cancelreturn = "n" }
    stream.close()

    if accept ~= "y" then
      -- TODO: Re-request it
      return
    end
  else
    stream.close()
  end

  store_new_function(filepath, key, new_function)

  -- Load via cache mechanisms
  return M.generate[key](opts)
end
```

Note: the old code opened a *second* window (`luai.win.popup`) just for the review, then deleted it. Now the stream window (already showing the normalised code thanks to `stream.replace` in `generate_new_function`) IS the review window. The accept prompt fires while the stream window is visible, then we close it.

- [ ] **Step 2: Run both spec suites — they should still pass**

```bash
nvim --headless --noplugin -u NONE -l test/providers_spec.lua
nvim --headless --noplugin -u NONE -l test/dispatch_spec.lua
```

Expected: 17 PASS lines from providers, 6 PASS lines from dispatch. No regressions.

- [ ] **Step 3: Confirm `lua/luai.lua` no longer references `luai.win` from the generation flow**

```bash
grep -n 'require *"luai.win"' lua/luai.lua
```

Expected: no matches (the only previous use was inside `Generated:__index`'s review popup, now replaced).

If `lua/luai/win.lua` is no longer used anywhere on rtp, leaving it in place is fine — it remains a useful helper that future code might pick up, and removing it is out of scope for this plan.

- [ ] **Step 4: Commit**

```bash
git add lua/luai.lua
git commit -m "feat(luai): review popup reuses the stream window"
```

---

## Task 9: Final verification

**Files:** none

- [ ] **Step 1: Run all three spec suites**

```bash
nvim --headless --noplugin -u NONE -l test/stream_win_spec.lua && \
nvim --headless --noplugin -u NONE -l test/providers_spec.lua && \
nvim --headless --noplugin -u NONE -l test/dispatch_spec.lua
```

Expected:
- stream_win: 7 PASS lines, exit 0
- providers: 17 PASS lines, exit 0
- dispatch: 6 PASS lines, exit 0

- [ ] **Step 2: Parse-check `test/manual.lua`**

```bash
nvim --headless --noplugin -u NONE \
  -c 'lua local f, err = loadfile("test/manual.lua"); print(err and ("ERROR: " .. err) or "OK")' \
  -c 'qa'
```

Expected: `OK`.

- [ ] **Step 3: Verify the branch history**

```bash
git log --oneline master..HEAD
git diff master --stat
```

Expected: 8 commits on the branch with task-aligned subjects; touched files are `lua/luai.lua`, `lua/luai/providers.lua`, `lua/luai/stream_win.lua` (new), `test/providers_spec.lua`, `test/dispatch_spec.lua`, `test/stream_win_spec.lua` (new).
