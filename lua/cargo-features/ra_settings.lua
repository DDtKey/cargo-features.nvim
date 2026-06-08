local config = require("cargo-features.config")
local util = require("cargo-features.util")

local M = {}

local UNSET = {}

---@param client vim.lsp.Client
---@return table
function M.ensure_settings(client)
  client.config = client.config or {}
  if type(client.settings) ~= "table" then
    client.settings = type(client.config.settings) == "table" and client.config.settings or {}
  end
  client.config.settings = client.settings
  client.settings["rust-analyzer"] = client.settings["rust-analyzer"] or {}
  return client.settings
end

---@param client vim.lsp.Client
---@return table?
function M.settings(client)
  local settings = type(client.settings) == "table" and client.settings
    or client.config and client.config.settings
  if type(settings) ~= "table" then
    return nil
  end
  return settings["rust-analyzer"]
end

---@param client vim.lsp.Client
---@return table<string, boolean>
function M.enabled_features(client)
  local ra = M.settings(client)
  if type(ra) ~= "table" or type(ra.cargo) ~= "table" then
    return { default = true }
  end

  local features = ra.cargo.features
  if features == "all" then
    return { ["*"] = true }
  end

  local enabled = {}
  if type(features) == "table" then
    for _, feature in ipairs(features) do
      if type(feature) == "string" then
        enabled[feature] = true
      end
    end
  end

  if ra.cargo.noDefaultFeatures ~= true then
    enabled.default = true
  end

  return enabled
end

---@param selected string[]
---@param opts CargoFeaturesApplyOptions
---@return string[]|"all"
function M.resolve_cargo_features(selected, opts)
  local cargo_features = selected
  if
    config.get().lsp.use_all_features_token
    and opts.allow_all_features_token
    and opts.scope == "workspace"
    and opts.all_enabled
  then
    cargo_features = "all"
  end
  return cargo_features
end

---@param value any
---@return any
local function comparable_features(value)
  if type(value) ~= "table" then
    return value
  end

  local out = {}
  for _, feature in ipairs(value) do
    if type(feature) == "string" then
      table.insert(out, feature)
    end
  end
  return util.unique_sorted(out)
end

---@param a any
---@param b any
---@return boolean
local function same_feature_value(a, b)
  return vim.deep_equal(comparable_features(a), comparable_features(b))
end

---@param client vim.lsp.Client
---@param features string[]
---@param opts CargoFeaturesApplyOptions
---@return table
function M.desired_reapply_config(client, features, opts)
  local ra = M.settings(client) or {}
  local cargo_features = M.resolve_cargo_features(features, opts)
  local desired = {
    cargo_features = cargo_features,
    cargo_no_default = UNSET,
    check_features = UNSET,
    check_no_default = UNSET,
  }

  if opts.has_default then
    desired.cargo_no_default = opts.default_enabled ~= true
  end

  local sync = config.get().lsp.sync_check_features
  if sync == "always" then
    desired.check_features = cargo_features
    if opts.has_default then
      desired.check_no_default = opts.default_enabled ~= true
    end
  elseif sync == "if_set" and type(ra.check) == "table" then
    if ra.check.features ~= nil then
      desired.check_features = cargo_features
    end
    if opts.has_default and ra.check.noDefaultFeatures ~= nil then
      desired.check_no_default = opts.default_enabled ~= true
    end
  end

  return desired
end

---@param client vim.lsp.Client
---@param opts CargoFeaturesApplyOptions
---@return boolean
function M.has_explicit_feature_config(client, opts)
  local ra = M.settings(client)
  if type(ra) ~= "table" then
    return false
  end

  if type(ra.cargo) == "table" then
    if ra.cargo.features ~= nil or ra.cargo.noDefaultFeatures ~= nil then
      return true
    end
  end

  if type(ra.check) ~= "table" then
    return false
  end

  local sync = config.get().lsp.sync_check_features
  if sync == "never" then
    return false
  end

  if ra.check.features ~= nil then
    return true
  end

  return opts.has_default == true and ra.check.noDefaultFeatures ~= nil
end

---@param client vim.lsp.Client
---@param desired table
---@return boolean
function M.current_config_matches(client, desired)
  local ra = M.settings(client)
  if type(ra) ~= "table" then
    return false
  end

  local cargo = type(ra.cargo) == "table" and ra.cargo or {}
  if cargo.features == nil or not same_feature_value(cargo.features, desired.cargo_features) then
    return false
  end

  if desired.cargo_no_default ~= UNSET then
    if (cargo.noDefaultFeatures == true) ~= desired.cargo_no_default then
      return false
    end
  elseif cargo.noDefaultFeatures ~= nil then
    return false
  end

  local check = type(ra.check) == "table" and ra.check or {}
  if desired.check_features ~= UNSET then
    if check.features == nil or not same_feature_value(check.features, desired.check_features) then
      return false
    end
  elseif check.features ~= nil then
    return false
  end

  if desired.check_no_default ~= UNSET then
    if (check.noDefaultFeatures == true) ~= desired.check_no_default then
      return false
    end
  elseif check.noDefaultFeatures ~= nil then
    return false
  end

  return true
end

---@param client vim.lsp.Client
---@param selected string[]
---@param opts CargoFeaturesApplyOptions
function M.apply(client, selected, opts)
  local cargo_features = M.resolve_cargo_features(selected, opts)
  local settings = M.ensure_settings(client)
  local ra = settings["rust-analyzer"]
  ra.cargo = ra.cargo or {}
  ra.cargo.features = cargo_features

  -- `cargo.features` is a set-like workspace option and can be merged across
  -- remembered package selections. `cargo.noDefaultFeatures` is also
  -- workspace-global, but it is not package-local and cannot be merged per
  -- member. Workspace member applies therefore avoid modeling package default
  -- toggles; only explicit workspace/package-default state updates this value.
  if opts.has_default then
    ra.cargo.noDefaultFeatures = opts.default_enabled ~= true
  end

  -- Some existing configs still contain the old allFeatures key. Clearing it
  -- avoids contradictory settings while keeping the current official key.
  if ra.cargo.allFeatures ~= nil then
    ra.cargo.allFeatures = false
  end

  local sync = config.get().lsp.sync_check_features
  if sync == "always" then
    ra.check = ra.check or {}
    ra.check.features = cargo_features
    if opts.has_default then
      ra.check.noDefaultFeatures = opts.default_enabled ~= true
    end
  elseif sync == "if_set" and type(ra.check) == "table" then
    if ra.check.features ~= nil then
      ra.check.features = cargo_features
    end
    if opts.has_default and ra.check.noDefaultFeatures ~= nil then
      ra.check.noDefaultFeatures = opts.default_enabled ~= true
    end
  end

  if config.get().lsp.notify then
    client:notify("workspace/didChangeConfiguration", { settings = settings })
  end
end

return M
