local config = require("cargo-features.config")
local api = require("cargo-features")
local profiles = require("cargo-features.profile_store")
local util = require("cargo-features.util")

local cwd = vim.uv.cwd()
local manifest = vim.fs.joinpath(cwd, "tests", "fixtures", "simple", "Cargo.toml")
local workspace_root = vim.fs.joinpath(cwd, "tests", "fixtures", "workspace")

describe("profile persistence", function()
  local original_xdg_state_home
  local original_notify
  local state_home
  local notifications

  before_each(function()
    original_xdg_state_home = vim.env.XDG_STATE_HOME
    original_notify = vim.notify
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
        enabled = true,
        default_profile = "default",
        auto_save = false,
        auto_load = "never",
      },
    })
    profiles._reset_for_tests()
  end)

  after_each(function()
    profiles._reset_for_tests()
    config.setup()
    vim.notify = original_notify
    vim.env.XDG_STATE_HOME = original_xdg_state_home
    vim.fn.delete(state_home, "rf")
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

  it("does not write profiles when persistence is disabled", function()
    config.setup({
      persistence = {
        enabled = false,
      },
    })
    profiles._reset_for_tests()

    local ok, err = api.save_profile("debug", {
      features = { "serde" },
      scope = "package",
      manifest_path = manifest,
    })

    assert.is_false(ok)
    assert.matches("persistence is disabled", err)
    assert.are.same({}, api.list_profiles({
      manifest_path = manifest,
      scope = "package",
    }))
  end)

  it("normalizes legacy boolean auto_load values", function()
    config.setup({
      persistence = {
        auto_load = true,
      },
    })
    assert.are.equal("always", config.get().persistence.auto_load)

    config.setup({
      persistence = {
        auto_load = false,
      },
    })
    assert.are.equal("never", config.get().persistence.auto_load)

    config.setup({
      persistence = {
        auto_load = "sometimes",
      },
    })
    assert.are.equal("never", config.get().persistence.auto_load)
  end)
end)
