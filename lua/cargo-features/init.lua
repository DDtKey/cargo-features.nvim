local config = require("cargo-features.config")

local M = {}

---@param opts? CargoFeaturesConfig
function M.setup(opts)
  config.setup(opts)
  require("cargo-features.highlights").setup(true)
  require("cargo-features.highlights").create_autocmd()
  require("cargo-features.lsp").create_autocmd()
  require("cargo-features.commands").create()
end

function M.open()
  require("cargo-features.highlights").setup()
  require("cargo-features.ui").open()
end

---@param features string[]
---@param opts? CargoFeaturesApplyOptions
function M.apply(features, opts)
  local selected = type(features) == "table" and features or {}
  return require("cargo-features.lsp").apply(selected, opts or {})
end

---@param name? string
---@param opts CargoFeaturesProfile
function M.save_profile(name, opts)
  return require("cargo-features.profile_store").save_profile(name, opts)
end

---@param name? string
---@param opts table
---@return CargoFeaturesProfile?
function M.load_profile(name, opts)
  return require("cargo-features.profile_store").load_profile(name, opts)
end

---@param name? string
---@param opts table
function M.delete_profile(name, opts)
  return require("cargo-features.profile_store").delete_profile(name, opts)
end

---@param opts table
---@return string[]
function M.list_profiles(opts)
  return require("cargo-features.profile_store").list_profiles(opts)
end

return M
