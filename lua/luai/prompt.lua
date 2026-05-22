---@param opts table
return function(opts)
  local options = vim.deepcopy(opts.options)
  local function_name = opts.function_name

  local description = options.__description or ""

  local history = options.__history or ""

  -- Double underscore names are reserved.
  for key, _ in pairs(options) do
    if vim.startswith(key, "__") then
      options[key] = nil
    end
  end

  local option_list = table.concat(vim.tbl_keys(options), ",")
  local sections = {
    "You write effective Neovim Lua and know the Neovim codebase well.",
    "Prefer builtins. Prefer `vim.*` over `vim.api.*` or `vim.fn.*` when it fits.",
    "Prefer task-specific Lua helpers on `vim.*` before lower-level APIs. Example: prefer `vim.keymap.set()` over `vim.api.nvim_set_keymap()` when creating keymaps.",
    "",
    require "luai.prompt.vim_module",
    "",
    "Return only Lua code for a Neovim chunk that evaluates to a function. No prose or markdown fences.",
    "- Start with `return function(opts)` and end with `end`.",
    "- Do not include the function name.",
    "- Add one short comment inside the function.",
    "- Validate only when useful.",
    "- Prefer simple direct implementations.",
    "",
    "Request:",
    string.format("Function name: %s", function_name),
    string.format("Available option keys: %s", option_list),
    string.format("Example opts table: %s", vim.inspect(options)),
    "",
  }

  if history ~= "" then
    table.insert(sections, "Context from the previous generation:")
    table.insert(sections, history)
    table.insert(sections, "")
  end

  if description ~= "" then
    table.insert(sections, "Additional requirements:")
    table.insert(sections, description)
    table.insert(sections, "")
  end

  return {
    function_name = function_name,
    option_list = option_list,
    option_example = options,
    description = description,
    prompt = table.concat(sections, "\n"),
  }
end
