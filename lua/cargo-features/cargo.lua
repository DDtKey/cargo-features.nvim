local config = require("cargo-features.config")
local util = require("cargo-features.util")

local M = {}

---@class CargoFeaturesFeature
---@field name string Display name.
---@field apply_name string Feature string sent to rust-analyzer.
---@field package? string Cargo package name.
---@field is_default boolean Whether this is the package's default feature.

---@class CargoFeaturesManifest
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

---@param manifest_path string
---@return CargoFeaturesManifest?, string?
function M.parse_toml(manifest_path)
  local ok, lines = pcall(vim.fn.readfile, manifest_path)
  if not ok then
    return nil, ("Unable to read %s"):format(manifest_path)
  end

  local section = nil
  local package_name = nil
  local features = {}

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
        local raw_key = line:match("^([^=]+)%s*=")
        local name = parse_key(raw_key or "")
        if name then
          table.insert(features, {
            name = name,
            apply_name = name,
            package = package_name,
            is_default = name == "default",
          })
        end
      end
    end
  end

  table.sort(features, function(a, b)
    if a.is_default ~= b.is_default then
      return a.is_default
    end
    return a.name < b.name
  end)

  return {
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

  local function add_package_features(package, qualified)
    local names = {}
    for name, _ in pairs(package.features or {}) do
      table.insert(names, name)
    end
    table.sort(names, function(a, b)
      if (a == "default") ~= (b == "default") then
        return a == "default"
      end
      return a < b
    end)

    for _, name in ipairs(names) do
      if not (qualified and name == "default") then
        table.insert(features, {
          name = qualified and ("%s/%s"):format(package.name, name) or name,
          apply_name = qualified and ("%s/%s"):format(package.name, name) or name,
          package = package.name,
          is_default = not qualified and name == "default",
        })
      end
    end
  end

  if exact_package then
    package_name = exact_package.name
    scope = "package"
    add_package_features(exact_package, workspace_root ~= nil and workspace_root ~= manifest_dir)
  else
    table.sort(workspace_packages, function(a, b)
      return a.name < b.name
    end)
    for _, package in ipairs(workspace_packages) do
      add_package_features(package, true)
    end
  end

  return {
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
