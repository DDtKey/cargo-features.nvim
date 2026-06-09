return {
  "ddtkey/cargo-features.nvim",
  version = "*",
  ft = "rust",
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
