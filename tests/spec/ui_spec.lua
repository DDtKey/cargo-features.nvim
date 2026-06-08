local cargo = require("cargo-features.cargo")
local config = require("cargo-features.config")
local lsp = require("cargo-features.lsp")
local profiles = require("cargo-features.profile_store")
local ui = require("cargo-features.ui")

local simple_manifest = vim.fs.joinpath(vim.uv.cwd(), "tests", "fixtures", "simple", "Cargo.toml")

describe("floating window UI", function()
  local original_find_manifest
  local original_load_manifest_async
  local original_lsp_get_clients
  local original_lsp_enabled_features
  local original_columns
  local original_lines
  local original_xdg_state_home
  local state_home

  before_each(function()
    original_find_manifest = cargo.find_manifest
    original_load_manifest_async = cargo.load_manifest_async
    original_lsp_get_clients = lsp.get_clients
    original_lsp_enabled_features = lsp.enabled_features
    original_columns = vim.o.columns
    original_lines = vim.o.lines
    original_xdg_state_home = vim.env.XDG_STATE_HOME
    state_home = vim.fs.joinpath(vim.uv.cwd(), ".tmp", "ui-state-spec")
    vim.fn.delete(state_home, "rf")
    vim.fn.mkdir(state_home, "p")
    vim.env.XDG_STATE_HOME = state_home
    profiles._reset_for_tests()
  end)

  after_each(function()
    cargo.find_manifest = original_find_manifest
    cargo.load_manifest_async = original_load_manifest_async
    lsp.get_clients = original_lsp_get_clients
    lsp.enabled_features = original_lsp_enabled_features
    profiles._reset_for_tests()
    config.setup()
    vim.env.XDG_STATE_HOME = original_xdg_state_home
    vim.fn.delete(state_home, "rf")
    vim.o.columns = original_columns
    vim.o.lines = original_lines
    pcall(vim.cmd, "silent! %bwipeout!")
  end)

  local function stub_manifest(features)
    cargo.find_manifest = function()
      return simple_manifest
    end

    cargo.load_manifest_async = function(manifest_path, callback)
      callback({
        features = features or {
          {
            name = "serde",
            apply_name = "serde",
            is_default = false,
          },
          {
            name = "metrics",
            apply_name = "metrics",
            is_default = false,
          },
        },
        manifest_path = vim.fs.normalize(manifest_path),
        package_name = "simple",
        scope = "package",
        source = "test",
      }, nil)
    end
  end

  local function save_default_profile()
    assert.is_true(require("cargo-features").save_profile(nil, {
      features = { "metrics" },
      default_enabled = true,
      scope = "package",
      manifest_path = simple_manifest,
    }))
  end

  it("keeps the floating window inside tiny editor bounds", function()
    cargo.find_manifest = function()
      return "tests/fixtures/simple/Cargo.toml"
    end

    cargo.load_manifest_async = function(manifest_path, callback)
      callback({
        features = {},
        manifest_path = vim.fs.normalize(manifest_path),
        package_name = "simple",
        scope = "package",
        source = "test",
      }, nil)
    end

    vim.o.columns = 12
    vim.o.lines = 6

    require("cargo-features").setup({
      ui = {
        width = 60,
        height = 18,
      },
    })

    require("cargo-features").open()

    local cfg = vim.api.nvim_win_get_config(vim.api.nvim_get_current_win())

    assert.is_true(cfg.width <= vim.o.columns - 2)
    assert.is_true(cfg.height <= vim.o.lines - 3)
    assert.is_true(cfg.col >= 0)
    assert.is_true(cfg.row >= 0)
  end)

  it("renders default keymaps as separate help rows", function()
    config.setup()

    assert.are.same({
      "Enter/Space  Toggle",
      "A            All",
      "W            Apply",
      "q/Esc        Close",
    }, ui._help_lines(60))
  end)

  it("reflects custom keymaps in help rows", function()
    config.setup({
      ui = {
        keymaps = {
          toggle = "t",
          toggle_all = "!",
          apply = "a",
          close = "x",
        },
      },
    })

    assert.are.same({
      "t  Toggle",
      "!  All",
      "a  Apply",
      "x  Close",
    }, ui._help_lines(60))
  end)

  it("uses compact help rows in narrow floats", function()
    config.setup()

    assert.are.same({
      "Enter/Space Toggle",
      "A All",
      "W Apply",
      "q/Esc Close",
    }, ui._help_lines(12))
  end)

  it("does not make help rows toggleable feature rows", function()
    cargo.find_manifest = function()
      return "tests/fixtures/simple/Cargo.toml"
    end

    cargo.load_manifest_async = function(manifest_path, callback)
      callback({
        features = {
          {
            name = "serde",
            apply_name = "serde",
            is_default = false,
          },
        },
        manifest_path = vim.fs.normalize(manifest_path),
        package_name = "simple",
        scope = "package",
        source = "test",
      }, nil)
    end

    require("cargo-features").setup()
    require("cargo-features").open()

    local lines = vim.api.nvim_buf_get_lines(vim.api.nvim_get_current_buf(), 0, -1, false)
    assert.are.equal("☐ serde", lines[1])
    assert.are.equal("", lines[2])
    assert.are.equal("Enter/Space  Toggle", lines[3])

    vim.api.nvim_win_set_cursor(vim.api.nvim_get_current_win(), { 3, 0 })
    vim.api.nvim_feedkeys(" ", "x", false)

    local after = vim.api.nvim_buf_get_lines(vim.api.nvim_get_current_buf(), 0, -1, false)
    assert.are.equal("☐ serde", after[1])
  end)

  it("keeps live rust-analyzer state on open by default even when a profile exists", function()
    stub_manifest()

    require("cargo-features").setup({
      persistence = {
        enabled = true,
      },
    })
    save_default_profile()

    lsp.get_clients = function()
      return { {} }
    end
    lsp.enabled_features = function()
      return { serde = true }
    end

    require("cargo-features").open()

    local lines = vim.api.nvim_buf_get_lines(vim.api.nvim_get_current_buf(), 0, 2, false)
    assert.are.equal("☑ serde", lines[1])
    assert.are.equal("☐ metrics", lines[2])
  end)

  it("loads the default profile with auto_load if_no_client only when no client matches", function()
    stub_manifest()
    require("cargo-features").setup({
      persistence = {
        enabled = true,
        auto_load = "if_no_client",
      },
    })
    save_default_profile()

    require("cargo-features").open()

    local lines = vim.api.nvim_buf_get_lines(vim.api.nvim_get_current_buf(), 0, 2, false)
    assert.are.equal("☐ serde", lines[1])
    assert.are.equal("☑ metrics", lines[2])
  end)

  it("does not load the default profile with auto_load if_no_client when a client matches", function()
    stub_manifest()

    require("cargo-features").setup({
      persistence = {
        enabled = true,
        auto_load = "if_no_client",
      },
    })
    save_default_profile()

    lsp.get_clients = function()
      return { {} }
    end
    lsp.enabled_features = function()
      return { serde = true }
    end

    require("cargo-features").open()

    local lines = vim.api.nvim_buf_get_lines(vim.api.nvim_get_current_buf(), 0, 2, false)
    assert.are.equal("☑ serde", lines[1])
    assert.are.equal("☐ metrics", lines[2])
  end)

  it("loads the default profile with auto_load always even when rust-analyzer has state", function()
    stub_manifest()

    require("cargo-features").setup({
      persistence = {
        enabled = true,
        auto_load = "always",
      },
    })
    save_default_profile()

    lsp.get_clients = function()
      return { {} }
    end
    lsp.enabled_features = function()
      return { serde = true }
    end

    require("cargo-features").open()

    local lines = vim.api.nvim_buf_get_lines(vim.api.nvim_get_current_buf(), 0, 2, false)
    assert.are.equal("☐ serde", lines[1])
    assert.are.equal("☑ metrics", lines[2])
  end)
end)
