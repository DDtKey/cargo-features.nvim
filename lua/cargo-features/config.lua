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
---@field reapply boolean Reapply remembered session-local settings to new rust-analyzer clients when safe.

---@class CargoFeaturesPersistenceConfig
---@field default_profile string Profile used for automatic save/load and the UI save prompt default.
---@field save_on_apply boolean Save the default profile when applying from the UI.
---@field load_on_open "never"|"if_no_client"|"always"|boolean Load the default profile when opening the UI.
---@field apply_on_attach boolean Apply the default profile to rust-analyzer clients on attach when safe.

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
    reapply = true,
  },
  persistence = {
    default_profile = "default",
    save_on_apply = false,
    load_on_open = "never",
    apply_on_attach = false,
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
      save_profile = "S",
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

  M.options.lsp = {
    reapply = M.options.lsp.reapply ~= false,
  }

  local persistence_opts = type(opts) == "table"
      and type(opts.persistence) == "table"
      and opts.persistence
    or {}
  if persistence_opts.auto_save ~= nil and persistence_opts.save_on_apply == nil then
    M.options.persistence.save_on_apply = persistence_opts.auto_save == true
  end
  if persistence_opts.auto_load ~= nil and persistence_opts.load_on_open == nil then
    M.options.persistence.load_on_open = persistence_opts.auto_load
  end
  M.options.persistence.auto_save = nil
  M.options.persistence.auto_load = nil

  if type(M.options.persistence.save_on_apply) ~= "boolean" then
    M.options.persistence.save_on_apply = false
  end
  if type(M.options.persistence.apply_on_attach) ~= "boolean" then
    M.options.persistence.apply_on_attach = false
  end

  local load_on_open = M.options.persistence.load_on_open
  if load_on_open == true then
    M.options.persistence.load_on_open = "always"
  elseif
    load_on_open == false
    or (load_on_open ~= "never" and load_on_open ~= "if_no_client" and load_on_open ~= "always")
  then
    M.options.persistence.load_on_open = "never"
  end

  return M.options
end

---@return CargoFeaturesConfig
function M.get()
  return M.options
end

return M
