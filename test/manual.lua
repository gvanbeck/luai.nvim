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

-- --{{{ Print all odd values
-- demand('luai.demo').print_all_odd_values_in_table { t = { 1, 2, 3, 4, 5 } }
-- --}}}

























-- -- {{{ Remove whitespace
-- print(demand('luai.demo').remove_multiple_whitespace_from_string_anywhere_in_text {
-- 	text = "start     hello  world  "
-- })
--
-- -- }}}

























-- -- {{{ It can even count!
-- print(demand('luai.demo').count_letters_in_word {
--   __description = "Count the letters!",
--   letter = "r",
--   word = "strawberry",
-- })
--
-- -- }}}

























-- --{{{ Of course, it knows neovim!
-- demand('luai.demo').create_floating_window {
--   __description = "Create a floating window, with the provided background color.",
--
--   title = "hello world 2",
--   filetype = "lua",
--   background = "green",
--   contents = {
--     'print("hello world")',
--   },
-- }
-- --}}}

























-- -- {{{ And can do weird things!
-- demand("luai.demo").greet_a_friend_in_a_popup_window {
--   __description = "Create a floating window with a border, include simple keybinds as well.",
--
--   friend_name = "omacon friends",
--   background = "blue",
-- }
-- -- }}}

























-- --{{{ And even knows plugins!
-- demand("luai.demo").telescope_picker_search_neovim_config {}
--
-- --}}}

























--{{{ But not limited to neovim!

-- -- It can even create new modules on the fly!
-- -- PRESENTER NOTE: (show folders before executing)
-- demand("luai.omarchy").change_omarchy_current_theme {
--   theme = "matte-black",
-- }

-- -- And do random stuff!
-- demand("luai.omarchy").next_omarchy_background {
--   __description = "move to the next omarchy background for the current theme",
-- }

--}}}

























-- --{{{ And can be improved
-- require('luai').improve_select()
-- --}}}



















