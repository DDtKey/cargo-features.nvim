local config = require("cargo-features.config")
local util = require("cargo-features.util")

local M = {}

---@class CargoFeaturesProfile
---@field features string[]
---@field default_enabled? boolean
---@field scope? "package"|"workspace"
---@field manifest_path string
---@field workspace_root? string
---@field package_name? string

---@class CargoFeaturesProfileStore
---@field version integer
---@field profiles table<string, table<string, CargoFeaturesProfile>>

---@type CargoFeaturesProfileStore
local profile_store = {
  version = 1,
  profiles = {},
}

local loaded = false
local invalid_store_path = nil
local invalid_store_warned = false

---@return string
local function state_path()
  return vim.fs.joinpath(vim.fn.stdpath("state"), "cargo-features.nvim", "profiles.json")
end

---@param opts table
---@return string?
local function profile_key(opts)
  if opts.scope == "workspace" and opts.workspace_root and opts.workspace_root ~= "" then
    return util.abspath(opts.workspace_root)
  end
  if opts.manifest_path and opts.manifest_path ~= "" then
    return util.abspath(opts.manifest_path)
  end
  if opts.workspace_root and opts.workspace_root ~= "" then
    return util.abspath(opts.workspace_root)
  end
  return nil
end

---@param name? string
---@return string
local function profile_name(name)
  if type(name) == "string" and name ~= "" then
    return name
  end
  return config.get().persistence.default_profile
end

---@param raw any
---@return boolean
local function is_profile_store(raw)
  if type(raw) == "table" and raw.version == 1 and type(raw.profiles) == "table" then
    return true
  end
  return false
end

---@param path string
---@param reason string
local function mark_invalid_store(path, reason)
  invalid_store_path = path
  if invalid_store_warned then
    return
  end
  invalid_store_warned = true
  util.notify(
    ("Ignoring invalid Cargo feature profile store (%s). It will be moved aside before saving a fresh v1 store."):format(
      reason
    ),
    vim.log.levels.WARN
  )
end

local function load()
  if loaded then
    return
  end
  loaded = true

  local path = state_path()
  if vim.fn.filereadable(path) ~= 1 then
    return
  end

  local ok, lines = pcall(vim.fn.readfile, path)
  if not ok then
    mark_invalid_store(path, "read failed")
    return
  end

  local decoded_ok, decoded = pcall(vim.json.decode, table.concat(lines, "\n"))
  if not decoded_ok then
    mark_invalid_store(path, "malformed JSON")
    return
  end

  if not is_profile_store(decoded) then
    mark_invalid_store(path, "unsupported version")
    return
  end

  profile_store = decoded
end

---@param path string
---@return boolean ok
---@return string? err
local function backup_invalid_store(path)
  local source = invalid_store_path
  if not source or vim.fn.filereadable(source) ~= 1 then
    invalid_store_path = nil
    return true, nil
  end

  local backup = source .. ".bak"
  if vim.fn.filereadable(backup) == 1 then
    backup = ("%s.%s.bak"):format(source, os.time())
  end

  local ok, result = pcall(vim.fn.rename, source, backup)
  if not ok then
    return false, result
  end
  if result ~= 0 then
    return false, ("unable to move invalid profile store to %s"):format(backup)
  end

  invalid_store_path = nil
  return true, nil
end

local function save()
  local path = state_path()
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  local backup_ok, backup_err = backup_invalid_store(path)
  if not backup_ok then
    return false, backup_err
  end

  local ok, err = pcall(vim.fn.writefile, { vim.json.encode(profile_store) }, path)
  if not ok then
    return false, err
  end
  return true, nil
end

---@param name? string
---@param opts CargoFeaturesProfile
---@return boolean ok
---@return string? err
function M.save_profile(name, opts)
  if type(opts) ~= "table" then
    return false, "profile options are required"
  end

  local key = profile_key(opts)
  if not key then
    return false, "manifest_path or workspace_root is required"
  end

  load()

  local profile = {
    features = util.unique_sorted(opts.features or {}),
    default_enabled = opts.default_enabled,
    scope = opts.scope,
    manifest_path = opts.manifest_path and util.abspath(opts.manifest_path) or nil,
    workspace_root = opts.workspace_root and util.abspath(opts.workspace_root) or nil,
    package_name = opts.package_name,
  }

  if not profile.manifest_path then
    return false, "manifest_path is required"
  end

  profile_store.profiles[key] = profile_store.profiles[key] or {}
  profile_store.profiles[key][profile_name(name)] = profile
  return save()
end

---@param name? string
---@param opts table
---@return CargoFeaturesProfile?
function M.load_profile(name, opts)
  opts = opts or {}

  local key = profile_key(opts)
  if not key then
    return nil
  end

  load()

  local profiles = profile_store.profiles[key]
  local profile = profiles and profiles[profile_name(name)] or nil
  return profile and vim.deepcopy(profile) or nil
end

---@param name? string
---@param opts table
---@return boolean ok
---@return string? err
function M.delete_profile(name, opts)
  opts = opts or {}

  local key = profile_key(opts)
  if not key then
    return false, "manifest_path or workspace_root is required"
  end

  load()

  local profiles = profile_store.profiles[key]
  if profiles then
    profiles[profile_name(name)] = nil
    if vim.tbl_isempty(profiles) then
      profile_store.profiles[key] = nil
    end
  end

  return save()
end

---@param opts table
---@return string[]
function M.list_profiles(opts)
  opts = opts or {}

  local key = profile_key(opts)
  if not key then
    return {}
  end

  load()

  local names = {}
  for name, _ in pairs(profile_store.profiles[key] or {}) do
    table.insert(names, name)
  end
  table.sort(names)
  return names
end

function M._reset_for_tests()
  loaded = false
  invalid_store_path = nil
  invalid_store_warned = false
  profile_store = {
    version = 1,
    profiles = {},
  }
end

---@return CargoFeaturesProfileStore
function M._profiles_for_tests()
  return vim.deepcopy(profile_store)
end

return M
