local config = require("cargo-features.config")
local ra_settings = require("cargo-features.ra_settings")
local state = require("cargo-features.state")
local util = require("cargo-features.util")

local M = {}
local autocmd_created = false
local reapplied_clients = {}

---@param client vim.lsp.Client
---@return boolean
function M.is_rust_analyzer_client(client)
  if not client then
    return false
  end
  if client.name == "rust-analyzer" or client.name == "rust_analyzer" then
    return true
  end

  local cmd = client.config and client.config.cmd
  local executable = type(cmd) == "table" and cmd[1] or nil
  if type(executable) ~= "string" or executable == "" then
    return false
  end

  local basename = vim.fs.basename(executable:gsub("\\", "/"))
  return basename == "rust-analyzer" or basename == "rust-analyzer.exe"
end

---@param opts? table
---@return vim.lsp.Client[]
local function get_lsp_clients(opts)
  local ok, clients = pcall(vim.lsp.get_clients, opts)
  if not ok then
    return {}
  end
  return clients
end

---@param opts? table
---@return vim.lsp.Client[]
local function rust_analyzer_clients(opts)
  return vim.tbl_filter(M.is_rust_analyzer_client, get_lsp_clients(opts))
end

---@class CargoFeaturesClientFilter
---@field bufnr? integer
---@field manifest_path? string
---@field allow_global? boolean

---@param path string
---@param root string
---@return boolean
local function path_is_inside(path, root)
  local normalized_path = util.abspath(path)
  local normalized_root = util.abspath(root):gsub("[/\\]$", "")
  return normalized_path == normalized_root or normalized_path:sub(1, #normalized_root + 1) == normalized_root .. "/"
end

---@param client vim.lsp.Client
---@return string[]
function M.client_roots(client)
  local roots = {}
  local seen = {}

  local function add(root)
    if type(root) == "string" and root ~= "" then
      local normalized = util.abspath(root)
      if not seen[normalized] then
        seen[normalized] = true
        table.insert(roots, normalized)
      end
    end
  end

  add(client.root_dir)
  if type(client.config) == "table" then
    add(client.config.root_dir)
  end

  for _, folder in ipairs(client.workspace_folders or {}) do
    if type(folder) == "table" then
      add(folder.name)
      if type(folder.uri) == "string" then
        local ok, path = pcall(vim.uri_to_fname, folder.uri)
        if ok then
          add(path)
        end
      end
    end
  end

  return roots
end

---@param client vim.lsp.Client
---@param manifest_path string
---@return boolean
function M.client_covers_manifest(client, manifest_path)
  for _, root in ipairs(M.client_roots(client)) do
    if path_is_inside(manifest_path, root) then
      return true
    end
  end
  return false
end

---@param opts? CargoFeaturesClientFilter|integer
---@return vim.lsp.Client[]
function M.get_clients(opts)
  if type(opts) == "number" then
    opts = { bufnr = opts }
  end
  opts = opts or {}

  if opts.bufnr and opts.bufnr > 0 then
    local attached = rust_analyzer_clients({
      bufnr = opts.bufnr,
    })
    if #attached > 0 then
      if opts.manifest_path then
        local covered = vim.tbl_filter(function(client)
          return M.client_covers_manifest(client, opts.manifest_path)
        end, attached)
        if #covered > 0 then
          return covered
        end
      end

      -- A rust-analyzer client attached to the current Rust buffer is the
      -- strongest signal available. Some real setups have nil, URI-shaped, or
      -- symlinked roots, so root coverage is used to narrow attached clients
      -- when possible, not to reject all attached clients.
      return attached
    end
  end

  local all = rust_analyzer_clients()

  if opts.manifest_path then
    return vim.tbl_filter(function(client)
      return M.client_covers_manifest(client, opts.manifest_path)
    end, all)
  end

  if opts.allow_global then
    return all
  end

  return {}
end

---@param opts? CargoFeaturesClientFilter|integer
---@return string?
function M.no_client_error(opts)
  if type(opts) == "number" then
    opts = { bufnr = opts }
  end
  opts = opts or {}

  local clients = rust_analyzer_clients()
  if #clients == 0 then
    return "No active rust-analyzer client found"
  end

  local attached = {}
  if opts.bufnr and opts.bufnr > 0 then
    attached = rust_analyzer_clients({
      bufnr = opts.bufnr,
    })
  end

  if opts.manifest_path then
    local lines = {
      "No matching rust-analyzer client found",
      ("Active rust-analyzer clients: %s"):format(#clients > 0 and "yes" or "no"),
      ("Attached to buffer %s: %s"):format(
        opts.bufnr or "(not provided)",
        opts.bufnr and (#attached > 0 and "yes" or "no") or "unknown"
      ),
      ("Cargo manifest: %s"):format(util.abspath(opts.manifest_path)),
      "Known rust-analyzer client roots:",
    }

    for _, client in ipairs(clients) do
      local roots = M.client_roots(client)
      local root_text = #roots > 0 and table.concat(roots, ", ") or "(no roots)"
      table.insert(lines, ("- client %s: %s"):format(client.id or "?", root_text))
    end

    return table.concat(lines, "\n")
  end

  return "No matching rust-analyzer client found"
end

---@param opts? { bufnr?: integer, manifest_path?: string }
---@return string
function M.debug_clients(opts)
  opts = opts or {}
  local bufnr = opts.bufnr or vim.api.nvim_get_current_buf()
  local manifest_path = opts.manifest_path

  if not manifest_path then
    local ok, cargo = pcall(require, "cargo-features.cargo")
    if ok then
      manifest_path = cargo.find_manifest(bufnr)
    end
  end

  local clients = rust_analyzer_clients()

  local attached = {}
  local attached_clients = rust_analyzer_clients({
    bufnr = bufnr,
  })
  for _, client in ipairs(attached_clients) do
    attached[client.id or client] = true
  end

  local lines = {
    "cargo-features.nvim rust-analyzer clients",
    ("buffer: %s"):format(bufnr),
    ("manifest: %s"):format(manifest_path and util.abspath(manifest_path) or "(not found)"),
  }

  if #clients == 0 then
    table.insert(lines, "no active rust-analyzer clients")
  end

  for _, client in ipairs(clients) do
    local roots = M.client_roots(client)
    local covers = manifest_path and M.client_covers_manifest(client, manifest_path) or false
    table.insert(lines, ("client %s"):format(client.id or "?"))
    table.insert(lines, ("  name: %s"):format(client.name or "(nil)"))
    table.insert(lines, ("  attached: %s"):format(attached[client.id or client] and "yes" or "no"))
    table.insert(lines, ("  root_dir: %s"):format(client.root_dir or "(nil)"))
    table.insert(lines, ("  config.root_dir: %s"):format(client.config and client.config.root_dir or "(nil)"))
    table.insert(lines, ("  workspace_folders: %s"):format(#roots > 0 and table.concat(roots, ", ") or "(none)"))
    table.insert(lines, ("  covers manifest: %s"):format(covers and "yes" or "no"))
  end

  local message = table.concat(lines, "\n")
  vim.notify(message, vim.log.levels.INFO, { title = "cargo-features.nvim" })
  return message
end

---@param client vim.lsp.Client
---@return table<string, boolean>
function M.enabled_features(client)
  return ra_settings.enabled_features(client)
end

---@class CargoFeaturesApplyOptions
---@field bufnr? integer
---@field manifest_path? string
---@field workspace_root? string
---@field package_name? string
---@field has_default? boolean
---@field default_enabled? boolean
---@field all_enabled? boolean
---@field scope? "package"|"workspace"
---@field allow_global? boolean
---@field allow_all_features_token? boolean
---@field remember? boolean

---@param entry CargoFeaturesAppliedSelection
---@return string
local function workspace_key(entry)
  if entry.workspace_root and entry.workspace_root ~= "" then
    return util.abspath(entry.workspace_root)
  end
  return util.abspath(entry.manifest_path)
end

---@param a CargoFeaturesAppliedSelection
---@param b CargoFeaturesAppliedSelection
---@return boolean
local function same_workspace(a, b)
  return workspace_key(a) == workspace_key(b)
end

---@param client vim.lsp.Client
---@param selected string[]
---@param opts CargoFeaturesApplyOptions
---@return string[]
---@return boolean merged_with_remembered
local function merged_features_for_client(client, selected, opts)
  local current = vim.tbl_extend("force", opts, {
    manifest_path = opts.manifest_path or "",
    selected = selected,
  })
  local merged = {}
  local merged_with_remembered = false

  local function add(features)
    for _, feature in ipairs(features or {}) do
      if type(feature) == "string" and feature ~= "" then
        table.insert(merged, feature)
      end
    end
  end

  for _, entry in ipairs(state.applied()) do
    if
      entry.manifest_path ~= opts.manifest_path
      and same_workspace(entry, current)
      and M.client_covers_manifest(client, entry.manifest_path)
    then
      add(entry.selected)
      merged_with_remembered = true
    end
  end

  add(selected)
  return util.unique_sorted(merged), merged_with_remembered
end

---@param selected string[]
---@param opts? CargoFeaturesApplyOptions
---@return boolean ok
---@return string? err
function M.apply(selected, opts)
  opts = opts or {}
  local clients = M.get_clients({
    bufnr = opts.bufnr,
    manifest_path = opts.manifest_path,
    allow_global = opts.allow_global,
  })
  if #clients == 0 then
    return false, M.no_client_error({
      bufnr = opts.bufnr,
      manifest_path = opts.manifest_path,
      allow_global = opts.allow_global,
    })
  end

  if opts.remember == true and opts.manifest_path then
    state.remember_applied({
      selected = selected,
      manifest_path = opts.manifest_path,
      workspace_root = opts.workspace_root,
      package_name = opts.package_name,
      scope = opts.scope,
      has_default = opts.has_default,
      default_enabled = opts.default_enabled,
      all_enabled = opts.all_enabled,
      allow_all_features_token = opts.allow_all_features_token,
    })
  end

  for _, client in ipairs(clients) do
    local effective_selected = selected
    local effective_opts = opts
    if opts.manifest_path then
      local merged_with_remembered
      effective_selected, merged_with_remembered = merged_features_for_client(client, selected, opts)
      if merged_with_remembered then
        effective_opts = vim.tbl_extend("force", opts, {
          all_enabled = false,
          allow_all_features_token = false,
        })
      end
    end
    ra_settings.apply(client, effective_selected, effective_opts)
  end

  return true, nil
end

---@class CargoFeaturesReapplyGroup
---@field key string
---@field entries CargoFeaturesAppliedSelection[]

---@param client vim.lsp.Client
---@return CargoFeaturesReapplyGroup[]
local function matching_applied_groups(client)
  local by_key = {}
  local groups = {}

  for _, entry in ipairs(state.applied()) do
    if M.client_covers_manifest(client, entry.manifest_path) then
      local key = workspace_key(entry)
      if not by_key[key] then
        by_key[key] = { key = key, entries = {} }
        table.insert(groups, by_key[key])
      end
      table.insert(by_key[key].entries, entry)
    end
  end

  table.sort(groups, function(a, b)
    return a.key < b.key
  end)

  for _, group in ipairs(groups) do
    table.sort(group.entries, function(a, b)
      return (a.manifest_path or "") < (b.manifest_path or "")
    end)
  end

  return groups
end

---@param entries CargoFeaturesAppliedSelection[]
---@return string[]
local function merged_entry_features(entries)
  local features = {}
  for _, entry in ipairs(entries) do
    for _, feature in ipairs(entry.selected or {}) do
      table.insert(features, feature)
    end
  end
  return util.unique_sorted(features)
end

---@param entries CargoFeaturesAppliedSelection[]
---@return CargoFeaturesApplyOptions
local function merged_entry_opts(entries)
  local effective = vim.tbl_extend("force", entries[#entries] or {}, { remember = false })

  -- Default features are workspace-global in rust-analyzer. If remembered
  -- states ever disagree inside one Cargo workspace, prefer enabled defaults
  -- when any entry enables them; otherwise set noDefaultFeatures=true.
  local has_default = false
  local default_enabled = false
  for _, entry in ipairs(entries) do
    if entry.has_default then
      has_default = true
      if entry.default_enabled == true then
        default_enabled = true
      end
    end
  end
  effective.has_default = has_default
  if has_default then
    effective.default_enabled = default_enabled
  else
    effective.default_enabled = nil
  end

  if #entries == 1 then
    return effective
  end

  effective.all_enabled = false
  effective.allow_all_features_token = false
  return effective
end

---@param entries CargoFeaturesAppliedSelection[]
---@return boolean
local function can_reapply_all_token(entries)
  local entry = entries[1]
  return #entries == 1
    and entry.scope == "workspace"
    and entry.all_enabled == true
    and entry.allow_all_features_token == true
end

---@param client vim.lsp.Client
function M.reapply_for_client(client)
  if not M.is_rust_analyzer_client(client) then
    return
  end
  local reapply_policy = config.get().lsp.reapply_policy
  if reapply_policy == "never" then
    return
  end

  local client_key = client.id or tostring(client)
  if reapplied_clients[client_key] then
    return
  end

  local groups = matching_applied_groups(client)
  if #groups == 0 then
    return
  end

  reapplied_clients[client_key] = true

  if #groups > 1 then
    local keys = vim.tbl_map(function(group)
      return group.key
    end, groups)
    vim.notify(
      ("cargo-features.nvim: rust-analyzer client matches multiple Cargo workspaces; skipping automatic feature reapply: %s"):format(
        table.concat(keys, ", ")
      ),
      vim.log.levels.WARN,
      { title = "cargo-features.nvim" }
    )
    return
  end

  local entries = groups[1].entries
  local features = merged_entry_features(entries)
  local effective_opts = merged_entry_opts(entries)

  if not can_reapply_all_token(entries) then
    effective_opts.all_enabled = false
    effective_opts.allow_all_features_token = false
  end

  local desired = ra_settings.desired_reapply_config(client, features, effective_opts)
  if ra_settings.current_config_matches(client, desired) then
    return
  end

  if reapply_policy == "if_empty" and ra_settings.has_explicit_feature_config(client, effective_opts) then
    vim.notify(
      "cargo-features.nvim: rust-analyzer already has explicit Cargo feature settings; skipping remembered feature reapply",
      vim.log.levels.INFO,
      { title = "cargo-features.nvim" }
    )
    return
  end

  ra_settings.apply(client, features, effective_opts)
end

function M._clear_reapplied_clients()
  reapplied_clients = {}
end

function M.create_autocmd()
  if autocmd_created then
    return
  end
  autocmd_created = true

  local group = vim.api.nvim_create_augroup("CargoFeaturesLspAttach", { clear = true })
  vim.api.nvim_create_autocmd("LspAttach", {
    group = group,
    callback = function(args)
      local client = vim.lsp.get_client_by_id(args.data.client_id)
      M.reapply_for_client(client)
    end,
  })
end

return M
