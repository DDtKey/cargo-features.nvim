local cargo = require("cargo-features.cargo")
local config = require("cargo-features.config")
local lsp = require("cargo-features.lsp")
local profiles = require("cargo-features.profile_store")
local util = require("cargo-features.util")

local M = {}

---@class CargoFeaturesView
---@field bufnr integer
---@field default_enabled boolean
---@field default_features_supported boolean
---@field default_toggle_line? integer
---@field features CargoFeaturesFeature[]
---@field line_to_feature table<integer, integer>
---@field manifest CargoFeaturesManifest
---@field namespace integer
---@field source_bufnr integer
---@field win integer
---@field loading? boolean

---@type CargoFeaturesView?
local current = nil

local ns = vim.api.nvim_create_namespace("cargo-features.nvim")

---@param value integer|fun(): integer
---@param fallback integer
---@return integer
local function resolve_dimension(value, fallback)
  if type(value) == "function" then
    local ok, result = pcall(value)
    if ok and type(result) == "number" then
      return result
    end
    return fallback
  end
  return value
end

---@param title string
---@return integer bufnr
---@return integer win
local function create_window(title)
  local ui = config.get().ui
  local available_width = math.max(1, vim.o.columns - 2)
  local available_height = math.max(1, vim.o.lines - 3)
  local requested_width = resolve_dimension(ui.width, 60)
  local requested_height = resolve_dimension(ui.height, 18)
  local width = math.min(math.max(1, requested_width), available_width)
  local height = math.min(math.max(1, requested_height), available_height)
  local row = math.floor((vim.o.lines - height) / 2)
  local col = math.floor((vim.o.columns - width) / 2)

  local float_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_option_value("buftype", "nofile", { buf = float_buf })
  vim.api.nvim_set_option_value("bufhidden", "wipe", { buf = float_buf })
  vim.api.nvim_set_option_value("swapfile", false, { buf = float_buf })
  vim.api.nvim_set_option_value("filetype", "cargo-features", { buf = float_buf })

  local win = vim.api.nvim_open_win(float_buf, true, {
    relative = "editor",
    width = width,
    height = height,
    row = row,
    col = col,
    style = "minimal",
    border = ui.border,
    title = " " .. title .. " ",
    title_pos = "center",
  })

  vim.api.nvim_set_option_value("cursorline", true, { win = win })
  vim.api.nvim_set_option_value("wrap", false, { win = win })
  vim.api.nvim_set_option_value("number", false, { win = win })
  vim.api.nvim_set_option_value("relativenumber", false, { win = win })
  vim.api.nvim_set_option_value("signcolumn", "no", { win = win })
  vim.api.nvim_set_option_value(
    "winhl",
    "FloatBorder:CargoFeaturesBorder,FloatTitle:CargoFeaturesTitle,CursorLine:CargoFeaturesSelection",
    { win = win }
  )

  return float_buf, win
end

---@param bufnr integer
---@param lines string[]
---@param hl? string
local function render_message(bufnr, lines, hl)
  vim.api.nvim_set_option_value("modifiable", true, { buf = bufnr })
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
  if hl then
    for index, line_text in ipairs(lines) do
      vim.api.nvim_buf_set_extmark(bufnr, ns, index - 1, 0, {
        end_col = #line_text,
        hl_eol = true,
        hl_group = hl,
      })
    end
  end
  vim.api.nvim_set_option_value("modifiable", false, { buf = bufnr })
end

---@return boolean
local function use_ascii_icons()
  local ui = config.get().ui
  return ui.ascii_icons or vim.o.encoding ~= "utf-8" or vim.o.ambiwidth == "double"
end

---@param lhs string|string[]
---@return string
local function key_label(lhs)
  local keys = type(lhs) == "table" and lhs or { lhs }
  local labels = {}
  for _, key in ipairs(keys) do
    if key == "<CR>" then
      table.insert(labels, "Enter")
    elseif key == " " then
      table.insert(labels, "Space")
    elseif key == "<Esc>" then
      table.insert(labels, "Esc")
    else
      table.insert(labels, key)
    end
  end
  return table.concat(labels, "/")
end

---@param width? integer
---@return string[]
local function help_lines(width)
  local keymaps = config.get().ui.keymaps
  local entries = {
    { key_label(keymaps.toggle), "Toggle" },
    { key_label(keymaps.toggle_all), "All" },
    { key_label(keymaps.apply), "Apply" },
    { key_label(keymaps.reset), "Reset" },
    { key_label(keymaps.save_profile), "Save profile" },
    { key_label(keymaps.close), "Close" },
  }

  local key_width = 0
  for _, entry in ipairs(entries) do
    key_width = math.max(key_width, #entry[1])
  end

  local lines = {}
  local align = not width or width >= key_width + 3 + 6
  for _, entry in ipairs(entries) do
    if align then
      table.insert(lines, ("%-" .. key_width .. "s  %s"):format(entry[1], entry[2]))
    else
      table.insert(lines, ("%s %s"):format(entry[1], entry[2]))
    end
  end

  return lines
end

---@param feature CargoFeaturesFeature
---@param enabled table<string, boolean>
---@return boolean
local function is_enabled(feature, enabled)
  return enabled["*"] or enabled[feature.apply_name] or enabled[feature.name] or false
end

---@param view CargoFeaturesView
---@param feature CargoFeaturesFeature
---@return boolean
local function is_frozen_default_feature(view, feature)
  return view.default_features_supported
    and view.default_enabled
    and feature.default_included == true
    and view.manifest.context == "standalone"
end

---@param view CargoFeaturesView
---@param feature CargoFeaturesFeature
---@return boolean
local function display_enabled(view, feature)
  return feature.enabled or is_frozen_default_feature(view, feature)
end

---@param manifest CargoFeaturesManifest
---@param bufnr integer
---@return table<string, boolean>, boolean
local function initial_enabled(manifest, bufnr)
  local clients = lsp.get_clients({
    bufnr = bufnr,
    manifest_path = manifest.manifest_path,
  })
  local has_client = #clients > 0
  local enabled = {}
  if has_client then
    enabled = lsp.enabled_features(clients[1])
  else
    enabled.default = true
  end

  local persistence = config.get().persistence
  local profile = nil
  local should_load_profile = persistence.load_on_open == "always"
    or (persistence.load_on_open == "if_no_client" and not has_client)
  if should_load_profile then
    profile = profiles.load_profile(persistence.default_profile, {
      manifest_path = manifest.manifest_path,
      workspace_root = manifest.workspace_root,
      scope = manifest.scope,
    })
  end
  if profile then
    enabled = {}
    for _, name in ipairs(profile.features or {}) do
      enabled[name] = true
    end
    if profile.default_enabled ~= nil then
      enabled.default = profile.default_enabled == true
    end
  end

  local default_enabled = enabled["*"] or enabled.default == true
  return enabled, default_enabled
end

---@param view CargoFeaturesView
local function render(view)
  local opts = config.get()
  local lines = {}
  local line_to_feature = {}
  local ascii = use_ascii_icons()
  local checked = ascii and opts.ui.icons.ascii_checked or opts.ui.icons.checked
  local unchecked = ascii and opts.ui.icons.ascii_unchecked or opts.ui.icons.unchecked
  local default_suffix_lines = {}

  if view.default_features_supported then
    local icon = view.default_enabled and checked or unchecked
    table.insert(lines, ("%s Default features"):format(icon))
    view.default_toggle_line = #lines
    if #view.features > 0 then
      table.insert(lines, "")
    end
  else
    view.default_toggle_line = nil
  end

  for index, feature in ipairs(view.features) do
    local enabled = display_enabled(view, feature)
    local icon = enabled and checked or unchecked
    local line = ("%s %s"):format(icon, feature.name)
    if feature.default_included == true then
      local prefix = line
      line = ("%s (default)"):format(line)
      default_suffix_lines[#lines + 1] = #prefix
    end
    table.insert(lines, line)
    line_to_feature[#lines] = index
  end

  if #view.features == 0 and not view.default_features_supported then
    table.insert(lines, "No [features] entries found")
  end

  table.insert(lines, "")
  local help_start = #lines + 1
  for _, line in ipairs(help_lines(vim.api.nvim_win_get_width(view.win))) do
    table.insert(lines, line)
  end

  vim.api.nvim_set_option_value("modifiable", true, { buf = view.bufnr })
  vim.api.nvim_buf_set_lines(view.bufnr, 0, -1, false, lines)
  vim.api.nvim_buf_clear_namespace(view.bufnr, ns, 0, -1)

  for line, index in pairs(line_to_feature) do
    local feature = view.features[index]
    local hl = display_enabled(view, feature) and "CargoFeaturesEnabled" or "CargoFeaturesDisabled"
    vim.api.nvim_buf_set_extmark(view.bufnr, ns, line - 1, 0, {
      end_col = #lines[line],
      hl_eol = true,
      hl_group = hl,
    })
  end

  for line, suffix_col in pairs(default_suffix_lines) do
    vim.api.nvim_buf_set_extmark(view.bufnr, ns, line - 1, suffix_col, {
      end_col = #lines[line],
      hl_group = "CargoFeaturesHelp",
      priority = 10,
    })
  end

  for line = help_start, #lines do
    vim.api.nvim_buf_set_extmark(view.bufnr, ns, line - 1, 0, {
      end_col = #lines[line],
      hl_eol = true,
      hl_group = "CargoFeaturesHelp",
    })
  end
  if #view.features == 0 and not view.default_features_supported then
    vim.api.nvim_buf_set_extmark(view.bufnr, ns, 0, 0, {
      end_col = #lines[1],
      hl_eol = true,
      hl_group = "CargoFeaturesError",
    })
  end

  vim.api.nvim_set_option_value("modifiable", false, { buf = view.bufnr })
  view.line_to_feature = line_to_feature
end

---@param view CargoFeaturesView
local function close(view)
  if view.win and vim.api.nvim_win_is_valid(view.win) then
    vim.api.nvim_win_close(view.win, true)
  end
  if view.bufnr and vim.api.nvim_buf_is_valid(view.bufnr) then
    vim.api.nvim_buf_delete(view.bufnr, { force = true })
  end
  if current == view then
    current = nil
  end
end

---@param view CargoFeaturesView
local function toggle_current(view)
  local row = vim.api.nvim_win_get_cursor(view.win)[1]
  if row == view.default_toggle_line then
    view.default_enabled = not view.default_enabled
    render(view)
    vim.api.nvim_win_set_cursor(view.win, { row, 0 })
    return
  end

  local index = view.line_to_feature[row]
  if not index then
    return
  end

  local feature = view.features[index]
  if is_frozen_default_feature(view, feature) then
    util.notify("Disable Default features first", vim.log.levels.INFO)
    return
  end

  feature.enabled = not feature.enabled
  render(view)
  vim.api.nvim_win_set_cursor(view.win, { row, 0 })
end

---@param view CargoFeaturesView
local function toggle_all(view)
  local all_enabled = #view.features > 0
  for _, feature in ipairs(view.features) do
    if not is_frozen_default_feature(view, feature) and not feature.enabled then
      all_enabled = false
      break
    end
  end

  local next_enabled = not all_enabled
  for _, feature in ipairs(view.features) do
    if not is_frozen_default_feature(view, feature) then
      feature.enabled = next_enabled
    end
  end
  render(view)
end

---@param view CargoFeaturesView
---@return string[]
---@return boolean all_enabled
---@return boolean has_default
local function selected_features(view)
  local selected = {}
  local all_enabled = #view.features > 0

  for _, feature in ipairs(view.features) do
    if feature.enabled and feature.apply_name ~= "default" then
      table.insert(selected, feature.apply_name)
    end

    if not is_frozen_default_feature(view, feature) and not feature.enabled then
      all_enabled = false
    end
  end

  return selected, all_enabled, view.default_features_supported
end

---@param view CargoFeaturesView
---@param name string?
---@return boolean ok
---@return string? err
local function save_profile(view, name)
  local selected = selected_features(view)
  return profiles.save_profile(name, {
    features = selected,
    default_enabled = view.default_enabled,
    scope = view.manifest.scope,
    manifest_path = view.manifest.manifest_path,
    workspace_root = view.manifest.workspace_root,
    package_name = view.manifest.package_name,
  })
end

---@param view CargoFeaturesView
local function apply(view)
  local selected, all_enabled, has_default = selected_features(view)

  local ok, err = lsp.apply(selected, {
    bufnr = view.source_bufnr,
    manifest_path = view.manifest.manifest_path,
    workspace_root = view.manifest.workspace_root,
    package_name = view.manifest.package_name,
    has_default = has_default,
    default_enabled = view.default_enabled,
    all_enabled = all_enabled,
    scope = view.manifest.scope,
    remember = true,
  })
  if not ok then
    util.notify(err or "Unable to apply Cargo features", vim.log.levels.ERROR)
    return
  end

  local persistence = config.get().persistence
  if persistence.save_on_apply then
    local saved, save_err = save_profile(view, persistence.default_profile)
    if not saved then
      util.notify(save_err or "Unable to save Cargo feature profile", vim.log.levels.WARN)
    end
  end

  util.notify("Applied Cargo features to rust-analyzer")
  close(view)
end

---@param view CargoFeaturesView
local function prompt_save_profile(view)
  vim.ui.input({
    prompt = "Profile name",
    default = config.get().persistence.default_profile,
  }, function(input)
    local name = type(input) == "string" and vim.trim(input) or ""
    if name == "" then
      return
    end

    local ok, err = save_profile(view, name)
    if ok then
      util.notify(("Saved Cargo feature profile: %s"):format(name))
    else
      util.notify(err or "Unable to save Cargo feature profile", vim.log.levels.ERROR)
    end
  end)
end

---@param view CargoFeaturesView
local function reset(view)
  local ok, err = lsp.reset({
    bufnr = view.source_bufnr,
    manifest_path = view.manifest.manifest_path,
    workspace_root = view.manifest.workspace_root,
    package_name = view.manifest.package_name,
    scope = view.manifest.scope,
  })
  if not ok then
    util.notify(err or "Unable to reset Cargo feature overrides", vim.log.levels.ERROR)
    return
  end

  util.notify("Reset Cargo feature overrides for rust-analyzer")
  close(view)
end

---@param bufnr integer
---@param manifest CargoFeaturesManifest
---@return CargoFeaturesView
local function create_view(bufnr, manifest)
  local title = config.get().ui.title
  if manifest.package_name then
    title = ("%s: %s"):format(title, manifest.package_name)
  end

  local float_buf, win = create_window(title)

  local enabled, default_enabled = initial_enabled(manifest, bufnr)
  local features = vim.deepcopy(manifest.features)
  for _, feature in ipairs(features) do
    feature.enabled = is_enabled(feature, enabled)
  end

  return {
    bufnr = float_buf,
    default_enabled = default_enabled,
    default_features_supported = manifest.default_features_supported == true,
    default_toggle_line = nil,
    features = features,
    line_to_feature = {},
    manifest = manifest,
    namespace = ns,
    source_bufnr = bufnr,
    win = win,
  }
end

---@param bufnr integer
---@param manifest_path string
---@return CargoFeaturesView
local function create_loading_view(bufnr, manifest_path)
  local float_buf, win = create_window(config.get().ui.title)
  local view = {
    bufnr = float_buf,
    default_enabled = true,
    features = {},
    line_to_feature = {},
    loading = true,
    manifest = {
      context = "standalone",
      default_features_supported = false,
      features = {},
      manifest_path = util.abspath(manifest_path),
      scope = "package",
      source = "loading",
    },
    namespace = ns,
    source_bufnr = bufnr,
    win = win,
  }

  render_message(float_buf, {
    "Loading Cargo features...",
    "",
    ("%s close"):format(key_label(config.get().ui.keymaps.close)),
  }, "CargoFeaturesHelp")

  return view
end

---@param lhs string|string[]
---@param rhs function
---@param bufnr integer
local function map(lhs, rhs, bufnr)
  local keys = type(lhs) == "table" and lhs or { lhs }
  for _, key in ipairs(keys) do
    vim.keymap.set("n", key, rhs, { buffer = bufnr, nowait = true, silent = true })
  end
end

---@param view CargoFeaturesView
local function attach_keymaps(view)
  local keymaps = config.get().ui.keymaps
  map(keymaps.toggle, function()
    toggle_current(view)
  end, view.bufnr)
  map(keymaps.toggle_all, function()
    toggle_all(view)
  end, view.bufnr)
  map(keymaps.apply, function()
    apply(view)
  end, view.bufnr)
  map(keymaps.reset, function()
    reset(view)
  end, view.bufnr)
  map(keymaps.save_profile, function()
    prompt_save_profile(view)
  end, view.bufnr)
  map(keymaps.close, function()
    close(view)
  end, view.bufnr)
end

---@param opts? { bufnr?: integer }
function M.open(opts)
  opts = opts or {}
  local bufnr = opts.bufnr or vim.api.nvim_get_current_buf()
  local manifest_path = cargo.find_manifest(bufnr)
  if not manifest_path then
    util.notify("No Cargo.toml found above the current buffer", vim.log.levels.ERROR)
    return
  end

  if current then
    close(current)
  end

  local loading = create_loading_view(bufnr, manifest_path)
  current = loading
  map(config.get().ui.keymaps.close, function()
    close(loading)
  end, loading.bufnr)

  cargo.load_manifest_async(manifest_path, function(manifest, err)
    if current ~= loading or not vim.api.nvim_buf_is_valid(loading.bufnr) then
      return
    end

    if not manifest then
      render_message(loading.bufnr, {
        err or "Unable to load Cargo features",
        "",
        ("%s close"):format(key_label(config.get().ui.keymaps.close)),
      }, "CargoFeaturesError")
      return
    end

    close(loading)
    current = create_view(bufnr, manifest)
    render(current)
    attach_keymaps(current)
  end)
end

M._help_lines = help_lines
M._reset = reset
M._save_profile = save_profile

return M
