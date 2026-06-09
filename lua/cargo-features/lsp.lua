local config = require("cargo-features.config")
local ra_settings = require("cargo-features.ra_settings")
local state = require("cargo-features.state")
local util = require("cargo-features.util")

local M = {}
local autocmd_created = false
local reapplied_clients = {}
local applied_attach_profiles = {}
local BUFFER_REATTACH_DELAY_MS = 700

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
  return normalized_path == normalized_root
    or normalized_path:sub(1, #normalized_root + 1) == normalized_root .. "/"
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
    table.insert(
      lines,
      ("  config.root_dir: %s"):format(client.config and client.config.root_dir or "(nil)")
    )
    table.insert(
      lines,
      ("  workspace_folders: %s"):format(#roots > 0 and table.concat(roots, ", ") or "(none)")
    )
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
---@field remember? boolean

---@class CargoFeaturesResetOptions
---@field bufnr? integer
---@field manifest_path? string
---@field workspace_root? string
---@field package_name? string
---@field scope? "package"|"workspace"
---@field allow_global? boolean
---@field force? boolean

---@param client vim.lsp.Client
---@return integer[]
local function rust_buffers_for_client(client)
  if not client.id then
    return {}
  end

  local bufnrs = {}
  if type(vim.lsp.get_buffers_by_client_id) == "function" then
    local ok, attached = pcall(vim.lsp.get_buffers_by_client_id, client.id)
    if ok and type(attached) == "table" then
      bufnrs = attached
    end
  end

  local rust = {}
  for _, bufnr in ipairs(bufnrs) do
    if
      vim.api.nvim_buf_is_valid(bufnr)
      and vim.api.nvim_buf_is_loaded(bufnr)
      and vim.api.nvim_get_option_value("filetype", { buf = bufnr }) == "rust"
    then
      table.insert(rust, bufnr)
    end
  end
  return util.unique_sorted(rust)
end

---@param client_id integer
---@param bufnr integer
---@return boolean
local function buffer_has_client(client_id, bufnr)
  if type(vim.lsp.get_buffers_by_client_id) ~= "function" then
    return false
  end
  local ok, bufnrs = pcall(vim.lsp.get_buffers_by_client_id, client_id)
  if not ok or type(bufnrs) ~= "table" then
    return false
  end
  for _, attached_bufnr in ipairs(bufnrs) do
    if attached_bufnr == bufnr then
      return true
    end
  end
  return false
end

---@param client_id integer
---@return boolean
local function client_exists(client_id)
  if type(vim.lsp.get_client_by_id) ~= "function" then
    return true
  end
  local ok, client = pcall(vim.lsp.get_client_by_id, client_id)
  return ok and client ~= nil
end

---@param clients vim.lsp.Client[]
function M.reattach_buffers_after_apply(clients)
  if
    type(vim.lsp.buf_detach_client) ~= "function"
    or type(vim.lsp.buf_attach_client) ~= "function"
    or type(vim.lsp.get_buffers_by_client_id) ~= "function"
  then
    return
  end

  local seen = {}
  for _, client in ipairs(clients) do
    local client_id = client.id
    if client_id then
      for _, bufnr in ipairs(rust_buffers_for_client(client)) do
        local key = ("%s:%s"):format(client_id, bufnr)
        if not seen[key] then
          seen[key] = true
          vim.defer_fn(function()
            if
              not vim.api.nvim_buf_is_valid(bufnr)
              or not vim.api.nvim_buf_is_loaded(bufnr)
              or not client_exists(client_id)
              or not buffer_has_client(client_id, bufnr)
            then
              return
            end

            pcall(vim.lsp.buf_detach_client, bufnr, client_id)
            pcall(vim.lsp.buf_attach_client, bufnr, client_id)
            pcall(vim.cmd, "redraw!")
          end, BUFFER_REATTACH_DELAY_MS)
        end
      end
    end
  end
end

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
    return false,
      M.no_client_error({
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
    })
  end

  for _, client in ipairs(clients) do
    local effective_selected = selected
    local effective_opts = opts
    if opts.manifest_path then
      local merged_with_remembered
      effective_selected, merged_with_remembered =
        merged_features_for_client(client, selected, opts)
      if merged_with_remembered then
        effective_opts = vim.tbl_extend("force", opts, {
          all_enabled = false,
        })
      end
    end
    ra_settings.apply(client, effective_selected, effective_opts)
  end

  M.reattach_buffers_after_apply(clients)

  return true, nil
end

---@param opts? CargoFeaturesResetOptions
---@return boolean ok
---@return string? err
function M.reset(opts)
  opts = opts or {}
  local clients = M.get_clients({
    bufnr = opts.bufnr,
    manifest_path = opts.manifest_path,
    allow_global = opts.allow_global,
  })
  if #clients == 0 then
    return false,
      M.no_client_error({
        bufnr = opts.bufnr,
        manifest_path = opts.manifest_path,
        allow_global = opts.allow_global,
      })
  end

  local any_reset = false
  local errors = {}
  local reset_clients = {}
  for _, client in ipairs(clients) do
    local ok, err = ra_settings.reset(client, opts)
    if ok then
      any_reset = true
      table.insert(reset_clients, client)
    elseif err then
      table.insert(errors, err)
    end
  end

  if not any_reset then
    return false, errors[1] or "No plugin-applied Cargo feature override is remembered"
  end

  if opts.manifest_path then
    state.forget_applied({
      manifest_path = opts.manifest_path,
      workspace_root = opts.workspace_root,
    })
  end

  M.reattach_buffers_after_apply(reset_clients)
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
  return effective
end

---@param client vim.lsp.Client
function M.reapply_for_client(client)
  if not M.is_rust_analyzer_client(client) then
    return
  end
  if not config.get().lsp.reapply then
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
  effective_opts.all_enabled = false

  local desired = ra_settings.desired_reapply_config(client, features, effective_opts)
  if ra_settings.current_config_matches(client, desired) then
    return
  end

  if ra_settings.has_explicit_feature_config(client, effective_opts) then
    vim.notify(
      "cargo-features.nvim: rust-analyzer already has explicit Cargo feature settings; skipping remembered feature reapply",
      vim.log.levels.INFO,
      { title = "cargo-features.nvim" }
    )
    return
  end

  ra_settings.apply(client, features, effective_opts)
  M.reattach_buffers_after_apply({ client })
end

---@param opts CargoFeaturesApplyOptions
---@return string
local function attach_profile_key(client, opts)
  local key
  if opts.scope == "workspace" and opts.workspace_root and opts.workspace_root ~= "" then
    key = util.abspath(opts.workspace_root)
  else
    key = util.abspath(opts.manifest_path or "")
  end
  return ("%s:%s:%s"):format(client.id or tostring(client), opts.scope or "package", key)
end

---@param base CargoFeaturesApplyOptions
---@return CargoFeaturesApplyOptions[]
local function profile_contexts_for_attach(base)
  local contexts = {}
  if base.manifest_path and base.manifest_path ~= "" then
    table.insert(
      contexts,
      vim.tbl_extend("force", base, {
        scope = "package",
      })
    )
  end
  if base.workspace_root and base.workspace_root ~= "" then
    table.insert(
      contexts,
      vim.tbl_extend("force", base, {
        scope = "workspace",
      })
    )
  end
  return contexts
end

---@param bufnr integer
---@return CargoFeaturesApplyOptions?
local function attached_buffer_context(bufnr)
  local ok, cargo = pcall(require, "cargo-features.cargo")
  if not ok then
    return nil
  end

  local manifest_path = cargo.find_manifest(bufnr)
  if not manifest_path then
    return nil
  end

  local context = {
    bufnr = bufnr,
    manifest_path = manifest_path,
    scope = "package",
  }

  local manifest = cargo.load_manifest(manifest_path)
  if manifest then
    context.workspace_root = manifest.workspace_root
    context.package_name = manifest.package_name
    context.scope = manifest.scope or context.scope
  end

  return context
end

---@param context CargoFeaturesApplyOptions
---@return CargoFeaturesProfile?
---@return CargoFeaturesApplyOptions?
local function default_profile_for_attach(context)
  local profiles = require("cargo-features.profile_store")
  local name = config.get().persistence.default_profile

  -- Prefer the package-local default profile when both package and workspace
  -- defaults exist. Workspace fallback keeps root-level profiles usable from
  -- member Rust buffers.
  for _, candidate in ipairs(profile_contexts_for_attach(context)) do
    local profile = profiles.load_profile(name, candidate)
    if profile then
      return profile, candidate
    end
  end

  return nil, nil
end

---@param client vim.lsp.Client
---@param bufnr integer
---@return boolean applied
function M.apply_default_profile_for_client(client, bufnr)
  if not M.is_rust_analyzer_client(client) or config.get().persistence.apply_on_attach ~= true then
    return false
  end

  local context = attached_buffer_context(bufnr)
  if not context then
    return false
  end

  local profile, profile_context = default_profile_for_attach(context)
  if not profile or not profile_context then
    return false
  end

  local apply_opts = vim.tbl_extend("force", profile_context, {
    default_enabled = profile.default_enabled,
    has_default = profile.default_enabled ~= nil,
    manifest_path = profile.manifest_path or profile_context.manifest_path,
    package_name = profile.package_name or profile_context.package_name,
    scope = profile.scope or profile_context.scope,
    workspace_root = profile.workspace_root or profile_context.workspace_root,
    remember = true,
  })

  local key = attach_profile_key(client, apply_opts)
  if applied_attach_profiles[key] then
    return false
  end
  applied_attach_profiles[key] = true

  local features = profile.features or {}
  local desired = ra_settings.desired_reapply_config(client, features, apply_opts)
  if ra_settings.current_config_matches(client, desired) then
    return false
  end

  if ra_settings.has_explicit_feature_config(client, apply_opts) then
    return false
  end

  state.remember_applied({
    selected = features,
    manifest_path = apply_opts.manifest_path,
    workspace_root = apply_opts.workspace_root,
    package_name = apply_opts.package_name,
    scope = apply_opts.scope,
    has_default = apply_opts.has_default,
    default_enabled = apply_opts.default_enabled,
    all_enabled = false,
  })
  ra_settings.apply(client, features, apply_opts)
  M.reattach_buffers_after_apply({ client })
  return true
end

function M._clear_reapplied_clients()
  reapplied_clients = {}
  applied_attach_profiles = {}
end

M._rust_buffers_for_client = rust_buffers_for_client

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
      M.apply_default_profile_for_client(client, args.buf)
    end,
  })
end

return M
