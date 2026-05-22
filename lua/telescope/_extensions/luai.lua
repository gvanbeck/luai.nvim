local function build_items()
  local luai = require "luai"
  local items = {}
  for _, module_item in ipairs(luai._get_generated_modules()) do
    for _, fn_item in ipairs(luai._get_generated_functions_for_module(module_item)) do
      local generated = luai._read_generated_file(fn_item.path)
      local latest = generated and generated.history and generated.history[#generated.history] or {}
      table.insert(items, {
        module = fn_item.module,
        fn = fn_item.fn,
        path = fn_item.path,
        option_example = latest.option_example,
        description = latest.description or "",
      })
    end
  end
  return items
end

local function pick(_opts)
  error "luai telescope extension: pick not implemented yet"
end

local ext = require("telescope").register_extension {
  exports = {
    run = pick,
    luai = pick,
  },
}

-- Internal hook for tests; not part of the user-facing API.
ext._build_items = build_items

return ext
