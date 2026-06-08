return {
  "ddtkey/cargo-features.nvim",
  ft = "rust",
  cmd = "CargoFeatures",
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
