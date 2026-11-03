if vim.g.loaded_petal then return end
vim.g.loaded_petal = true

-- :Petal opens the status, :Petal <args> runs one git command (output in a notification or a buffer)
vim.api.nvim_create_user_command("Petal", function(o)
  if o.args == "" then require("petal").open() else require("petal").command(o.args) end
end, { nargs = "*", desc = "Petal git status / run git" })
