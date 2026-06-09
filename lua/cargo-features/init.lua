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

---@param opts? CargoFeaturesResetOptions
function M.reset(opts)
  opts = opts or {}
  local cargo = require("cargo-features.cargo")
  local bufnr = opts.bufnr or vim.api.nvim_get_current_buf()
  local manifest_path = opts.manifest_path
  if not manifest_path then
    manifest_path = cargo.find_manifest(bufnr)
  end
  if not manifest_path then
    return false, "No Cargo.toml found above the current buffer"
  end

  local reset_opts = vim.tbl_extend("force", opts, {
    bufnr = bufnr,
    manifest_path = manifest_path,
  })
  if not reset_opts.workspace_root or not reset_opts.scope then
    local manifest = cargo.load_manifest(manifest_path)
    if manifest then
      reset_opts.workspace_root = reset_opts.workspace_root or manifest.workspace_root
      reset_opts.package_name = reset_opts.package_name or manifest.package_name
      reset_opts.scope = reset_opts.scope or manifest.scope
    end
  end
  return require("cargo-features.lsp").reset(reset_opts)
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
