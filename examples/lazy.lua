return {
  "ddtkey/cargo-features.nvim",
  version = "*",
  ft = "rust",
  cmd = {
    "CargoFeatures",
    "CargoFeaturesApplyProfile",
    "CargoFeaturesReset",
    "CargoFeaturesDebug",
  },
  keys = {
    {
      "<leader>rf",
      function()
        require("cargo-features").open()
      end,
      desc = "Cargo Features",
    },
  },
  opts = {},
}
