local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
vim.opt.runtimepath:prepend(root)

local plenary = vim.env.PLENARY_PATH
if plenary and plenary ~= "" then
  vim.opt.runtimepath:prepend(plenary)
else
  vim.opt.runtimepath:prepend(vim.fs.joinpath(root, ".deps", "plenary.nvim"))
end

vim.opt.swapfile = false
vim.opt.shadafile = "NONE"
