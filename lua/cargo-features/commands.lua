local M = {}

function M.create()
  vim.api.nvim_create_user_command("CargoFeatures", function()
    require("cargo-features").open()
  end, {
    desc = "Open Cargo feature manager for rust-analyzer",
  })

  vim.api.nvim_create_user_command("CargoFeaturesDebug", function()
    require("cargo-features.lsp").debug_clients()
  end, {
    desc = "Show rust-analyzer client matching details",
  })
end

return M
