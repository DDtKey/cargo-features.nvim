return {
  "ddtkey/cargo-features.nvim",
  version = "*",
  ft = "rust",
  cmd = { "CargoFeatures", "CargoFeaturesReset", "CargoFeaturesDebug" },
  keys = {
    {
      "<leader>rf",
      function()
        require("cargo-features").open()
      end,
      desc = "Cargo Features",
    },
  },
  opts = {
    lsp = {
      sync_check_features = "if_set",
    },
  },
}
