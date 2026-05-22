--[[
TODO:
- Make async version of generation, where it's not required, just generate one
- Make async version when `callback` is specified, since you can just execute the callback later

```lua
-- This would happen asynchronously, we don't have to wait for the generation
demand("my.plugin").do_something_cool {
  callback = function(err, result)
    print(err, result)
  end
}
```

--]]

local path = require "luai.path"

local M = {}
local config = {
  ---@type table<string, luai.Provider>
  providers = {},
  ---@type string
  default_provider = "default",
  ---@type string: path ending in `/lua/<namespace>` where generated functions live
  user_storage = vim.fn.stdpath "config" .. "/lua/luai_user",
  ---@type string: derived from the basename of user_storage by setup()
  _namespace = "luai_user",
}

local function namespace()
  return config._namespace
end

local function storage_root()
  return config.user_storage
end

local function default_module()
  return namespace() .. ".default"
end

local function normalize_module(module)
  local ns = namespace()
  if module == nil or module == "" then
    return ns .. ".default"
  end
  if module == ns or vim.startswith(module, ns .. ".") then
    return module
  end
  return ns .. "." .. module
end

local function module_to_path(module, file)
  local ns = namespace()
  local sub = module == ns and "" or module:sub(#ns + 2) -- strip "<ns>." prefix
  local parts = sub == "" and {} or vim.split(sub, ".", { plain = true })
  table.insert(parts, file .. ".lua")
  return vim.fs.joinpath(storage_root(), unpack(parts))
end

local function ensure_default_module()
  local init_file = module_to_path(default_module(), "init")
  if not vim.uv.fs_stat(init_file) then
    vim.fn.mkdir(vim.fn.fnamemodify(init_file, ":h"), "p")
    local stub = string.format([[return require("luai")._require_init(%q)]], default_module())
    vim.fn.writefile({ stub }, init_file)
  end
end

---@class luai.Settings
---@field providers? table<string, luai.Provider>: Named provider registry. Required for generation.
---@field default_provider? string: Key into `providers` used when `opts.__provider` is not set. Defaults to `"default"`.

---@class luai.GeneratedFunction
---@field function_name string
---@field filepath string
---@field history luai.RawGeneratedFunctionResult[]
---@field implementation function

---@class luai.WriteFileOptions
---@field function_name string
---@field filepath string
---@field history luai.RawGeneratedFunctionResult[]
---@field implementation string

---@class luai.RawGeneratedFunctionResult
---@field option_list string
---@field option_example table
---@field description string
---@field implementation string

---@class luai.GenerateFunctionOpts
---@field function_name string
---@field options table

--- Setup the luai module. This is currently optional and kept for API compatibility.
---@param opts? luai.Settings
M.setup = function(opts)
  opts = opts or {}
  config = vim.tbl_extend("force", config, opts)
  config.user_storage = vim.fn.expand(config.user_storage)
  local ns = config.user_storage:match "/lua/([^/]+)/?$"
  assert(ns,
    "[luai] user_storage must end in /lua/<namespace>, got: " .. config.user_storage)
  config._namespace = ns
  vim.fn.mkdir(config.user_storage, "p")
end

---@param implementation string
---@return boolean
---@return string?
local validate_generated_code = function(implementation)
  local loader = loadstring or load
  local _, err = loader(implementation)
  if err then
    return false, err
  end

  return true
end

---@param response_text string
---@return string
local normalize_generated_code = function(response_text)
  local normalized = vim.trim(response_text)
  if normalized == "" then
    error "[luai] provider returned an empty response."
  end

  local candidates = { normalized }

  local fenced = normalized:match("```lua%s*(.-)%s*```") or normalized:match("```%s*(.-)%s*```")
  if fenced then
    table.insert(candidates, vim.trim(fenced))
  end

  local tagged = normalized:match "<lua_function>%s*(.-)%s*</lua_function>"
  if tagged then
    table.insert(candidates, vim.trim(tagged))
  end

  local start = normalized:find("return%s+function%s*%(")
  if start then
    local lines = vim.split(normalized:sub(start), "\n")
    for last = #lines, 1, -1 do
      local candidate_lines = {}
      for i = 1, last do
        table.insert(candidate_lines, lines[i])
      end

      table.insert(candidates, vim.trim(table.concat(candidate_lines, "\n")))
    end
  end

  for _, candidate in ipairs(candidates) do
    if candidate ~= "" and candidate:match "^return%s+function%s*%(" then
      local ok = validate_generated_code(candidate)
      if ok then
        return candidate
      end
    end
  end

  error(string.format(
    "[luai] provider response did not contain valid Lua starting with `return function(opts)`:\n%s",
    response_text
  ))
end

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

  local window_opts = opts.__window or {}
  local stream = require("luai.stream_win").open {
    title = "luai: generating",
    geometry = { size = window_opts.size or "fullsize" },
    focus = window_opts.focus,
    winblend = window_opts.winblend,
  }
  opts.__on_chunk = function(chunk) stream.append(chunk) end

  local ok, result = pcall(provider, prompt, opts)
  if not ok then
    stream.close()
    error(result)
  end

  return result, stream
end

M._dispatch_to_provider = dispatch_to_provider

--- Read the generated file from disk
---@param filepath string: The path to the existing generated file
---@return luai.GeneratedFunction?
local read_generated_file = function(filepath)
  if vim.fn.filereadable(filepath) == 1 then
    local generated = loadfile(filepath)()
    generated.history = vim.json.decode(generated.history)
    for _, v in ipairs(generated.history) do
      if type(v.option_example) == "string" then
        v.option_example = vim.json.decode(v.option_example)
      end
    end

    return generated
  end

  return nil
end

---@param value any
---@return string
local format_json_for_history = function(value)
  local encoded = vim.json.encode(value)
  if vim.fn.executable "jq" ~= 1 then
    return encoded
  end

  local result = vim.system({ "jq", "--sort-keys", "." }, {
    stdin = encoded,
    text = true,
  }):wait()

  if result.code ~= 0 then
    return encoded
  end

  return vim.trim(result.stdout or "")
end

--- Write the generated file to disk
---@param options luai.WriteFileOptions
local write_generate_file = function(options)
  assert(options.implementation, "must have implementation to write")

  local file_contents = string.format(
    [[
return setmetatable({
  history = [==[ %s ]==],
  implementation = function()
%s
  end,
}, { __call = function(self, ...) return self.implementation()(...) end })
]],
    format_json_for_history(options.history),
    options.implementation
  )

  vim.fn.writefile(vim.split(file_contents, "\n"), options.filepath)
  if vim.fn.executable "stylua" == 1 then
    vim.system({ "stylua", options.filepath }):wait()
  end

  print(string.format("[luai] wrote new updated file: %s", options.filepath))
end

--- Generate a new function
---@param opts luai.GenerateFunctionOpts
---@return luai.RawGeneratedFunctionResult
local generate_new_function = function(opts)
  print("[luai] generating new function:", opts.function_name)

  local new_prompt = require "luai.prompt"(opts)
  local response_text, stream = dispatch_to_provider(new_prompt.prompt, opts.options)

  local ok, implementation = pcall(normalize_generated_code, response_text)
  if not ok then
    stream.close()
    error(implementation)
  end

  stream.replace(vim.split(implementation, "\n"))

  return {
    implementation = implementation,
    description = new_prompt.description,
    option_list = new_prompt.option_list,
    option_example = new_prompt.option_example,
  }, stream
end

---@param options table
---@param latest_history luai.RawGeneratedFunctionResult
local add_previous_implementation_context = function(options, latest_history)
  ---@diagnostic disable-next-line: inject-field
  options.__history = string.format(
    [[
Here is the previous implementation. Keep the parts that are still correct and update it to satisfy the new request.

Previous implementation:
%s
]],
    latest_history.implementation
  )
end

local store_new_function = function(filepath, key, new_function)
  ---@type luai.WriteFileOptions
  local generated = {
    function_name = key,
    filepath = filepath,
    history = {
      {
        option_list = new_function.option_list,
        option_example = new_function.option_example,
        description = new_function.description,
        implementation = new_function.implementation,
      },
    },
    implementation = new_function.implementation,
  }

  write_generate_file(generated)
end

local update_existing_generation = function(filepath, function_name, value)
  local generated = assert(read_generated_file(filepath), "existing func")
  local latest_history = generated.history[#generated.history]

  local options
  if type(value) == "table" then
    options = vim.deepcopy(value)
  elseif type(value) == "string" then
    options = vim.deepcopy(latest_history.option_example)
    options.__description = value
  else
    error "Unsupported type"
  end

  add_previous_implementation_context(options, latest_history)

  local updated, stream = generate_new_function {
    function_name = function_name,
    options = options,
  }

  local history = vim.deepcopy(generated.history)
  table.insert(history, {
    option_list = updated.option_list,
    option_example = vim.json.encode(updated.option_example),
    description = updated.description,
    implementation = updated.implementation,
  })

  ---@type luai.WriteFileOptions
  local towrite = {
    function_name = function_name,
    filepath = filepath,
    history = history,
    implementation = updated.implementation,
  }
  write_generate_file(towrite)
  stream.close()
end

---@class luai.CachedGeneration
---@field stat uv.aliases.fs_stat_table
---@field fn function
local cached = {}

local Generated = {}
Generated.__index = Generated

M.generate = setmetatable({}, Generated)

--- Get the generated function from the cache, or generate a new one if it doesn't exist
---@param key string
---@return function
function Generated:__index(key)
  ensure_default_module()
  local filepath = module_to_path(default_module(), key)

  -- Save things into memory, so we don't read from disk all the time
  if cached[key] and not path.is_file_newer(filepath, cached[key].stat) then
    return cached[key].fn
  end

  -- Read things from disk, so we don't ask AI to generate every time
  local result = read_generated_file(filepath)
  if result then
    local fn = result.implementation()
    cached[key] = {
      fn = fn,
      stat = vim.uv.fs_stat(filepath),
    }

    return fn
  end

  -- Generate new function from AI.
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
end

function Generated:__newindex(key, value)
  ensure_default_module()
  local generated_filepath = module_to_path(default_module(), key)
  local generated = assert(read_generated_file(generated_filepath), "existing func")
  local latest_history = generated.history[#generated.history]

  local options
  if type(value) == "table" then
    options = vim.deepcopy(value)
  elseif type(value) == "string" then
    options = vim.deepcopy(latest_history.option_example)
    options.__description = value
  else
    error "Unsupported type"
  end

  add_previous_implementation_context(options, latest_history)

  local updated, stream = generate_new_function {
    function_name = key,
    options = options,
  }

  local history = vim.deepcopy(generated.history)
  table.insert(history, {
    option_list = updated.option_list,
    option_example = vim.json.encode(updated.option_example),
    description = updated.description,
    implementation = updated.implementation,
  })

  ---@type luai.WriteFileOptions
  local towrite = {
    function_name = key,
    filepath = module_to_path(default_module(), key),
    history = history,
    implementation = updated.implementation,
  }
  write_generate_file(towrite)
  stream.close()
end

-- after you use demand, if you like it...
-- you just replace it with require
M.demand = function(module)
  local norm = normalize_module(module)
  local init_file = module_to_path(norm, "init")

  -- Generate the init stub on first use.
  if not vim.uv.fs_stat(init_file) then
    vim.fn.mkdir(vim.fn.fnamemodify(init_file, ":h"), "p")
    local contents = string.format([[return require("luai")._require_init(%q)]], norm)
    vim.fn.writefile({ contents }, init_file)
  end

  return require(norm)
end

--- Improve a function that already exists. This must have been generated already.
---@param module string
---@return table
M.improve = function(module)
  local norm = normalize_module(module)
  return setmetatable({}, {
    __newindex = function(_, function_name, value)
      local generated_filepath = module_to_path(norm, function_name)
      assert(vim.uv.fs_stat(generated_filepath), "generated function file must exist already")

      update_existing_generation(generated_filepath, function_name, value)
    end,
  })
end

--- Used by modules created from `demand`. This is not meant to be used by the user.
---@param module string
---@return table
M._require_init = function(module)
  return setmetatable({}, {
    __index = function(_, key)
      local path_fn = string.format("%s.%s", module, key)
      local ok, fn = pcall(require, path_fn)
      if not ok then
        return function(options)
          local filepath = module_to_path(module, key)

          local new_function, stream = generate_new_function {
            function_name = key,
            options = options,
          }
          store_new_function(filepath, key, new_function)
          stream.close()

          return require(path_fn)(options)
        end
      end

      return fn
    end,
  })
end

local generated_module_pattern = '^return require%("luai"%)%._require_init%("([^"]+)"%)'

---@return table[]
local get_generated_modules = function()
  local root = storage_root()
  local items = {}
  for name, type_ in vim.fs.dir(root) do
    if type_ == "directory" then
      local init_path = vim.fs.joinpath(root, name, "init.lua")
      if vim.uv.fs_stat(init_path) then
        local lines = vim.fn.readfile(init_path)
        local module = lines[1] and lines[1]:match(generated_module_pattern)
        if module then
          table.insert(items, {
            module = module,
            dir = vim.fs.joinpath(root, name),
            init = init_path,
          })
        end
      end
    end
  end

  table.sort(items, function(left, right)
    return left.module < right.module
  end)

  return items
end

---@param module_item table
---@return table[]
local get_generated_functions_for_module = function(module_item)
  local items = {}
  for file, filetype in vim.fs.dir(module_item.dir) do
    if filetype == "file" and file ~= "init.lua" and vim.endswith(file, ".lua") then
      table.insert(items, {
        module = module_item.module,
        fn = vim.fn.fnamemodify(file, ":r"),
        path = vim.fs.joinpath(module_item.dir, file),
      })
    end
  end

  table.sort(items, function(left, right)
    return left.fn < right.fn
  end)

  return items
end

---@param module string|table
---@return table?
local resolve_generated_module = function(module)
  if type(module) == "table" then
    return module
  end

  for _, item in ipairs(get_generated_modules()) do
    if item.module == module then
      return item
    end
  end
end

---@param choice table
local prompt_for_improvement = function(choice)
  vim.schedule(function()
    local improvement = vim.fn.input(string.format('Improve `require("%s").%s`: ', choice.module, choice.fn))
    if improvement == nil or vim.trim(improvement) == "" then
      return
    end

    M.improve(choice.module)[choice.fn] = improvement
  end)
end

---@param module string|table
M.improve_module_select = function(module)
  local module_item = resolve_generated_module(module)
  assert(module_item, string.format("[luai] Could not find generated module: %s", module))

  local items = get_generated_functions_for_module(module_item)
  if vim.tbl_isempty(items) then
    vim.notify(string.format("[luai] No generated functions found for %s", module_item.module))
    return
  end

  vim.ui.select(items, {
    prompt = string.format("Which function in %s should be improved?", module_item.module),
    format_item = function(choice)
      return string.format('require("%s").%s', choice.module, choice.fn)
    end,
  }, function(choice)
    if choice then
      prompt_for_improvement(choice)
    end
  end)
end

M.improve_select = function()
  local items = get_generated_modules()
  if vim.tbl_isempty(items) then
    vim.notify "[luai] No generated modules found under user storage."
    return
  end

  vim.ui.select(items, {
    prompt = "Which module should be improved?",
    format_item = function(choice)
      return choice.module
    end,
  }, function(choice)
    if choice then
      vim.schedule(function()
        M.improve_module_select(choice)
      end)
    end
  end)
end

-- Expose discovery helpers for telescope extension
M._get_generated_modules = get_generated_modules
M._get_generated_functions_for_module = get_generated_functions_for_module
M._read_generated_file = read_generated_file

-- Expose storage helpers for testing
M._normalize_module = normalize_module
M._module_to_path = module_to_path
M._namespace = namespace
M._storage_root = storage_root

---Public access to the context helper module.
M.context = require "luai.context"

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

---@param arglead string
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

return M
