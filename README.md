# `luai.nvim`

Generate, Demand, and Improve Lua Functions on the fly.

## Installation

### lazy.nvim

```lua
{
  "gvanbeck/luai.nvim",
  cmd = { "LuaiGenerate", "LuaiImprove", "LuaiRun" },
  dependencies = {
    -- Optional, only required for `:Telescope luai`.
    "nvim-telescope/telescope.nvim",
    "nvim-lua/plenary.nvim",
  },
  config = function()
    local providers = require "luai.providers"
    require("luai").setup {
      providers = {
        default = providers.claude_code { model = "sonnet" },
      },
      default_provider = "default",
    }
    -- Optional: register the Telescope picker.
    pcall(function() require("telescope").load_extension "luai" end)
  end,
}
```

### Requirements

- **Neovim 0.10+** — uses `vim.system` (async + sync), `vim.uv`, `vim.fs.dir`, `vim.api.nvim_get_runtime_file`.
- **At least one CLI agent on `$PATH`**: `claude` (Claude Code) for `providers.claude_code`, `agent` (Cursor Agent) for `providers.cursor_agent`, or any other CLI you wrap via `providers.cli`.
- **Optional CLIs**: `stylua` for auto-formatting generated files (luai skips formatting silently when absent); `jq` for pretty-printed `history` JSON inside generated files (compact JSON otherwise).
- **Optional plugins**: `telescope.nvim` + `plenary.nvim` for `:Telescope luai`. luai works without them; only the picker requires Telescope.

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

### Where generated functions live

All generated functions are stored under a user-owned path you control. The default is:

```
~/.config/nvim/lua/luai_user/<module>/<function>.lua
```

Files there are part of your nvim config tree, so they're git-trackable in your dotfiles. The require namespace is derived from the path's last segment (`luai_user` by default), and functions resolve as `require("luai_user.<module>.<fn>")`.

Override the location via `setup{}`:

```lua
require("luai").setup {
  user_storage = vim.fn.stdpath("config") .. "/lua/luai_user",  -- default
  providers = { ... },
  default_provider = "default",
}
```

The path must end in `/lua/<namespace>` so the standard Lua module path resolves it (your nvim config dir is already on the runtimepath). Whatever you choose for `<namespace>` becomes the prefix users will type with `demand("<sub>")` (auto-prefixed to `<namespace>.<sub>`).

Module names you pass to `demand(...)` are auto-prefixed with the namespace if absent:
- `demand("demo")` → `~/.config/nvim/lua/luai_user/demo/`
- `demand("luai_user.demo")` → same path (no double-prefix)
- `demand("foo.bar")` → `~/.config/nvim/lua/luai_user/foo/bar/`

The `M.generate.fn(...)` API has no module, so its files land under `<namespace>.default` at `~/.config/nvim/lua/luai_user/default/<fn>.lua`.

#### Migrating from earlier luai releases

Earlier luai releases either shipped demos under the plugin's own `lua/luai/{demo,omarchy,default}/` or wrote `M.generate` files to `~/.local/share/nvim/luai/generated/`. To bring any of those into the new user-owned location:

```bash
mkdir -p ~/.config/nvim/lua/luai_user

# If you have shipped demos in the plugin install (older versions only):
cp -r ~/.local/share/nvim/lazy/luai.nvim/lua/luai/demo \
      ~/.local/share/nvim/lazy/luai.nvim/lua/luai/omarchy \
      ~/.config/nvim/lua/luai_user/ 2>/dev/null

# If you have functions under the older stdpath('data') location:
cp ~/.local/share/nvim/luai/generated/*.lua \
   ~/.config/nvim/lua/luai_user/default/ 2>/dev/null

# Rewrite each init.lua so it registers the luai_user.* namespace:
for d in ~/.config/nvim/lua/luai_user/*/; do
  module=$(basename "$d")
  printf 'return require("luai")._require_init("luai_user.%s")\n' "$module" > "$d/init.lua"
done
```

After migration the picker and `M.generate.<name>` resolve normally and your functions live in your own dotfiles tree.

## Usage

### `demand`

`demand` is `require` for functions that may not exist yet — give it a module name, access any function on it, and luai generates it on the fly if the file isn't on disk. Subsequent calls `require` the stored file like normal Lua.

```lua
local demand = require("luai").demand

local win = demand("utils").create_floating_window {
  title = "Hello, World!",
  filetype = "lua",
}
```

The module name auto-prefixes with your namespace (default `luai_user`). After the first call, the files land under your user storage:

```
~/.config/nvim/lua/luai_user/utils/init.lua                  (stub registering "luai_user.utils")
~/.config/nvim/lua/luai_user/utils/create_floating_window.lua
```

After generation you can also call `require("luai_user.utils").create_floating_window` directly. Delete the function file to regenerate fresh on the next `demand`.

**Note**: `demand` automatically EXECUTES the generated code. If you want to review before running, use `:LuaiGenerate` or `M.generate` with `__prompt = "Accept (y/n)?"`.

### `generate` / `:LuaiGenerate`

`:LuaiGenerate` prompts you for a function name + description, streams the LLM's output into a floating window, normalises the result, and asks `Accept (y/n)?` before persisting.

```vim
:LuaiGenerate
```

Programmatic equivalent (also accepts `__provider` / `__model` per-call overrides):

```lua
require("luai").generate.my_fn {
  __description = "Print Hello World",
  __prompt = "Accept (y/n)? ",  -- omit for silent generation
}
```

Files land under your storage's default module:

```
~/.config/nvim/lua/luai_user/default/<name>.lua
```

Run the new function with `:LuaiRun <name>` (see below).

### `improve` / `:LuaiImprove`

`:LuaiImprove` opens a `vim.ui.select` picker over all generated modules and functions under your user storage. Pick a module, then a function, then describe what should change. luai regenerates with the previous implementation as context and appends a new history entry — the old versions stay visible inside the file.

```vim
:LuaiImprove
```

Programmatic equivalent:

```lua
require("luai").improve("utils").create_floating_window = "use rounded borders"
```

The Telescope picker's preview pane (`:Telescope luai`) shows the full file including history, so you can browse the evolution of any function.

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

### Telescope picker

`luai.nvim` ships a Telescope extension at `lua/telescope/_extensions/luai.lua` that lists every previously-generated function on your runtimepath and runs the one you pick.

Load it once in your Neovim config:

```lua
require("telescope").load_extension("luai")
```

Then:

```vim
:Telescope luai
```

The picker shows `module.function — first line of description` and a preview pane with the function's source file. Pressing `<CR>` invokes the selected function with the most recent `option_example` from its history (`{}` if there's no example yet). The selection happens before the picker closes, so any popup the function opens stays on top.

Telescope is a soft dependency — luai works fine without it; only this picker requires it.

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
