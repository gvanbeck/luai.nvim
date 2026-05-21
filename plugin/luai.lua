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
      require("luai").generate[name] {
        __description = description,
        __prompt = "Accept (y/n)? ",
      }
    end)
  end)
end, { desc = "Generate a new luai function via interactive prompts" })

vim.api.nvim_create_user_command("LuaiImprove", function()
  require("luai").improve_select()
end, { desc = "Pick a generated luai module/function and improve it" })
