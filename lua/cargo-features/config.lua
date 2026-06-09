local M = {}

---@class CargoFeaturesConfig
---@field cargo CargoFeaturesCargoConfig
---@field highlights table<string,string>
---@field lsp CargoFeaturesLspConfig
---@field persistence CargoFeaturesPersistenceConfig
---@field ui CargoFeaturesUiConfig

---@class CargoFeaturesCargoConfig
---@field use_metadata boolean Prefer `cargo metadata` over the fallback TOML scanner.
---@field metadata_timeout integer Timeout in milliseconds for `cargo metadata`.
---@field metadata_extra_args string[] Extra args appended to `cargo metadata`.
---@field metadata_env table<string,string> Extra environment for `cargo metadata`.
---@field metadata_cwd string? Working directory for `cargo metadata`.

---@class CargoFeaturesLspConfig
---@field notify boolean Send workspace/didChangeConfiguration after updating client settings.
---@field reapply_policy "never"|"if_empty"|"always" Control automatic restart/LspAttach recovery.
---@field refresh_after_apply boolean Request semantic-token refresh for loaded Rust buffers attached to updated clients.
---@field sync_check_features "never"|"if_set"|"always" Keep rust-analyzer.check.* aligned.
---@field use_all_features_token boolean Use cargo.features = "all" only for explicitly workspace-scoped apply calls.

---@class CargoFeaturesPersistenceConfig
---@field enabled boolean Persist named profiles under stdpath("state").
---@field default_profile string Profile name used by the UI until profile UX exists.
---@field auto_save boolean Save the default profile when applying from the UI.
---@field auto_load "never"|"if_no_client"|"always"|boolean Load the default profile when opening the UI.

---@class CargoFeaturesUiConfig
---@field ascii_icons boolean Force ASCII checkbox icons.
---@field border string|string[]
---@field height integer|fun(): integer
---@field icons table<string,string>
---@field keymaps table<string,string|string[]>
---@field title string
---@field width integer|fun(): integer

M.defaults = {
  cargo = {
    use_metadata = true,
    metadata_timeout = 3000,
    metadata_extra_args = {},
    metadata_env = {},
    metadata_cwd = nil,
  },
  highlights = {
    CargoFeaturesTitle = "Title",
    CargoFeaturesEnabled = "DiagnosticOk",
    CargoFeaturesDisabled = "Comment",
    CargoFeaturesSelection = "CursorLine",
    CargoFeaturesBorder = "FloatBorder",
    CargoFeaturesHelp = "Comment",
    CargoFeaturesError = "DiagnosticError",
  },
  lsp = {
    notify = true,
    reapply_policy = "if_empty",
    refresh_after_apply = true,
    sync_check_features = "if_set",
    use_all_features_token = false,
  },
  persistence = {
    enabled = false,
    default_profile = "default",
    auto_save = false,
    auto_load = "never",
  },
  ui = {
    ascii_icons = false,
    border = "rounded",
    height = 18,
    icons = {
      checked = "☑",
      unchecked = "☐",
      ascii_checked = "[x]",
      ascii_unchecked = "[ ]",
    },
    keymaps = {
      toggle = { "<CR>", " " },
      toggle_all = "A",
      apply = "W",
      reset = "R",
      close = { "q", "<Esc>" },
    },
    title = "Cargo Features",
    width = 60,
  },
}

---@type CargoFeaturesConfig
M.options = vim.deepcopy(M.defaults)

---@param opts? CargoFeaturesConfig
---@return CargoFeaturesConfig
function M.setup(opts)
  M.options = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts or {})

  local reapply_policy = M.options.lsp.reapply_policy
  if reapply_policy ~= "never" and reapply_policy ~= "if_empty" and reapply_policy ~= "always" then
    M.options.lsp.reapply_policy = "if_empty"
  end

  if type(M.options.lsp.refresh_after_apply) ~= "boolean" then
    M.options.lsp.refresh_after_apply = true
  end

  local auto_load = M.options.persistence.auto_load
  if auto_load == true then
    M.options.persistence.auto_load = "always"
  elseif auto_load == false or (auto_load ~= "never" and auto_load ~= "if_no_client" and auto_load ~= "always") then
    M.options.persistence.auto_load = "never"
  end

  return M.options
end

---@return CargoFeaturesConfig
function M.get()
  return M.options
end

return M
