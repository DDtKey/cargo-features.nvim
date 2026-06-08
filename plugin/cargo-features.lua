if vim.g.loaded_cargo_features_nvim == 1 then
  return
end
vim.g.loaded_cargo_features_nvim = 1

require("cargo-features.highlights").setup()
require("cargo-features.highlights").create_autocmd()
require("cargo-features.lsp").create_autocmd()
require("cargo-features.commands").create()
