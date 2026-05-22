if vim.g.loaded_luai then
  return
end
vim.g.loaded_luai = 1

vim.api.nvim_create_user_command("LuaiGenerate", function()
  vim.ui.input({ prompt = "Function name: " }, function(name)
    if name == nil or vim.trim(name) == "" then
      return
    end
    vim.ui.input({ prompt = "Description: " }, function(description)
      if description == nil then
        return
      end
      -- Run generation outside the vim.ui.input callback chain so the
      -- accept-prompt's vim.fn.input blocks correctly. Inside scheduled
      -- callbacks (which dressing/snacks/noice route vim.ui.input through)
      -- nested cmdline input can return immediately instead of waiting.
      vim.schedule(function()
        require("luai").generate[name] {
          __description = description,
          __prompt = "Accept (y/n)? ",
        }
      end)
    end)
  end)
end, { desc = "Generate a new luai function via interactive prompts" })

vim.api.nvim_create_user_command("LuaiImprove", function()
  require("luai").improve_select()
end, { desc = "Pick a generated luai module/function and improve it" })

vim.api.nvim_create_user_command("LuaiRun", function(c)
  local ctx = {
    range_start = c.line1,
    range_end = c.line2,
    range_present = c.range > 0,
  }
  if c.args == "" then
    local candidates = require("luai").complete_function_names ""
    if #candidates == 0 then
      vim.notify("[luai] no generated functions found", vim.log.levels.WARN)
      return
    end
    vim.ui.select(candidates, { prompt = "Run luai function:" }, function(choice)
      if choice then require("luai").run(choice, ctx) end
    end)
    return
  end
  require("luai").run(c.args, ctx)
end, {
  nargs = "?",
  range = true,
  complete = function(arglead)
    return require("luai").complete_function_names(arglead)
  end,
  desc = "Run a generated luai function (no arg = pick interactively)",
})
