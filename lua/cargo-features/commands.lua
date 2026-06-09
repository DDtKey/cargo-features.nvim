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

  vim.api.nvim_create_user_command("CargoFeaturesReset", function(opts)
    local ok, err = require("cargo-features").reset({ force = opts.bang })
    if ok then
      require("cargo-features.util").notify("Reset Cargo feature overrides for rust-analyzer")
    else
      require("cargo-features.util").notify(err or "Unable to reset Cargo feature overrides", vim.log.levels.ERROR)
    end
  end, {
    bang = true,
    desc = "Reset plugin-applied Cargo feature overrides for rust-analyzer",
  })
end

return M
