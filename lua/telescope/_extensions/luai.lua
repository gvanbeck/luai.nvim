local function build_items()
  local luai = require "luai"
  local items = {}
  for _, module_item in ipairs(luai._get_generated_modules()) do
    for _, fn_item in ipairs(luai._get_generated_functions_for_module(module_item)) do
      local ok, generated = pcall(luai._read_generated_file, fn_item.path)
      if ok then
        -- Spec: a corrupt file silently skips just that function.
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
  end
  return items
end

local function pick(opts)
  opts = opts or {}
  local pickers = require "telescope.pickers"
  local finders = require "telescope.finders"
  local conf = require("telescope.config").values
  local previewers = require "telescope.previewers"
  local actions = require "telescope.actions"
  local action_state = require "telescope.actions.state"

  local items = build_items()

  pickers.new(opts, {
    prompt_title = "luai functions",
    finder = finders.new_table {
      results = items,
      entry_maker = function(item)
        local desc_summary = (item.description:gsub("\n", " ")):sub(1, 60)
        local display = string.format("%s.%s", item.module, item.fn)
        if desc_summary ~= "" then
          display = display .. " — " .. desc_summary
        end
        return {
          value = item,
          display = display,
          ordinal = item.module .. "." .. item.fn,
          path = item.path,
        }
      end,
    },
    sorter = conf.generic_sorter(opts),
    previewer = previewers.new_buffer_previewer {
      title = "function source",
      define_preview = function(self, entry)
        local lines = vim.fn.readfile(entry.path)
        vim.api.nvim_buf_set_lines(self.state.bufnr, 0, -1, false, lines)
        vim.bo[self.state.bufnr].filetype = "lua"
      end,
    },
    attach_mappings = function(prompt_bufnr, _map)
      actions.select_default:replace(function()
        local entry = action_state.get_selected_entry()
        actions.close(prompt_bufnr)
        if not entry then return end
        local item = entry.value
        local mod = require(item.module)
        mod[item.fn](item.option_example or {})
      end)
      return true
    end,
  }):find()
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
