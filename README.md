# `luai.nvim`

Generate, Demand, and Improve Lua Functions on the fly.

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

## Usage

### `demand`

```lua
-- Load demand into the scope.
local demand = require("luai").demand

-- Demand is like `require` - just give it a module name
-- (must have a base module somewhere with a shared name)
--
-- If you have already demanded this function before, it will
-- re-use the generated function. Otherwise, it will generate
-- a function definition for you on the fly, and then save it.
--
-- NOTE: `demand` automatically executes the code. So if you
-- care about that, you should probably use `generate` first ;)
local win = demand("custom.utils").create_floating_window {
    title = "Hello, World!",
    filetype = "lua"
}
```

This will create a new file wherever you have a `lua/custom` folder somewhere in your runtime path.

The folder structure will look like:

```
lua/custom/utils/init.lua
lua/custom/utils/create_floating_window.lua
```

Going forward, you can just `require("custom.utils").create_floating_window` if you want! I made it so that
afterwards, loading it just works as normal with Lua. Or you can delete the file and it will generate something
fresh next time you `demand` it.

### `generate`

You can generate functions with a command:

```vim
:LuaiGenerate
```

This will lead you through several prompts and then generate the code, where you can review it afterwards.

### `improve`

```vim
" The coolest way to use the command:
:LuaiImprove
```

This will open up a selection window for you to select from
the generated modules on your runtimepath, then a second selection
for the generated functions inside that module, and finally it will
prompt you for what you want improved.

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

`agent.call` opens a small 70×12 floating window in the bottom-right corner showing the LLM's live stream. It does not steal focus and closes itself when the call completes. The returned string is the model's raw response (no Lua normalisation — use `require("luai").generate` if you want code generated and stored on disk).

`agent.ask_user(question)` returns the user's free-text answer. Pass a second argument with a list of strings to get a selection prompt instead. Returns `nil` on cancel or after 60 seconds without a response.
