local config = require("cargo-features.config")
local util = require("cargo-features.util")

local M = {}

---@class CargoFeaturesFeature
---@field name string Display name.
---@field apply_name string Feature string sent to rust-analyzer.
---@field package? string Cargo package name.
---@field default_included? boolean Whether this feature is directly listed in `[features].default`.

---@class CargoFeaturesManifest
---@field context "standalone"|"member"|"workspace"
---@field default_features_supported? boolean Whether cargo.noDefaultFeatures can safely be controlled here.
---@field features CargoFeaturesFeature[]
---@field manifest_path string
---@field package_name? string
---@field scope "package"|"workspace"
---@field source string
---@field workspace_root? string

---@param bufnr? integer
---@return string? manifest_path
function M.find_manifest(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local name = vim.api.nvim_buf_get_name(bufnr)
  local start = name ~= "" and util.dirname(name) or vim.uv.cwd()
  if not start or start == "" then
    return nil
  end

  local found = vim.fs.find("Cargo.toml", { upward = true, path = start, type = "file" })
  return found[1]
end

---@param line string
---@return string
local function strip_comment(line)
  local quote = nil
  local escaped = false
  for i = 1, #line do
    local ch = line:sub(i, i)
    if quote then
      if escaped then
        escaped = false
      elseif ch == "\\" then
        escaped = true
      elseif ch == quote then
        quote = nil
      end
    elseif ch == '"' or ch == "'" then
      quote = ch
    elseif ch == "#" then
      return line:sub(1, i - 1)
    end
  end
  return line
end

---@param raw string
---@return string?
local function parse_key(raw)
  raw = vim.trim(raw)
  if raw == "" then
    return nil
  end

  if raw:sub(1, 1) == '"' then
    local out = {}
    local escaped = false
    for i = 2, #raw do
      local ch = raw:sub(i, i)
      if escaped then
        table.insert(out, ch)
        escaped = false
      elseif ch == "\\" then
        escaped = true
      elseif ch == '"' then
        return table.concat(out)
      else
        table.insert(out, ch)
      end
    end
  end

  local quoted = raw:match("^'([^']*)'")
  if quoted then
    return quoted
  end

  return raw:match("^([%w_%-%+%.%/]+)")
end

---@param raw string
---@return string[]
local function parse_string_array(raw)
  local values = {}
  local quote = nil
  local escaped = false
  local current = {}

  for i = 1, #raw do
    local ch = raw:sub(i, i)
    if quote then
      if escaped then
        table.insert(current, ch)
        escaped = false
      elseif ch == "\\" then
        escaped = true
      elseif ch == quote then
        table.insert(values, table.concat(current))
        current = {}
        quote = nil
      else
        table.insert(current, ch)
      end
    elseif ch == '"' or ch == "'" then
      quote = ch
      current = {}
    end
  end

  return values
end

---@param manifest_path string
---@return CargoFeaturesManifest?, string?
function M.parse_toml(manifest_path)
  local ok, lines = pcall(vim.fn.readfile, manifest_path)
  if not ok then
    return nil, ("Unable to read %s"):format(manifest_path)
  end

  local section = nil
  local package_name = nil
  local feature_names = {}
  local feature_seen = {}
  local default_names = {}
  local default_declared = false

  for _, original in ipairs(lines) do
    local line = vim.trim(strip_comment(original))
    if line ~= "" then
      local header = line:match("^%[([^%]]+)%]$")
      if header then
        section = header
      elseif section == "package" then
        local key, value = line:match("^([^=]+)%s*=%s*(.+)$")
        if parse_key(key or "") == "name" then
          package_name = (value or ""):match('^"([^"]+)"') or (value or ""):match("^'([^']+)'")
        end
      elseif section == "features" then
        local raw_key, raw_value = line:match("^([^=]+)%s*=%s*(.+)$")
        local name = parse_key(raw_key or "")
        if name then
          if name == "default" then
            default_declared = true
            for _, default_name in ipairs(parse_string_array(raw_value or "")) do
              default_names[default_name] = true
            end
          elseif not feature_seen[name] then
            feature_seen[name] = true
            table.insert(feature_names, name)
          end
        end
      end
    end
  end

  local features = {}
  for _, name in ipairs(feature_names) do
    table.insert(features, {
      name = name,
      apply_name = name,
      package = package_name,
      default_included = default_names[name] == true,
    })
  end

  table.sort(features, function(a, b)
    return a.name < b.name
  end)

  return {
    context = package_name and "standalone" or "workspace",
    default_features_supported = package_name ~= nil and default_declared,
    features = features,
    manifest_path = util.abspath(manifest_path),
    package_name = package_name,
    scope = package_name and "package" or "workspace",
    source = "toml",
  },
    nil
end

---@param manifest_path string
---@return string[]
local function metadata_cmd(manifest_path)
  local cmd = {
    "cargo",
    "metadata",
    "--no-deps",
    "--format-version",
    "1",
    "--manifest-path",
    manifest_path,
  }

  for _, arg in ipairs(config.get().cargo.metadata_extra_args or {}) do
    table.insert(cmd, arg)
  end

  return cmd
end

---@param package table
---@return boolean
local function package_has_default_features(package)
  return type(package.features) == "table" and package.features.default ~= nil
end

---@param package table
---@return table<string, boolean>
local function package_default_feature_names(package)
  local default_names = {}
  for _, default_name in ipairs(package.features and package.features.default or {}) do
    if type(default_name) == "string" and package.features[default_name] ~= nil then
      default_names[default_name] = true
    end
  end
  return default_names
end

---@param features CargoFeaturesFeature[]
---@param package table
---@param opts { display_qualified?: boolean, apply_qualified?: boolean }
local function append_package_features(features, package, opts)
  local names = {}
  for name, _ in pairs(package.features or {}) do
    if name ~= "default" then
      table.insert(names, name)
    end
  end

  local default_names = package_default_feature_names(package)
  table.sort(names, function(a, b)
    return a < b
  end)

  for _, name in ipairs(names) do
    table.insert(features, {
      name = opts.display_qualified and ("%s/%s"):format(package.name, name) or name,
      apply_name = opts.apply_qualified and ("%s/%s"):format(package.name, name) or name,
      package = package.name,
      default_included = default_names[name] == true,
    })
  end
end

---@param manifest_path string
---@param result vim.SystemCompleted
---@return CargoFeaturesManifest?, string?
local function metadata_from_result(manifest_path, result)
  if result.code == 124 then
    return nil, "cargo metadata timed out"
  end

  if result.code ~= 0 then
    local stderr = vim.trim(result.stderr or "")
    return nil, stderr ~= "" and stderr or "cargo metadata failed"
  end

  local ok, metadata = pcall(vim.json.decode, result.stdout)
  if not ok or type(metadata) ~= "table" then
    return nil, "cargo metadata returned invalid JSON"
  end

  local normalized_manifest = util.abspath(manifest_path)
  local packages = metadata.packages or {}
  local workspace_members = {}
  for _, id in ipairs(metadata.workspace_members or {}) do
    workspace_members[id] = true
  end

  local exact_package = nil
  local workspace_packages = {}
  for _, package in ipairs(packages) do
    if package.manifest_path and util.abspath(package.manifest_path) == normalized_manifest then
      exact_package = package
      break
    end
    if workspace_members[package.id] then
      table.insert(workspace_packages, package)
    end
  end

  local features = {}
  local package_name = nil
  local scope = "workspace"
  local workspace_root = metadata.workspace_root and util.abspath(metadata.workspace_root) or nil
  local manifest_dir = util.dirname(normalized_manifest)
  local context = "workspace"
  local default_features_supported = false

  if exact_package then
    package_name = exact_package.name
    scope = "package"
    local is_member = workspace_root ~= nil and workspace_root ~= manifest_dir
    context = is_member and "member" or "standalone"
    default_features_supported = package_has_default_features(exact_package)
    append_package_features(features, exact_package, {
      apply_qualified = is_member,
      display_qualified = false,
    })
  else
    context = "workspace"
    table.sort(workspace_packages, function(a, b)
      return a.name < b.name
    end)
    for _, package in ipairs(workspace_packages) do
      if package_has_default_features(package) then
        default_features_supported = true
      end
      append_package_features(features, package, {
        apply_qualified = true,
        display_qualified = true,
      })
    end
  end

  return {
    context = context,
    default_features_supported = default_features_supported,
    features = features,
    manifest_path = normalized_manifest,
    package_name = package_name,
    scope = scope,
    source = "cargo metadata",
    workspace_root = workspace_root,
  },
    nil
end

---@param manifest_path string
---@return CargoFeaturesManifest?, string?
function M.metadata(manifest_path)
  if vim.fn.executable("cargo") ~= 1 then
    return nil, "cargo executable not found"
  end

  local result = vim
    .system(metadata_cmd(manifest_path), {
      cwd = config.get().cargo.metadata_cwd,
      env = config.get().cargo.metadata_env,
      text = true,
    })
    :wait(config.get().cargo.metadata_timeout)

  if not result then
    return nil, "cargo metadata timed out"
  end

  return metadata_from_result(manifest_path, result)
end

---@param manifest_path string
---@return CargoFeaturesManifest?, string?
function M.load_manifest(manifest_path)
  if config.get().cargo.use_metadata then
    local manifest, metadata_err = M.metadata(manifest_path)
    if manifest then
      return manifest, nil
    end

    local fallback, parse_err = M.parse_toml(manifest_path)
    if fallback then
      fallback.source = "toml fallback"
      return fallback, nil
    end

    return nil, parse_err or metadata_err
  end

  return M.parse_toml(manifest_path)
end

---@param manifest_path string
---@param callback fun(manifest: CargoFeaturesManifest?, err: string?)
function M.load_manifest_async(manifest_path, callback)
  if not config.get().cargo.use_metadata then
    vim.schedule(function()
      callback(M.parse_toml(manifest_path))
    end)
    return
  end

  if vim.fn.executable("cargo") ~= 1 then
    vim.schedule(function()
      local fallback, parse_err = M.parse_toml(manifest_path)
      if fallback then
        fallback.source = "toml fallback"
        callback(fallback, nil)
      else
        callback(nil, parse_err or "cargo executable not found")
      end
    end)
    return
  end

  local done = false
  local metadata_finished = false
  local proc

  local function finish(manifest, err)
    if done then
      return
    end
    done = true
    vim.schedule(function()
      callback(manifest, err)
    end)
  end

  proc = vim.system(metadata_cmd(manifest_path), {
    cwd = config.get().cargo.metadata_cwd,
    env = config.get().cargo.metadata_env,
    text = true,
  }, function(result)
    if done then
      return
    end
    metadata_finished = true

    vim.schedule(function()
      if done then
        return
      end

      local manifest, metadata_err = metadata_from_result(manifest_path, result)
      if manifest then
        finish(manifest, nil)
        return
      end

      local fallback, parse_err = M.parse_toml(manifest_path)
      if fallback then
        fallback.source = "toml fallback"
        finish(fallback, nil)
        return
      end

      finish(nil, parse_err or metadata_err)
    end)
  end)

  vim.defer_fn(function()
    if done or metadata_finished then
      return
    end

    if proc then
      pcall(function()
        proc:kill(15)
      end)
    end

    local fallback, parse_err = M.parse_toml(manifest_path)
    if fallback then
      fallback.source = "toml fallback"
      finish(fallback, nil)
    else
      finish(nil, parse_err or "cargo metadata timed out")
    end
  end, config.get().cargo.metadata_timeout)
end

return M
