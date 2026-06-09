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
  local original_lsp_apply
  local original_lsp_reset
  local original_notify
  local original_ui_input
  local original_columns
  local original_lines
  local original_xdg_state_home
  local state_home

  before_each(function()
    original_find_manifest = cargo.find_manifest
    original_load_manifest_async = cargo.load_manifest_async
    original_lsp_get_clients = lsp.get_clients
    original_lsp_enabled_features = lsp.enabled_features
    original_lsp_apply = lsp.apply
    original_lsp_reset = lsp.reset
    original_notify = vim.notify
    original_ui_input = vim.ui.input
    original_columns = vim.o.columns
    original_lines = vim.o.lines
    original_xdg_state_home = vim.env.XDG_STATE_HOME
    state_home = vim.fs.joinpath(vim.uv.cwd(), ".tmp", "ui-state-spec")
    vim.fn.delete(state_home, "rf")
    vim.fn.mkdir(state_home, "p")
    vim.env.XDG_STATE_HOME = state_home
    profiles._reset_for_tests()
    vim.notify = function() end
  end)

  after_each(function()
    cargo.find_manifest = original_find_manifest
    cargo.load_manifest_async = original_load_manifest_async
    lsp.get_clients = original_lsp_get_clients
    lsp.enabled_features = original_lsp_enabled_features
    lsp.apply = original_lsp_apply
    lsp.reset = original_lsp_reset
    vim.notify = original_notify
    vim.ui.input = original_ui_input
    profiles._reset_for_tests()
    config.setup()
    vim.env.XDG_STATE_HOME = original_xdg_state_home
    vim.fn.delete(state_home, "rf")
    vim.o.columns = original_columns
    vim.o.lines = original_lines
    pcall(vim.cmd, "silent! %bwipeout!")
  end)

  local function stub_manifest(features, manifest_opts)
    manifest_opts = manifest_opts or {}
    cargo.find_manifest = function()
      return simple_manifest
    end

    cargo.load_manifest_async = function(manifest_path, callback)
      callback({
        features = features or {
          {
            name = "serde",
            apply_name = "serde",
            default_included = manifest_opts.serde_default == true,
          },
          {
            name = "metrics",
            apply_name = "metrics",
          },
        },
        context = manifest_opts.context or "standalone",
        default_features_supported = manifest_opts.default_features_supported == true,
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
      "R            Reset",
      "S            Save profile",
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
          reset = "r",
          save_profile = "s",
          close = "x",
        },
      },
    })

    assert.are.same({
      "t  Toggle",
      "!  All",
      "a  Apply",
      "r  Reset",
      "s  Save profile",
      "x  Close",
    }, ui._help_lines(60))
  end)

  it("uses compact help rows in narrow floats", function()
    config.setup()

    assert.are.same({
      "Enter/Space Toggle",
      "A All",
      "W Apply",
      "R Reset",
      "S Save profile",
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

  it("renders default features as a separate row", function()
    stub_manifest(nil, {
      default_features_supported = true,
      serde_default = true,
    })
    require("cargo-features").setup()

    require("cargo-features").open()

    local lines = vim.api.nvim_buf_get_lines(vim.api.nvim_get_current_buf(), 0, 5, false)
    assert.are.equal("☑ Default features", lines[1])
    assert.are.equal("", lines[2])
    assert.are.equal("☑ serde (default)", lines[3])
    assert.are.equal("☐ metrics", lines[4])
    assert.is_false(vim.tbl_contains(lines, "☐ default"))
    assert.is_false(vim.tbl_contains(lines, "☑ default"))
  end)

  it("does not serialize features included only by Cargo defaults", function()
    stub_manifest(nil, {
      default_features_supported = true,
      serde_default = true,
    })
    require("cargo-features").setup()

    local apply_features
    local apply_opts
    lsp.apply = function(features, opts)
      apply_features = features
      apply_opts = opts
      return true
    end

    require("cargo-features").open()
    vim.api.nvim_feedkeys("W", "x", false)

    assert.are.same({}, apply_features)
    assert.is_true(apply_opts.default_enabled)
  end)

  it("keeps the default marker but unfreezes rows when Default features are disabled", function()
    stub_manifest(nil, {
      default_features_supported = true,
      serde_default = true,
    })
    require("cargo-features").setup()

    require("cargo-features").open()
    vim.api.nvim_win_set_cursor(vim.api.nvim_get_current_win(), { 1, 0 })
    vim.api.nvim_feedkeys(" ", "x", false)

    local lines = vim.api.nvim_buf_get_lines(vim.api.nvim_get_current_buf(), 0, 4, false)
    assert.are.equal("☐ Default features", lines[1])
    assert.are.equal("☐ serde (default)", lines[3])
  end)

  it("does not toggle a default-provided row while Default features are enabled", function()
    stub_manifest(nil, {
      default_features_supported = true,
      serde_default = true,
    })
    require("cargo-features").setup()

    local notifications = {}
    vim.notify = function(message, level)
      table.insert(notifications, { message = message, level = level })
    end
    local apply_features
    lsp.apply = function(features)
      apply_features = features
      return true
    end

    require("cargo-features").open()
    vim.api.nvim_win_set_cursor(vim.api.nvim_get_current_win(), { 3, 0 })
    vim.api.nvim_feedkeys(" ", "x", false)
    vim.api.nvim_feedkeys("W", "x", false)

    assert.are.same({}, apply_features)
    assert.are.equal("Disable Default features first", notifications[1].message)
    assert.are.equal(vim.log.levels.INFO, notifications[1].level)
  end)

  it("lets a default-included feature toggle after Default features are disabled", function()
    stub_manifest(nil, {
      default_features_supported = true,
      serde_default = true,
    })
    require("cargo-features").setup()

    local apply_features
    local apply_opts
    lsp.apply = function(features, opts)
      apply_features = features
      apply_opts = opts
      return true
    end

    require("cargo-features").open()
    vim.api.nvim_win_set_cursor(vim.api.nvim_get_current_win(), { 1, 0 })
    vim.api.nvim_feedkeys(" ", "x", false)
    vim.api.nvim_win_set_cursor(vim.api.nvim_get_current_win(), { 3, 0 })
    vim.api.nvim_feedkeys(" ", "x", false)
    vim.api.nvim_feedkeys("W", "x", false)

    assert.are.same({ "serde" }, apply_features)
    assert.is_false(apply_opts.default_enabled)
  end)

  it("highlights the default suffix with the help highlight group", function()
    stub_manifest(nil, {
      default_features_supported = true,
      serde_default = true,
    })
    require("cargo-features").setup()

    require("cargo-features").open()

    local namespace = vim.api.nvim_create_namespace("cargo-features.nvim")
    local marks = vim.api.nvim_buf_get_extmarks(
      vim.api.nvim_get_current_buf(),
      namespace,
      0,
      -1,
      { details = true }
    )
    local suffix_mark
    for _, mark in ipairs(marks) do
      if mark[2] == 2 and mark[3] == #"☑ serde" then
        suffix_mark = mark
      end
    end

    assert.is_not_nil(suffix_mark)
    assert.are.equal("CargoFeaturesHelp", suffix_mark[4].hl_group)
  end)

  it("toggles Default features separately from named features", function()
    stub_manifest(nil, {
      default_features_supported = true,
      serde_default = true,
    })
    require("cargo-features").setup()

    local apply_features
    local apply_opts
    lsp.apply = function(features, opts)
      apply_features = features
      apply_opts = opts
      return true
    end

    require("cargo-features").open()
    vim.api.nvim_win_set_cursor(vim.api.nvim_get_current_win(), { 1, 0 })
    vim.api.nvim_feedkeys(" ", "x", false)
    vim.api.nvim_feedkeys("W", "x", false)

    assert.are.same({}, apply_features)
    assert.is_true(apply_opts.has_default)
    assert.is_false(apply_opts.default_enabled)
  end)

  it("toggles all named features without changing Default features", function()
    stub_manifest(nil, {
      default_features_supported = true,
      serde_default = true,
    })
    require("cargo-features").setup()

    require("cargo-features").open()
    vim.api.nvim_feedkeys("A", "x", false)

    local lines = vim.api.nvim_buf_get_lines(vim.api.nvim_get_current_buf(), 0, 5, false)
    assert.are.equal("☑ Default features", lines[1])
    assert.are.equal("☑ serde (default)", lines[3])
    assert.are.equal("☑ metrics", lines[4])

    local apply_features
    lsp.apply = function(features)
      apply_features = features
      return true
    end
    vim.api.nvim_feedkeys("W", "x", false)
    assert.are.same({ "metrics" }, apply_features)
  end)

  it(
    "shows local feature names and a global Default features toggle for workspace members",
    function()
      stub_manifest({
        {
          name = "foo",
          apply_name = "a/foo",
          default_included = true,
        },
        {
          name = "bar",
          apply_name = "a/bar",
        },
      }, {
        context = "member",
        default_features_supported = true,
      })
      require("cargo-features").setup()

      require("cargo-features").open()

      local lines = vim.api.nvim_buf_get_lines(vim.api.nvim_get_current_buf(), 0, 5, false)
      assert.are.equal("☑ Default features", lines[1])
      assert.are.equal("☐ foo (default)", lines[3])
      assert.are.equal("☐ bar", lines[4])
    end
  )

  it(
    "lets workspace member default-marked rows toggle while Default features are enabled",
    function()
      stub_manifest({
        {
          name = "foo",
          apply_name = "a/foo",
          default_included = true,
        },
        {
          name = "bar",
          apply_name = "a/bar",
        },
      }, {
        context = "member",
        default_features_supported = true,
      })
      require("cargo-features").setup()

      local apply_features
      local apply_opts
      lsp.apply = function(features, opts)
        apply_features = features
        apply_opts = opts
        return true
      end

      require("cargo-features").open()
      vim.api.nvim_win_set_cursor(vim.api.nvim_get_current_win(), { 3, 0 })
      vim.api.nvim_feedkeys(" ", "x", false)
      vim.api.nvim_feedkeys("W", "x", false)

      assert.are.same({ "a/foo" }, apply_features)
      assert.is_true(apply_opts.default_enabled)
    end
  )

  it("applies workspace member selections with package-qualified feature names", function()
    stub_manifest({
      {
        name = "metrics",
        apply_name = "a/metrics",
      },
    }, {
      context = "member",
      default_features_supported = true,
    })
    require("cargo-features").setup()

    local apply_features
    local apply_opts
    lsp.apply = function(features, opts)
      apply_features = features
      apply_opts = opts
      return true
    end

    require("cargo-features").open()
    vim.api.nvim_win_set_cursor(vim.api.nvim_get_current_win(), { 1, 0 })
    vim.api.nvim_feedkeys(" ", "x", false)
    vim.api.nvim_win_set_cursor(vim.api.nvim_get_current_win(), { 3, 0 })
    vim.api.nvim_feedkeys(" ", "x", false)
    vim.api.nvim_feedkeys("W", "x", false)

    assert.are.same({ "a/metrics" }, apply_features)
    assert.is_true(apply_opts.has_default)
    assert.is_false(apply_opts.default_enabled)
  end)

  it(
    "shows package-qualified labels and informational default markers for workspace roots",
    function()
      stub_manifest({
        {
          name = "a/foo",
          apply_name = "a/foo",
          default_included = true,
        },
        {
          name = "b/bar",
          apply_name = "b/bar",
        },
      }, {
        context = "workspace",
        default_features_supported = true,
      })
      require("cargo-features").setup()

      require("cargo-features").open()

      local lines = vim.api.nvim_buf_get_lines(vim.api.nvim_get_current_buf(), 0, 5, false)
      assert.are.equal("☑ Default features", lines[1])
      assert.are.equal("☐ a/foo (default)", lines[3])
      assert.are.equal("☐ b/bar", lines[4])
    end
  )

  it("save profile key prompts for a profile name", function()
    stub_manifest()
    require("cargo-features").setup()

    local prompt_opts
    vim.ui.input = function(opts, callback)
      prompt_opts = opts
      callback(nil)
    end

    require("cargo-features").open()
    vim.api.nvim_feedkeys("S", "x", false)

    assert.are.equal("Profile name", prompt_opts.prompt)
    assert.are.equal("default", prompt_opts.default)
  end)

  it("does nothing when save profile input is cancelled or blank", function()
    stub_manifest()
    require("cargo-features").setup()

    vim.ui.input = function(_, callback)
      callback("   ")
    end

    require("cargo-features").open()
    vim.api.nvim_feedkeys("S", "x", false)

    local profile = profiles.load_profile("debug", {
      manifest_path = simple_manifest,
      scope = "package",
    })
    assert.is_nil(profile)
  end)

  it("saves current UI selection without applying or closing", function()
    stub_manifest()
    require("cargo-features").setup()

    lsp.get_clients = function()
      return { {} }
    end
    lsp.enabled_features = function()
      return { metrics = true }
    end

    local apply_called = false
    lsp.apply = function()
      apply_called = true
      return true
    end
    vim.ui.input = function(_, callback)
      callback("debug")
    end

    require("cargo-features").open()
    local ui_buf = vim.api.nvim_get_current_buf()
    vim.api.nvim_feedkeys("S", "x", false)

    assert.is_false(apply_called)
    assert.is_true(vim.api.nvim_buf_is_valid(ui_buf))

    local profile = profiles.load_profile("debug", {
      manifest_path = simple_manifest,
      scope = "package",
    })
    assert.are.same({ "metrics" }, profile.features)
    assert.is_false(profile.default_enabled)
  end)

  it("can apply a profile saved from the UI", function()
    stub_manifest()
    require("cargo-features").setup()

    lsp.get_clients = function()
      return { {} }
    end
    lsp.enabled_features = function()
      return { serde = true }
    end
    vim.ui.input = function(_, callback)
      callback("debug")
    end

    require("cargo-features").open()
    vim.api.nvim_feedkeys("S", "x", false)

    local applied_features
    lsp.apply = function(features)
      applied_features = features
      return true
    end

    local ok, err = require("cargo-features").apply_profile("debug", {
      bufnr = 9,
      manifest_path = simple_manifest,
      scope = "package",
    })

    assert.is_true(ok, err)
    assert.are.same({ "serde" }, applied_features)
  end)

  it("reset key calls reset for the current manifest", function()
    stub_manifest()
    require("cargo-features").setup()

    local reset_opts
    lsp.reset = function(opts)
      reset_opts = opts
      return true
    end

    require("cargo-features").open()
    vim.api.nvim_feedkeys("R", "x", false)

    assert.are.equal(simple_manifest, reset_opts.manifest_path)
    assert.are.equal("simple", reset_opts.package_name)
    assert.are.equal("package", reset_opts.scope)
  end)

  it("keeps live rust-analyzer state on open by default even when a profile exists", function()
    stub_manifest()

    require("cargo-features").setup()
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

  it("saves the default profile with save_on_apply after successful UI apply", function()
    stub_manifest()
    require("cargo-features").setup({
      persistence = {
        save_on_apply = true,
      },
    })

    lsp.get_clients = function()
      return { {} }
    end
    lsp.enabled_features = function()
      return { metrics = true }
    end
    lsp.apply = function()
      return true, nil
    end

    require("cargo-features").open()
    vim.api.nvim_feedkeys("W", "x", false)

    local profile = profiles.load_profile(nil, {
      manifest_path = simple_manifest,
      scope = "package",
    })
    assert.are.same({ "metrics" }, profile.features)
    assert.is_false(profile.default_enabled)
  end)

  it(
    "loads the default profile with load_on_open if_no_client only when no client matches",
    function()
      stub_manifest()
      require("cargo-features").setup({
        persistence = {
          load_on_open = "if_no_client",
        },
      })
      save_default_profile()

      require("cargo-features").open()

      local lines = vim.api.nvim_buf_get_lines(vim.api.nvim_get_current_buf(), 0, 2, false)
      assert.are.equal("☐ serde", lines[1])
      assert.are.equal("☑ metrics", lines[2])
    end
  )

  it(
    "does not load the default profile with load_on_open if_no_client when a client matches",
    function()
      stub_manifest()

      require("cargo-features").setup({
        persistence = {
          load_on_open = "if_no_client",
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
    end
  )

  it(
    "loads the default profile with load_on_open always even when rust-analyzer has state",
    function()
      stub_manifest()

      require("cargo-features").setup({
        persistence = {
          load_on_open = "always",
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
    end
  )
end)
