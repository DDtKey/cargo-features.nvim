local config = require("cargo-features.config")

local M = {}

---@param opts? table
---@return table?
---@return string?
local function resolve_context(opts)
  opts = opts or {}
  local cargo = require("cargo-features.cargo")
  local bufnr = opts.bufnr or vim.api.nvim_get_current_buf()
  local manifest_path = opts.manifest_path
  if not manifest_path then
    manifest_path = cargo.find_manifest(bufnr)
  end
  if not manifest_path then
    return nil, "No Cargo.toml found above the current buffer"
  end

  local context = vim.tbl_extend("force", opts, {
    bufnr = bufnr,
    manifest_path = manifest_path,
  })
  if not context.workspace_root or not context.scope or not context.package_name then
    local manifest = cargo.load_manifest(manifest_path)
    if manifest then
      context.workspace_root = context.workspace_root or manifest.workspace_root
      context.package_name = context.package_name or manifest.package_name
      context.scope = context.scope or manifest.scope
    end
  end
  return context, nil
end

---@param opts? table
---@return table?
---@return string?
function M._resolve_context(opts)
  return resolve_context(opts)
end

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
  local reset_opts, err = resolve_context(opts)
  if not reset_opts then
    return false, err
  end
  return require("cargo-features.lsp").reset(reset_opts)
end

---@param name? string
---@param opts? table
---@return boolean ok
---@return string? err
function M.apply_profile(name, opts)
  local apply_opts, err = resolve_context(opts)
  if not apply_opts then
    return false, err
  end

  local profile_name = type(name) == "string" and name ~= "" and name or config.get().persistence.default_profile
  local profile = require("cargo-features.profile_store").load_profile(profile_name, apply_opts)
  if not profile then
    return false, ("Profile not found: %s"):format(profile_name)
  end

  apply_opts = vim.tbl_extend("force", apply_opts, {
    default_enabled = profile.default_enabled,
    has_default = profile.default_enabled ~= nil,
    package_name = profile.package_name or apply_opts.package_name,
    scope = profile.scope or apply_opts.scope,
    workspace_root = profile.workspace_root or apply_opts.workspace_root,
    remember = true,
  })

  return require("cargo-features.lsp").apply(profile.features or {}, apply_opts)
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
