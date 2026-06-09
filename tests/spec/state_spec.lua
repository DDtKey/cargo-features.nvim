local config = require("cargo-features.config")
local api = require("cargo-features")
local cargo = require("cargo-features.cargo")
local commands = require("cargo-features.commands")
local lsp = require("cargo-features.lsp")
local profiles = require("cargo-features.profile_store")
local util = require("cargo-features.util")

local cwd = vim.uv.cwd()
local manifest = vim.fs.joinpath(cwd, "tests", "fixtures", "simple", "Cargo.toml")
local workspace_root = vim.fs.joinpath(cwd, "tests", "fixtures", "workspace")

describe("profile persistence", function()
  local original_xdg_state_home
  local original_notify
  local original_find_manifest
  local original_load_manifest
  local original_lsp_apply
  local original_ui_select
  local state_home
  local notifications

  before_each(function()
    original_xdg_state_home = vim.env.XDG_STATE_HOME
    original_notify = vim.notify
    original_find_manifest = cargo.find_manifest
    original_load_manifest = cargo.load_manifest
    original_lsp_apply = lsp.apply
    original_ui_select = vim.ui.select
    state_home = vim.fs.joinpath(cwd, ".tmp", "state-spec")
    vim.fn.delete(state_home, "rf")
    vim.fn.mkdir(state_home, "p")
    vim.env.XDG_STATE_HOME = state_home
    notifications = {}
    vim.notify = function(message, level, opts)
      table.insert(notifications, {
        message = message,
        level = level,
        opts = opts,
      })
    end

    config.setup({
      persistence = {
        default_profile = "default",
        save_on_apply = false,
        load_on_open = "never",
      },
    })
    profiles._reset_for_tests()
  end)

  after_each(function()
    profiles._reset_for_tests()
    config.setup()
    cargo.find_manifest = original_find_manifest
    cargo.load_manifest = original_load_manifest
    lsp.apply = original_lsp_apply
    vim.ui.select = original_ui_select
    vim.notify = original_notify
    vim.env.XDG_STATE_HOME = original_xdg_state_home
    vim.fn.delete(state_home, "rf")
    pcall(vim.api.nvim_del_user_command, "CargoFeaturesApplyProfile")
    pcall(vim.api.nvim_del_user_command, "CargoFeatures")
    pcall(vim.api.nvim_del_user_command, "CargoFeaturesDebug")
    pcall(vim.api.nvim_del_user_command, "CargoFeaturesReset")
  end)

  local function profile_store_path()
    return vim.fs.joinpath(vim.fn.stdpath("state"), "cargo-features.nvim", "profiles.json")
  end

  it("stores named profiles in the versioned profile format", function()
    local ok, err = api.save_profile(nil, {
      features = { "serde", "metrics", "serde" },
      default_enabled = true,
      scope = "package",
      manifest_path = manifest,
      workspace_root = workspace_root,
      package_name = "my-crate",
    })

    assert.is_true(ok, err)

    local store = profiles._profiles_for_tests()
    local profile = store.profiles[util.abspath(manifest)].default

    assert.are.equal(1, store.version)
    assert.are.same({ "metrics", "serde" }, profile.features)
    assert.is_true(profile.default_enabled)
    assert.are.equal("package", profile.scope)
    assert.are.equal(util.abspath(manifest), profile.manifest_path)
    assert.are.equal(util.abspath(workspace_root), profile.workspace_root)
    assert.are.equal("my-crate", profile.package_name)
  end)

  it("lists loads and deletes profiles by name", function()
    assert.is_true(api.save_profile("debug", {
      features = { "serde" },
      default_enabled = false,
      scope = "package",
      manifest_path = manifest,
    }))
    assert.is_true(api.save_profile("release", {
      features = { "metrics" },
      default_enabled = true,
      scope = "package",
      manifest_path = manifest,
    }))

    assert.are.same({ "debug", "release" }, api.list_profiles({
      manifest_path = manifest,
      scope = "package",
    }))

    local profile = api.load_profile("debug", {
      manifest_path = manifest,
      scope = "package",
    })

    assert.are.same({ "serde" }, profile.features)
    assert.is_false(profile.default_enabled)

    assert.is_true(api.delete_profile("debug", {
      manifest_path = manifest,
      scope = "package",
    }))
    assert.are.same({ "release" }, api.list_profiles({
      manifest_path = manifest,
      scope = "package",
    }))
  end)

  it("loads a saved profile from disk after resetting memory", function()
    assert.is_true(api.save_profile("debug", {
      features = { "serde" },
      default_enabled = false,
      scope = "package",
      manifest_path = manifest,
      workspace_root = workspace_root,
      package_name = "simple",
    }))

    profiles._reset_for_tests()

    local profile = api.load_profile("debug", {
      manifest_path = manifest,
      scope = "package",
    })
    local store = profiles._profiles_for_tests()

    assert.are.equal(1, store.version)
    assert.are.same({ "serde" }, profile.features)
    assert.is_false(profile.default_enabled)
    assert.are.equal("package", profile.scope)
    assert.are.equal(util.abspath(manifest), profile.manifest_path)
    assert.are.equal(util.abspath(workspace_root), profile.workspace_root)
    assert.are.equal("simple", profile.package_name)
  end)

  it("moves unsupported profile stores aside before saving a fresh v1 store", function()
    local path = profile_store_path()
    vim.fn.mkdir(vim.fs.dirname(path), "p")
    vim.fn.writefile({ vim.json.encode({ version = 99, profiles = {} }) }, path)

    profiles._reset_for_tests()

    local ok, err = api.save_profile("debug", {
      features = { "serde" },
      default_enabled = true,
      scope = "package",
      manifest_path = manifest,
    })

    assert.is_true(ok, err)
    assert.are.equal(1, vim.fn.filereadable(path .. ".bak"))
    assert.are.equal(1, #notifications)
    assert.are.equal(vim.log.levels.WARN, notifications[1].level)
    assert.matches("unsupported version", notifications[1].message)

    profiles._reset_for_tests()
    local profile = api.load_profile("debug", {
      manifest_path = manifest,
      scope = "package",
    })
    assert.are.same({ "serde" }, profile.features)
  end)

  it("moves malformed profile stores aside before saving a fresh v1 store", function()
    local path = profile_store_path()
    vim.fn.mkdir(vim.fs.dirname(path), "p")
    vim.fn.writefile({ "{not-json" }, path)

    profiles._reset_for_tests()

    local ok, err = api.save_profile("debug", {
      features = { "serde" },
      default_enabled = true,
      scope = "package",
      manifest_path = manifest,
    })

    assert.is_true(ok, err)
    assert.are.equal(1, vim.fn.filereadable(path .. ".bak"))
    assert.are.equal(1, #notifications)
    assert.are.equal(vim.log.levels.WARN, notifications[1].level)
    assert.matches("malformed JSON", notifications[1].message)

    profiles._reset_for_tests()
    local profile = api.load_profile("debug", {
      manifest_path = manifest,
      scope = "package",
    })
    assert.are.same({ "serde" }, profile.features)
  end)

  it("uses workspace root as the key for workspace profiles", function()
    assert.is_true(api.save_profile(nil, {
      features = { "a/foo" },
      scope = "workspace",
      manifest_path = vim.fs.joinpath(workspace_root, "Cargo.toml"),
      workspace_root = workspace_root,
    }))

    local store = profiles._profiles_for_tests()

    assert.is_not_nil(store.profiles[util.abspath(workspace_root)].default)
  end)

  it("uses clearer persistence defaults", function()
    config.setup()

    assert.is_false(config.get().persistence.save_on_apply)
    assert.are.equal("never", config.get().persistence.load_on_open)
    assert.is_false(config.get().persistence.apply_on_attach)
  end)

  it("normalizes load_on_open values", function()
    config.setup({
      persistence = {
        load_on_open = true,
      },
    })
    assert.are.equal("always", config.get().persistence.load_on_open)

    config.setup({
      persistence = {
        load_on_open = false,
      },
    })
    assert.are.equal("never", config.get().persistence.load_on_open)

    config.setup({
      persistence = {
        load_on_open = "sometimes",
      },
    })
    assert.are.equal("never", config.get().persistence.load_on_open)
  end)

  it("maps deprecated persistence aliases to the new names", function()
    config.setup({
      persistence = {
        auto_load = true,
        auto_save = true,
      },
    })
    assert.are.equal("always", config.get().persistence.load_on_open)
    assert.is_true(config.get().persistence.save_on_apply)
    assert.is_nil(config.get().persistence.auto_load)
    assert.is_nil(config.get().persistence.auto_save)

    config.setup({
      persistence = {
        auto_load = false,
        auto_save = false,
      },
    })
    assert.are.equal("never", config.get().persistence.load_on_open)
    assert.is_false(config.get().persistence.save_on_apply)
    assert.is_nil(config.get().persistence.auto_load)
    assert.is_nil(config.get().persistence.auto_save)
  end)

  it("apply_profile loads and applies a named profile", function()
    assert.is_true(api.save_profile("debug", {
      features = { "metrics", "serde" },
      default_enabled = false,
      scope = "package",
      manifest_path = manifest,
      workspace_root = workspace_root,
      package_name = "simple",
    }))

    local applied_features
    local applied_opts
    lsp.apply = function(features, opts)
      applied_features = features
      applied_opts = opts
      return true, nil
    end

    local ok, err = api.apply_profile("debug", {
      bufnr = 9,
      manifest_path = manifest,
      scope = "package",
    })

    assert.is_true(ok, err)
    assert.are.same({ "metrics", "serde" }, applied_features)
    assert.are.equal(9, applied_opts.bufnr)
    assert.are.equal(util.abspath(manifest), util.abspath(applied_opts.manifest_path))
    assert.are.equal(util.abspath(workspace_root), util.abspath(applied_opts.workspace_root))
    assert.are.equal("simple", applied_opts.package_name)
    assert.are.equal("package", applied_opts.scope)
    assert.is_false(applied_opts.default_enabled)
    assert.is_true(applied_opts.has_default)
    assert.is_true(applied_opts.remember)
  end)

  it("apply_profile uses the default profile when name is omitted", function()
    assert.is_true(api.save_profile(nil, {
      features = { "serde" },
      default_enabled = true,
      scope = "package",
      manifest_path = manifest,
    }))

    local applied_features
    lsp.apply = function(features)
      applied_features = features
      return true, nil
    end

    local ok, err = api.apply_profile(nil, {
      manifest_path = manifest,
      scope = "package",
    })

    assert.is_true(ok, err)
    assert.are.same({ "serde" }, applied_features)
  end)

  it("apply_profile returns a useful error when the profile is missing", function()
    local ok, err = api.apply_profile("missing", {
      manifest_path = manifest,
      scope = "package",
    })

    assert.is_false(ok)
    assert.are.equal("Profile not found: missing", err)
  end)

  it("apply_profile does not rewrite saved profiles", function()
    assert.is_true(api.save_profile("debug", {
      features = { "serde" },
      default_enabled = true,
      scope = "package",
      manifest_path = manifest,
    }))

    lsp.apply = function()
      return true, nil
    end

    assert.is_true(api.apply_profile("debug", {
      manifest_path = manifest,
      scope = "package",
    }))

    local profile = api.load_profile("debug", {
      manifest_path = manifest,
      scope = "package",
    })
    assert.are.same({ "serde" }, profile.features)
    assert.is_true(profile.default_enabled)
  end)

  it("apply_profile resolves the current buffer context", function()
    cargo.find_manifest = function(bufnr)
      assert.are.equal(12, bufnr)
      return manifest
    end
    cargo.load_manifest = function(path)
      assert.are.equal(manifest, path)
      return {
        manifest_path = manifest,
        workspace_root = workspace_root,
        package_name = "simple",
        scope = "package",
      }
    end

    assert.is_true(api.save_profile("debug", {
      features = { "serde" },
      default_enabled = true,
      scope = "package",
      manifest_path = manifest,
      workspace_root = workspace_root,
      package_name = "simple",
    }))

    local applied_opts
    lsp.apply = function(_, opts)
      applied_opts = opts
      return true, nil
    end

    local ok, err = api.apply_profile("debug", { bufnr = 12 })

    assert.is_true(ok, err)
    assert.are.equal(12, applied_opts.bufnr)
    assert.are.equal("simple", applied_opts.package_name)
    assert.are.equal("package", applied_opts.scope)
  end)

  local function stub_command_context()
    cargo.find_manifest = function()
      return manifest
    end
    cargo.load_manifest = function()
      return {
        manifest_path = manifest,
        workspace_root = workspace_root,
        package_name = "simple",
        scope = "package",
      }
    end
  end

  it("CargoFeaturesApplyProfile applies an explicit package profile name", function()
    stub_command_context()
    assert.is_true(api.save_profile("debug", {
      features = { "serde" },
      scope = "package",
      manifest_path = manifest,
      workspace_root = workspace_root,
    }))

    local called_name
    local called_opts
    local original_apply_profile = api.apply_profile
    api.apply_profile = function(name, opts)
      called_name = name
      called_opts = opts
      return true, nil
    end

    commands.create()
    vim.cmd("CargoFeaturesApplyProfile debug")

    api.apply_profile = original_apply_profile
    assert.are.equal("debug", called_name)
    assert.are.equal("package", called_opts.scope)
    assert.are.equal(manifest, called_opts.manifest_path)
    assert.matches("Applied Cargo feature profile: debug %(package%)", notifications[#notifications].message)
  end)

  it("CargoFeaturesApplyProfile applies a workspace profile when no package profile exists", function()
    stub_command_context()
    assert.is_true(api.save_profile("debug", {
      features = { "a/foo" },
      scope = "workspace",
      manifest_path = vim.fs.joinpath(workspace_root, "Cargo.toml"),
      workspace_root = workspace_root,
    }))

    local called_name
    local called_opts
    local original_apply_profile = api.apply_profile
    api.apply_profile = function(name, opts)
      called_name = name
      called_opts = opts
      return true, nil
    end

    commands.create()
    vim.cmd("CargoFeaturesApplyProfile debug")

    api.apply_profile = original_apply_profile
    assert.are.equal("debug", called_name)
    assert.are.equal("workspace", called_opts.scope)
    assert.are.equal(workspace_root, called_opts.workspace_root)
    assert.matches("Applied Cargo feature profile: debug %(workspace%)", notifications[#notifications].message)
  end)

  it("CargoFeaturesApplyProfile prefers package profile when duplicate names exist", function()
    stub_command_context()
    assert.is_true(api.save_profile("debug", {
      features = { "serde" },
      scope = "package",
      manifest_path = manifest,
      workspace_root = workspace_root,
    }))
    assert.is_true(api.save_profile("debug", {
      features = { "a/foo" },
      scope = "workspace",
      manifest_path = vim.fs.joinpath(workspace_root, "Cargo.toml"),
      workspace_root = workspace_root,
    }))

    local called_opts
    local original_apply_profile = api.apply_profile
    api.apply_profile = function(_, opts)
      called_opts = opts
      return true, nil
    end

    commands.create()
    vim.cmd("CargoFeaturesApplyProfile debug")

    api.apply_profile = original_apply_profile
    assert.are.equal("package", called_opts.scope)
  end)

  it("CargoFeaturesApplyProfile picker lists package and workspace profiles", function()
    stub_command_context()
    assert.is_true(api.save_profile("debug", {
      features = { "serde" },
      default_enabled = true,
      scope = "package",
      manifest_path = manifest,
      workspace_root = workspace_root,
    }))
    assert.is_true(api.save_profile("release", {
      features = { "metrics" },
      default_enabled = false,
      scope = "workspace",
      manifest_path = vim.fs.joinpath(workspace_root, "Cargo.toml"),
      workspace_root = workspace_root,
    }))

    local selected_items
    local formatted_items
    local selected_prompt
    vim.ui.select = function(items, opts, callback)
      selected_items = items
      selected_prompt = opts.prompt
      formatted_items = vim.tbl_map(opts.format_item, items)
      callback(items[2])
    end

    local called_name
    local called_opts
    local original_apply_profile = api.apply_profile
    api.apply_profile = function(name, opts)
      called_name = name
      called_opts = opts
      return true, nil
    end

    commands.create()
    vim.cmd("CargoFeaturesApplyProfile")

    api.apply_profile = original_apply_profile
    assert.are.equal(2, #selected_items)
    assert.are.same({ "debug (package)", "release (workspace)" }, formatted_items)
    assert.are.equal("Cargo feature profile", selected_prompt)
    assert.are.equal("release", called_name)
    assert.are.equal("workspace", called_opts.scope)
    assert.matches("Applied Cargo feature profile: release %(workspace%)", notifications[#notifications].message)
  end)

  it("CargoFeaturesApplyProfile picker can apply a package profile", function()
    stub_command_context()
    assert.is_true(api.save_profile("debug", {
      features = { "serde" },
      scope = "package",
      manifest_path = manifest,
      workspace_root = workspace_root,
    }))
    assert.is_true(api.save_profile("release", {
      features = { "a/foo" },
      scope = "workspace",
      manifest_path = vim.fs.joinpath(workspace_root, "Cargo.toml"),
      workspace_root = workspace_root,
    }))

    vim.ui.select = function(items, _, callback)
      callback(items[1])
    end

    local called_opts
    local original_apply_profile = api.apply_profile
    api.apply_profile = function(_, opts)
      called_opts = opts
      return true, nil
    end

    commands.create()
    vim.cmd("CargoFeaturesApplyProfile")

    api.apply_profile = original_apply_profile
    assert.are.equal("package", called_opts.scope)
  end)

  it("CargoFeaturesApplyProfile picker cancel is a no-op", function()
    stub_command_context()
    assert.is_true(api.save_profile("debug", {
      features = { "serde" },
      scope = "package",
      manifest_path = manifest,
      workspace_root = workspace_root,
    }))

    vim.ui.select = function(_, _, callback)
      callback(nil)
    end

    local called = false
    local original_apply_profile = api.apply_profile
    api.apply_profile = function()
      called = true
      return true, nil
    end

    commands.create()
    vim.cmd("CargoFeaturesApplyProfile")

    api.apply_profile = original_apply_profile
    assert.is_false(called)
    assert.are.equal(0, #notifications)
  end)

  it("CargoFeaturesApplyProfile reports when no profiles exist for the context", function()
    stub_command_context()

    local select_called = false
    vim.ui.select = function()
      select_called = true
    end

    commands.create()
    vim.cmd("CargoFeaturesApplyProfile")

    assert.is_false(select_called)
    assert.are.equal(vim.log.levels.INFO, notifications[#notifications].level)
    assert.matches("No Cargo feature profiles saved", notifications[#notifications].message)
  end)

  it("CargoFeaturesApplyProfile reports apply failures", function()
    stub_command_context()
    assert.is_true(api.save_profile("debug", {
      features = { "serde" },
      scope = "package",
      manifest_path = manifest,
      workspace_root = workspace_root,
    }))

    local original_apply_profile = api.apply_profile
    api.apply_profile = function()
      return false, "Profile not found: debug"
    end

    commands.create()
    vim.cmd("CargoFeaturesApplyProfile debug")

    api.apply_profile = original_apply_profile
    assert.are.equal(vim.log.levels.ERROR, notifications[#notifications].level)
    assert.matches("Profile not found: debug", notifications[#notifications].message)
  end)
end)
