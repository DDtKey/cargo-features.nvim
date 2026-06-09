local config = require("cargo-features.config")
local api = require("cargo-features")
local cargo = require("cargo-features.cargo")
local lsp = require("cargo-features.lsp")
local profiles = require("cargo-features.profile_store")
local ra_settings = require("cargo-features.ra_settings")
local state = require("cargo-features.state")
local util = require("cargo-features.util")

local cwd = vim.uv.cwd()
local simple_root = vim.fs.joinpath(cwd, "tests", "fixtures", "simple")
local workspace_root = vim.fs.joinpath(cwd, "tests", "fixtures", "workspace")
local other_root = vim.fs.joinpath(cwd, "tests", "fixtures", "other")
local manifest = vim.fs.joinpath(simple_root, "Cargo.toml")

local function make_client(root, opts)
  opts = opts or {}
  local client
  client = {
    name = opts.name or "rust-analyzer",
    root_dir = root,
    config = opts.config or {
      cmd = opts.cmd,
      root_dir = root,
      settings = {
        ["rust-analyzer"] = {
          cargo = {},
        },
      },
    },
    settings = opts.settings,
    notify = function(self, method, params)
      assert.are.equal(client, self)
      self.notify_count = (self.notify_count or 0) + 1
      self.notified = { method = method, params = params }
    end,
    stop = function(self)
      self.stopped = true
    end,
  }
  return client
end

describe("rust-analyzer LSP integration", function()
  local original_get_clients
  local original_cmd
  local original_get_buffers_by_client_id
  local original_get_client_by_id
  local original_buf_detach_client
  local original_buf_attach_client
  local original_notify
  local original_defer_fn
  local original_xdg_state_home
  local original_find_manifest
  local original_load_manifest
  local clients
  local notifications
  local restart_called
  local state_home

  before_each(function()
    config.setup({
      lsp = {
        reapply = true,
      },
    })
    state.clear_applied()

    original_get_clients = vim.lsp.get_clients
    original_cmd = vim.cmd
    original_get_buffers_by_client_id = vim.lsp.get_buffers_by_client_id
    original_get_client_by_id = vim.lsp.get_client_by_id
    original_buf_detach_client = vim.lsp.buf_detach_client
    original_buf_attach_client = vim.lsp.buf_attach_client
    original_notify = vim.notify
    original_defer_fn = vim.defer_fn
    original_xdg_state_home = vim.env.XDG_STATE_HOME
    original_find_manifest = cargo.find_manifest
    original_load_manifest = cargo.load_manifest
    clients = {}
    notifications = {}
    restart_called = false
    state_home = vim.fs.joinpath(vim.uv.cwd(), ".tmp", "lsp-state-spec")
    vim.fn.delete(state_home, "rf")
    vim.fn.mkdir(state_home, "p")
    vim.env.XDG_STATE_HOME = state_home
    profiles._reset_for_tests()

    vim.lsp.get_clients = function(opts)
      opts = opts or {}
      if opts.bufnr then
        return vim.tbl_filter(function(client)
          return client.attached ~= false
        end, clients)
      end
      return clients
    end

    vim.cmd = setmetatable({}, {
      __call = function(_, command)
        if tostring(command):match("LspRestart") then
          restart_called = true
        end
      end,
      __index = function(_, key)
        if key == "RustAnalyzer" then
          return function()
            restart_called = true
          end
        end
        return original_cmd[key]
      end,
    })

    vim.notify = function(message, level, opts)
      table.insert(notifications, {
        message = message,
        level = level,
        opts = opts,
      })
    end
    vim.defer_fn = function() end
    vim.lsp.get_client_by_id = function(client_id)
      for _, client in ipairs(clients) do
        if client.id == client_id then
          return client
        end
      end
      return nil
    end
  end)

  after_each(function()
    vim.lsp.get_clients = original_get_clients
    vim.cmd = original_cmd
    vim.lsp.get_buffers_by_client_id = original_get_buffers_by_client_id
    vim.lsp.get_client_by_id = original_get_client_by_id
    vim.lsp.buf_detach_client = original_buf_detach_client
    vim.lsp.buf_attach_client = original_buf_attach_client
    vim.notify = original_notify
    vim.defer_fn = original_defer_fn
    vim.env.XDG_STATE_HOME = original_xdg_state_home
    cargo.find_manifest = original_find_manifest
    cargo.load_manifest = original_load_manifest
    vim.fn.delete(state_home, "rf")
    profiles._reset_for_tests()
    state.clear_applied()
    lsp._clear_reapplied_clients()
    ra_settings._clear_owned_overrides()
    pcall(vim.cmd, "silent! %bwipeout!")
  end)

  it("writes settings to client.settings and mirrors client.config.settings", function()
    local client = make_client(simple_root, {
      config = {
        root_dir = simple_root,
      },
      settings = {},
    })
    clients = { client }

    local ok, err = lsp.apply({ "metrics" }, {
      manifest_path = manifest,
      scope = "package",
    })

    assert.is_true(ok, err)
    assert.are.equal(client.settings, client.config.settings)
    assert.are.same({ "metrics" }, client.settings["rust-analyzer"].cargo.features)
  end)

  it("recognizes the canonical rust-analyzer client name", function()
    assert.is_true(lsp.is_rust_analyzer_client(make_client(simple_root, {
      name = "rust-analyzer",
    })))
  end)

  it("recognizes the rust_analyzer compatibility client name", function()
    assert.is_true(lsp.is_rust_analyzer_client(make_client(simple_root, {
      name = "rust_analyzer",
    })))
  end)

  it("recognizes custom clients launched with rust-analyzer", function()
    assert.is_true(lsp.is_rust_analyzer_client(make_client(simple_root, {
      name = "custom-rust",
      config = {
        cmd = { "rust-analyzer" },
        root_dir = simple_root,
        settings = { ["rust-analyzer"] = { cargo = {} } },
      },
    })))
  end)

  it("recognizes custom clients launched with a rust-analyzer path", function()
    assert.is_true(lsp.is_rust_analyzer_client(make_client(simple_root, {
      name = "custom-rust",
      config = {
        cmd = { "/some/path/rust-analyzer" },
        root_dir = simple_root,
        settings = { ["rust-analyzer"] = { cargo = {} } },
      },
    })))
    assert.is_true(lsp.is_rust_analyzer_client(make_client(simple_root, {
      name = "custom-rust",
      config = {
        cmd = { "C:\\tools\\rust-analyzer.exe" },
        root_dir = simple_root,
        settings = { ["rust-analyzer"] = { cargo = {} } },
      },
    })))
  end)

  it("ignores non-rust-analyzer clients", function()
    assert.is_false(lsp.is_rust_analyzer_client(make_client(simple_root, {
      name = "lua_ls",
      config = {
        cmd = { "lua-language-server" },
        root_dir = simple_root,
        settings = {},
      },
    })))
  end)

  it("exposes only session reapply in public LSP config", function()
    config.setup()

    assert.are.same({ reapply = true }, config.get().lsp)
  end)

  it("normalizes invalid or old LSP config to safe session reapply", function()
    config.setup({
      lsp = {
        notify = false,
        reapply_policy = "always",
        refresh_delay_ms = -1,
        sync_check_features = "always",
        use_all_features_token = true,
      },
    })

    assert.are.same({ reapply = true }, config.get().lsp)

    config.setup({
      lsp = {
        reapply = false,
      },
    })

    assert.are.same({ reapply = false }, config.get().lsp)
  end)

  it("does not expose semantic refresh controls as public config", function()
    config.setup()

    assert.is_nil(config.get().lsp.notify)
    assert.is_nil(config.get().lsp.reapply_policy)
    assert.is_nil(config.get().lsp.refresh_after_apply)
    assert.is_nil(config.get().lsp.refresh_delay_ms)
    assert.is_nil(config.get().lsp.sync_check_features)
    assert.is_nil(config.get().lsp.use_all_features_token)
    assert.is_nil(config.get().lsp.restart_semantic_tokens_after_apply)
    assert.is_nil(
      table.concat(vim.fn.readfile("README.md"), "\n"):find("refresh_delay_ms", 1, true)
    )
    assert.is_nil(
      table
        .concat(vim.fn.readfile("README.md"), "\n")
        :find("restart_semantic_tokens_after_apply", 1, true)
    )
    assert.is_nil(
      table
        .concat(vim.fn.readfile("doc/cargo-features.nvim.txt"), "\n")
        :find("refresh_delay_ms", 1, true)
    )
  end)

  it("falls back to client.config.settings when client.settings is absent", function()
    local client = make_client(simple_root)
    clients = { client }

    local ok, err = lsp.apply({ "serde", "tokio" }, {
      manifest_path = manifest,
      has_default = true,
      default_enabled = false,
      all_enabled = true,
      scope = "package",
    })

    assert.is_true(ok, err)
    assert.are.equal(client.settings, client.config.settings)
    assert.are.same({ "serde", "tokio" }, client.settings["rust-analyzer"].cargo.features)
    assert.is_true(client.settings["rust-analyzer"].cargo.noDefaultFeatures)
  end)

  it("applies to a client named rust-analyzer", function()
    local client = make_client(simple_root, { name = "rust-analyzer" })
    clients = { client }

    local ok, err = lsp.apply({ "serde" }, {
      manifest_path = manifest,
      scope = "package",
    })

    assert.is_true(ok, err)
    assert.are.same({ "serde" }, client.settings["rust-analyzer"].cargo.features)
  end)

  it("applies to a client named rust_analyzer", function()
    local client = make_client(simple_root, { name = "rust_analyzer" })
    clients = { client }

    local ok, err = lsp.apply({ "serde" }, {
      manifest_path = manifest,
      scope = "package",
    })

    assert.is_true(ok, err)
    assert.are.same({ "serde" }, client.settings["rust-analyzer"].cargo.features)
  end)

  it("applies to a custom-named client launched with rust-analyzer", function()
    local client = make_client(simple_root, {
      name = "rust-tools",
      config = {
        cmd = { "/some/path/rust-analyzer" },
        root_dir = simple_root,
        settings = { ["rust-analyzer"] = { cargo = {} } },
      },
    })
    clients = { client }

    local ok, err = lsp.apply({ "serde" }, {
      manifest_path = manifest,
      scope = "package",
    })

    assert.is_true(ok, err)
    assert.are.same({ "serde" }, client.settings["rust-analyzer"].cargo.features)
  end)

  it("ignores unrelated clients during apply", function()
    local client = make_client(simple_root, {
      name = "lua_ls",
      config = {
        cmd = { "lua-language-server" },
        root_dir = simple_root,
        settings = {},
      },
    })
    clients = { client }

    local ok, err = lsp.apply({ "serde" }, {
      manifest_path = manifest,
      scope = "package",
    })

    assert.is_false(ok)
    assert.is_nil(client.notified)
    assert.matches("No active rust%-analyzer client found", err)
  end)

  it("does not mutate unrelated rust-analyzer clients", function()
    local attached = make_client(simple_root)
    local unrelated = make_client(other_root)
    clients = { attached, unrelated }

    local ok, err = lsp.apply({ "serde" }, {
      bufnr = 1,
      manifest_path = manifest,
      scope = "package",
    })

    assert.is_true(ok, err)
    assert.are.equal("workspace/didChangeConfiguration", attached.notified.method)
    assert.is_nil(unrelated.notified)
  end)

  it("uses an attached rust-analyzer client even when root coverage is unknown", function()
    local attached = make_client(nil, {
      config = {
        settings = {
          ["rust-analyzer"] = {
            cargo = {},
          },
        },
      },
    })
    clients = { attached }

    local ok, err = lsp.apply({ "serde" }, {
      bufnr = 1,
      manifest_path = manifest,
      scope = "package",
    })

    assert.is_true(ok, err)
    assert.are.same({ "serde" }, attached.settings["rust-analyzer"].cargo.features)
  end)

  it("uses an attached rust-analyzer client when root coverage fails", function()
    local attached = make_client(other_root)
    clients = { attached }

    local ok, err = lsp.apply({ "serde" }, {
      bufnr = 1,
      manifest_path = manifest,
      scope = "package",
    })

    assert.is_true(ok, err)
    assert.are.same({ "serde" }, attached.settings["rust-analyzer"].cargo.features)
  end)

  it("does not use unrelated global clients when no root covers the manifest", function()
    local unrelated = make_client(other_root)
    clients = { unrelated }

    vim.lsp.get_clients = function(opts)
      opts = opts or {}
      if opts.bufnr then
        return {}
      end
      return clients
    end

    local ok, err = lsp.apply({ "serde" }, {
      bufnr = 1,
      manifest_path = manifest,
      scope = "package",
    })

    assert.is_false(ok)
    assert.is_nil(unrelated.notified)
    assert.matches("No matching rust%-analyzer client found", err)
    assert.matches("Cargo.toml", err)
    assert.matches("Known rust%-analyzer client roots", err)
  end)

  it("does not use unrelated clients for manifest_path-only apply", function()
    local unrelated = make_client(other_root)
    clients = { unrelated }

    local ok, err = lsp.apply({ "serde" }, {
      manifest_path = manifest,
      scope = "package",
    })

    assert.is_false(ok)
    assert.is_nil(unrelated.notified)
    assert.matches("Active rust%-analyzer clients: yes", err)
    assert.matches("Attached to buffer %(not provided%): unknown", err)
    assert.matches("Cargo manifest: " .. vim.pesc(manifest), err)
    assert.matches(vim.pesc(other_root), err)
  end)

  it("reports when no rust-analyzer client exists", function()
    clients = {}

    local ok, err = lsp.apply({ "serde" }, {
      manifest_path = manifest,
      scope = "package",
    })

    assert.is_false(ok)
    assert.equals("No active rust-analyzer client found", err)
  end)

  it("reports active clients attachment state manifest and roots when no client matches", function()
    local unrelated = make_client(other_root)
    clients = { unrelated }

    vim.lsp.get_clients = function(opts)
      opts = opts or {}
      if opts.bufnr then
        return {}
      end
      return clients
    end

    local ok, err = lsp.apply({ "serde" }, {
      bufnr = 9,
      manifest_path = manifest,
      scope = "package",
    })

    assert.is_false(ok)
    assert.matches("Active rust%-analyzer clients: yes", err)
    assert.matches("Attached to buffer 9: no", err)
    assert.matches("Cargo manifest: " .. vim.pesc(manifest), err)
    assert.matches("client %?", err)
    assert.matches(vim.pesc(other_root), err)
  end)

  it("does not restart rust-analyzer on normal apply", function()
    clients = { make_client(simple_root) }

    local ok, err = lsp.apply({ "serde" }, {
      manifest_path = manifest,
      scope = "package",
    })

    assert.is_true(ok, err)
    assert.is_false(restart_called)
  end)

  it("does not apply globally without explicit allow_global", function()
    clients = { make_client(simple_root) }

    local ok = lsp.apply({ "serde" }, {})

    assert.is_false(ok)
  end)

  it("allows explicit global apply", function()
    clients = { make_client(simple_root) }

    local ok, err = lsp.apply({ "serde" }, { allow_global = true })

    assert.is_true(ok, err)
  end)

  it("remembers applied selections in runtime state", function()
    clients = { make_client(simple_root) }

    local ok, err = lsp.apply({ "serde" }, {
      manifest_path = manifest,
      package_name = "simple",
      scope = "package",
      remember = true,
    })

    assert.is_true(ok, err)
    local remembered = state.applied()
    assert.are.equal(1, #remembered)
    assert.are.same({ "serde" }, remembered[1].selected)
    assert.are.equal("simple", remembered[1].package_name)
  end)

  it("does not remember public apply calls unless requested", function()
    clients = { make_client(simple_root) }

    local ok, err = lsp.apply({ "serde" }, {
      manifest_path = manifest,
      package_name = "simple",
      scope = "package",
    })

    assert.is_true(ok, err)
    assert.are.equal(0, #state.applied())
  end)

  it("resets plugin-applied cargo feature overrides without applying an empty list", function()
    local client = make_client(simple_root)
    clients = { client }

    assert.is_true(lsp.apply({ "serde" }, {
      manifest_path = manifest,
      has_default = true,
      default_enabled = false,
      package_name = "simple",
      scope = "package",
      remember = true,
    }))

    local ok, err = lsp.reset({
      manifest_path = manifest,
      package_name = "simple",
      scope = "package",
    })

    assert.is_true(ok, err)
    assert.is_nil(client.settings["rust-analyzer"].cargo.features)
    assert.is_nil(client.settings["rust-analyzer"].cargo.noDefaultFeatures)
    assert.are.equal(2, client.notify_count)
    assert.are.equal(0, #state.applied())
  end)

  it("reset restores pre-existing explicit rust-analyzer feature settings", function()
    local client = make_client(simple_root, {
      settings = {
        ["rust-analyzer"] = {
          cargo = {
            features = { "from-config" },
            noDefaultFeatures = false,
          },
        },
      },
    })
    clients = { client }

    assert.is_true(lsp.apply({ "serde" }, {
      manifest_path = manifest,
      has_default = true,
      default_enabled = false,
      scope = "package",
      remember = true,
    }))

    local ok, err = lsp.reset({
      manifest_path = manifest,
      scope = "package",
    })

    assert.is_true(ok, err)
    assert.are.same({ "from-config" }, client.settings["rust-analyzer"].cargo.features)
    assert.is_false(client.settings["rust-analyzer"].cargo.noDefaultFeatures)
  end)

  it("reset refuses to clear settings without plugin ownership unless forced", function()
    local client = make_client(simple_root, {
      settings = {
        ["rust-analyzer"] = {
          cargo = {
            features = { "from-config" },
          },
        },
      },
    })
    clients = { client }

    local ok, err = lsp.reset({
      manifest_path = manifest,
      scope = "package",
    })

    assert.is_false(ok)
    assert.matches("No plugin%-applied", err)
    assert.are.same({ "from-config" }, client.settings["rust-analyzer"].cargo.features)
    assert.is_nil(client.notified)
  end)

  it("forced reset clears matching live cargo overrides", function()
    local client = make_client(simple_root, {
      settings = {
        ["rust-analyzer"] = {
          cargo = {
            features = { "from-config" },
            noDefaultFeatures = true,
            allFeatures = true,
          },
        },
      },
    })
    clients = { client }

    local ok, err = lsp.reset({
      manifest_path = manifest,
      scope = "package",
      force = true,
    })

    assert.is_true(ok, err)
    assert.is_nil(client.settings["rust-analyzer"].cargo.features)
    assert.is_nil(client.settings["rust-analyzer"].cargo.noDefaultFeatures)
    assert.is_nil(client.settings["rust-analyzer"].cargo.allFeatures)
  end)

  it("reset respects manifest client matching", function()
    local matched = make_client(simple_root)
    local unrelated = make_client(other_root, {
      settings = {
        ["rust-analyzer"] = {
          cargo = {
            features = { "keep" },
          },
        },
      },
    })
    clients = { matched, unrelated }

    assert.is_true(lsp.apply({ "serde" }, {
      manifest_path = manifest,
      scope = "package",
      remember = true,
    }))

    local ok, err = lsp.reset({
      manifest_path = manifest,
      scope = "package",
    })

    assert.is_true(ok, err)
    assert.is_nil(matched.settings["rust-analyzer"].cargo.features)
    assert.are.same({ "keep" }, unrelated.settings["rust-analyzer"].cargo.features)
    assert.is_nil(unrelated.notified)
  end)

  it("reset restores check settings previously synced by the plugin", function()
    local client = make_client(simple_root, {
      settings = {
        ["rust-analyzer"] = {
          cargo = {},
          check = {
            features = { "check-config" },
            noDefaultFeatures = false,
          },
        },
      },
    })
    clients = { client }

    assert.is_true(lsp.apply({ "serde" }, {
      manifest_path = manifest,
      has_default = true,
      default_enabled = false,
      scope = "package",
      remember = true,
    }))
    assert.are.same({ "serde" }, client.settings["rust-analyzer"].check.features)
    assert.is_true(client.settings["rust-analyzer"].check.noDefaultFeatures)

    local ok, err = lsp.reset({
      manifest_path = manifest,
      scope = "package",
    })

    assert.is_true(ok, err)
    assert.are.same({ "check-config" }, client.settings["rust-analyzer"].check.features)
    assert.is_false(client.settings["rust-analyzer"].check.noDefaultFeatures)
  end)

  it(
    "does not create check settings when rust-analyzer did not have explicit check features",
    function()
      local client = make_client(simple_root)
      clients = { client }

      assert.is_true(lsp.apply({ "serde" }, {
        manifest_path = manifest,
        has_default = true,
        default_enabled = false,
        scope = "package",
        remember = true,
      }))
      assert.is_nil(client.settings["rust-analyzer"].check)

      local ok, err = lsp.reset({
        manifest_path = manifest,
        scope = "package",
      })

      assert.is_true(ok, err)
      assert.is_nil(client.settings["rust-analyzer"].check)
    end
  )

  it("normal reset restores original check settings", function()
    local client = make_client(simple_root, {
      settings = {
        ["rust-analyzer"] = {
          cargo = {},
          check = {
            features = { "check-config" },
            noDefaultFeatures = false,
          },
        },
      },
    })
    clients = { client }

    assert.is_true(lsp.apply({ "serde" }, {
      manifest_path = manifest,
      has_default = true,
      default_enabled = false,
      scope = "package",
      remember = true,
    }))

    local ok, err = lsp.reset({
      manifest_path = manifest,
      scope = "package",
    })

    assert.is_true(ok, err)
    assert.are.same({ "check-config" }, client.settings["rust-analyzer"].check.features)
    assert.is_false(client.settings["rust-analyzer"].check.noDefaultFeatures)
  end)

  it("forced reset keeps check settings without plugin ownership", function()
    local client = make_client(simple_root, {
      settings = {
        ["rust-analyzer"] = {
          cargo = {
            features = { "from-config" },
          },
          check = {
            features = { "from-config" },
            noDefaultFeatures = true,
          },
        },
      },
    })
    clients = { client }

    local ok, err = lsp.reset({
      manifest_path = manifest,
      scope = "package",
      force = true,
    })

    assert.is_true(ok, err)
    local check = client.settings["rust-analyzer"].check or {}
    assert.are.same({ "from-config" }, check.features)
    assert.is_true(check.noDefaultFeatures)
  end)

  it("reset does not delete disk profiles", function()
    local client = make_client(simple_root)
    clients = { client }
    config.setup()
    assert.is_true(profiles.save_profile("default", {
      manifest_path = manifest,
      scope = "package",
      features = { "serde" },
      default_enabled = true,
    }))
    assert.is_true(lsp.apply({ "serde" }, {
      manifest_path = manifest,
      scope = "package",
      remember = true,
    }))

    local ok, err = lsp.reset({
      manifest_path = manifest,
      scope = "package",
    })

    assert.is_true(ok, err)
    local profile = profiles.load_profile("default", {
      manifest_path = manifest,
      scope = "package",
    })
    assert.are.same({ "serde" }, profile.features)
  end)

  it(
    "apply_profile respects client matching and does not mutate unrelated rust-analyzer clients",
    function()
      local matched = make_client(simple_root)
      local unrelated = make_client(other_root)
      clients = { matched, unrelated }
      config.setup()
      assert.is_true(profiles.save_profile("debug", {
        manifest_path = manifest,
        scope = "package",
        features = { "serde" },
        default_enabled = false,
      }))

      local ok, err = api.apply_profile("debug", {
        manifest_path = manifest,
        scope = "package",
      })

      assert.is_true(ok, err)
      assert.are.same({ "serde" }, matched.settings["rust-analyzer"].cargo.features)
      assert.is_true(matched.settings["rust-analyzer"].cargo.noDefaultFeatures)
      assert.is_nil(unrelated.notified)
    end
  )

  local function capture_reattach()
    local scheduled = {}
    local calls = {}
    vim.defer_fn = function(callback, ms)
      table.insert(scheduled, { callback = callback, ms = ms })
    end
    vim.lsp.buf_detach_client = function(bufnr, client_id)
      table.insert(calls, { "detach", bufnr, client_id })
      return true
    end
    vim.lsp.buf_attach_client = function(bufnr, client_id)
      table.insert(calls, { "attach", bufnr, client_id })
      return true
    end
    vim.cmd = function(command)
      table.insert(calls, { "cmd", command })
    end
    return scheduled, calls
  end

  local function stub_attached_context(path, manifest_data)
    cargo.find_manifest = function()
      return path
    end
    cargo.load_manifest = function(manifest_path)
      assert.are.equal(path, manifest_path)
      return manifest_data
        or {
          manifest_path = path,
          workspace_root = simple_root,
          package_name = "simple",
          scope = "package",
        }
    end
  end

  it("apply schedules reattach for loaded Rust buffers attached to updated clients", function()
    local client = make_client(simple_root)
    client.id = 101
    clients = { client }

    local rust_buf = vim.api.nvim_create_buf(false, true)
    local other_rust_buf = vim.api.nvim_create_buf(false, true)
    local lua_buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_option_value("filetype", "rust", { buf = rust_buf })
    vim.api.nvim_set_option_value("filetype", "rust", { buf = other_rust_buf })
    vim.api.nvim_set_option_value("filetype", "lua", { buf = lua_buf })

    vim.lsp.get_buffers_by_client_id = function(client_id)
      assert.are.equal(101, client_id)
      return { rust_buf, other_rust_buf, lua_buf }
    end

    local scheduled, calls = capture_reattach()

    local ok, err = lsp.apply({ "serde" }, {
      manifest_path = manifest,
      scope = "package",
    })

    assert.is_true(ok, err)
    assert.are.equal(2, #scheduled)
    assert.are.equal(700, scheduled[1].ms)

    scheduled[1].callback()
    scheduled[2].callback()

    assert.are.same({
      { "detach", rust_buf, 101 },
      { "attach", rust_buf, 101 },
      { "cmd", "redraw!" },
      { "detach", other_rust_buf, 101 },
      { "attach", other_rust_buf, 101 },
      { "cmd", "redraw!" },
    }, calls)
  end)

  it("dedupes duplicate reattach buffers for one client", function()
    local client = make_client(simple_root)
    client.id = 101
    clients = { client }

    local rust_buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_option_value("filetype", "rust", { buf = rust_buf })
    vim.lsp.get_buffers_by_client_id = function()
      return { rust_buf, rust_buf }
    end

    local scheduled, calls = capture_reattach()

    assert.is_true(lsp.apply({ "serde" }, {
      manifest_path = manifest,
      scope = "package",
    }))

    assert.are.equal(1, #scheduled)
    scheduled[1].callback()
    assert.are.same({
      { "detach", rust_buf, 101 },
      { "attach", rust_buf, 101 },
      { "cmd", "redraw!" },
    }, calls)
  end)

  it("apply does not reattach unrelated buffers", function()
    local client = make_client(simple_root)
    client.id = 101
    clients = { client }

    local rust_buf = vim.api.nvim_create_buf(false, true)
    local unrelated = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_option_value("filetype", "rust", { buf = rust_buf })
    vim.api.nvim_set_option_value("filetype", "rust", { buf = unrelated })

    vim.lsp.get_buffers_by_client_id = function()
      return { rust_buf }
    end

    local scheduled, calls = capture_reattach()

    assert.is_true(lsp.apply({ "serde" }, {
      manifest_path = manifest,
      scope = "package",
    }))

    assert.are.equal(1, #scheduled)
    scheduled[1].callback()
    assert.are.same({
      { "detach", rust_buf, 101 },
      { "attach", rust_buf, 101 },
      { "cmd", "redraw!" },
    }, calls)
    for _, call in ipairs(calls) do
      assert.are_not.equal(unrelated, call[2])
    end
  end)

  it("apply does not reattach buffers for unrelated clients", function()
    local matched = make_client(simple_root)
    matched.id = 101
    local unrelated = make_client(other_root)
    unrelated.id = 202
    clients = { matched, unrelated }

    local matched_buf = vim.api.nvim_create_buf(false, true)
    local unrelated_buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_option_value("filetype", "rust", { buf = matched_buf })
    vim.api.nvim_set_option_value("filetype", "rust", { buf = unrelated_buf })

    vim.lsp.get_buffers_by_client_id = function(client_id)
      if client_id == 101 then
        return { matched_buf }
      end
      return { unrelated_buf }
    end

    local scheduled, calls = capture_reattach()

    assert.is_true(lsp.apply({ "serde" }, {
      manifest_path = manifest,
      scope = "package",
    }))

    assert.are.equal(1, #scheduled)
    scheduled[1].callback()
    assert.are.same({
      { "detach", matched_buf, 101 },
      { "attach", matched_buf, 101 },
      { "cmd", "redraw!" },
    }, calls)
  end)

  it("apply failure does not reattach buffers", function()
    clients = {}
    local scheduled = false
    vim.defer_fn = function()
      scheduled = true
    end

    local ok = lsp.apply({ "serde" }, {
      manifest_path = manifest,
      scope = "package",
    })

    assert.is_false(ok)
    assert.is_false(scheduled)
  end)

  it("treats missing reattach APIs as a safe no-op", function()
    local client = make_client(simple_root)
    client.id = 101
    clients = { client }
    local rust_buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_option_value("filetype", "rust", { buf = rust_buf })
    vim.lsp.get_buffers_by_client_id = function()
      return { rust_buf }
    end

    vim.lsp.buf_detach_client = nil
    local scheduled = false
    vim.defer_fn = function()
      scheduled = true
    end

    local ok, err = lsp.apply({ "serde" }, {
      manifest_path = manifest,
      scope = "package",
    })

    assert.is_true(ok, err)
    assert.is_false(scheduled)
    assert.are.same({ "serde" }, client.settings["rust-analyzer"].cargo.features)
  end)

  it("reset success reattaches affected Rust buffers", function()
    local client = make_client(simple_root)
    client.id = 101
    clients = { client }

    local rust_buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_option_value("filetype", "rust", { buf = rust_buf })
    vim.lsp.get_buffers_by_client_id = function()
      return { rust_buf }
    end
    local scheduled, calls = capture_reattach()

    assert.is_true(lsp.apply({ "serde" }, {
      manifest_path = manifest,
      scope = "package",
      remember = true,
    }))
    scheduled, calls = capture_reattach()

    local ok, err = lsp.reset({
      manifest_path = manifest,
      scope = "package",
    })

    assert.is_true(ok, err)
    assert.are.equal(1, #scheduled)
    scheduled[1].callback()
    assert.are.same({
      { "detach", rust_buf, 101 },
      { "attach", rust_buf, 101 },
      { "cmd", "redraw!" },
    }, calls)
  end)

  it("reapply_for_client schedules reattach after applying remembered session state", function()
    state.remember_applied({
      selected = { "serde" },
      manifest_path = manifest,
      scope = "package",
    })

    local client = make_client(simple_root)
    client.id = 101
    clients = { client }

    local rust_buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_option_value("filetype", "rust", { buf = rust_buf })
    vim.lsp.get_buffers_by_client_id = function()
      return { rust_buf }
    end
    local scheduled, calls = capture_reattach()

    lsp.reapply_for_client(client)

    assert.are.same({ "serde" }, client.settings["rust-analyzer"].cargo.features)
    assert.are.equal(1, #scheduled)
    scheduled[1].callback()
    assert.are.same({
      { "detach", rust_buf, 101 },
      { "attach", rust_buf, 101 },
      { "cmd", "redraw!" },
    }, calls)
  end)

  it("reapply_for_client does not reattach when current config already matches", function()
    state.remember_applied({
      selected = { "serde" },
      manifest_path = manifest,
      scope = "package",
      has_default = true,
      default_enabled = true,
    })

    local client = make_client(simple_root, {
      settings = {
        ["rust-analyzer"] = {
          cargo = {
            features = { "serde" },
            noDefaultFeatures = false,
          },
        },
      },
    })
    client.id = 101
    clients = { client }
    local scheduled = capture_reattach()

    lsp.reapply_for_client(client)

    assert.is_nil(client.notified)
    assert.are.equal(0, #scheduled)
  end)

  it("reapply_for_client does not reattach when explicit feature config causes skip", function()
    state.remember_applied({
      selected = { "serde" },
      manifest_path = manifest,
      scope = "package",
    })

    local client = make_client(simple_root, {
      settings = {
        ["rust-analyzer"] = {
          cargo = {
            features = { "metrics" },
          },
        },
      },
    })
    client.id = 101
    clients = { client }
    local scheduled = capture_reattach()

    lsp.reapply_for_client(client)

    assert.is_nil(client.notified)
    assert.are.same({ "metrics" }, client.settings["rust-analyzer"].cargo.features)
    assert.are.equal(0, #scheduled)
  end)

  it("reapplies remembered selections to a new rust-analyzer client", function()
    clients = { make_client(simple_root) }
    assert.is_true(lsp.apply({ "serde" }, {
      manifest_path = manifest,
      package_name = "simple",
      scope = "package",
      remember = true,
    }))

    local new_client = make_client(simple_root)
    lsp.reapply_for_client(new_client)

    assert.are.same({ "serde" }, new_client.settings["rust-analyzer"].cargo.features)
    assert.are.equal("workspace/didChangeConfiguration", new_client.notified.method)
  end)

  it("does not reapply remembered selections to non-rust-analyzer clients", function()
    clients = { make_client(simple_root) }
    assert.is_true(lsp.apply({ "serde" }, {
      manifest_path = manifest,
      scope = "package",
      remember = true,
    }))

    local new_client = make_client(simple_root, { name = "lua_ls" })
    lsp.reapply_for_client(new_client)

    assert.is_nil(new_client.notified)
  end)

  it("does not reapply remembered selections when reapply is false", function()
    config.setup({
      lsp = {
        reapply = false,
      },
    })
    state.remember_applied({
      selected = { "serde" },
      manifest_path = manifest,
      scope = "package",
    })

    local client = make_client(simple_root)
    lsp.reapply_for_client(client)

    assert.is_nil(client.notified)
  end)

  it("does not apply the default profile on attach by default", function()
    config.setup()
    stub_attached_context(manifest)
    assert.is_true(profiles.save_profile(nil, {
      manifest_path = manifest,
      workspace_root = simple_root,
      package_name = "simple",
      scope = "package",
      features = { "serde" },
      default_enabled = true,
    }))

    local client = make_client(simple_root)
    client.id = 101
    clients = { client }
    local scheduled = capture_reattach()

    local applied = lsp.apply_default_profile_for_client(client, 1)

    assert.is_false(applied)
    assert.is_nil(client.notified)
    assert.are.equal(0, #scheduled)
  end)

  it("applies the default profile on attach when enabled and no explicit config exists", function()
    config.setup({
      persistence = {
        apply_on_attach = true,
      },
    })
    stub_attached_context(manifest)
    assert.is_true(profiles.save_profile(nil, {
      manifest_path = manifest,
      workspace_root = simple_root,
      package_name = "simple",
      scope = "package",
      features = { "serde" },
      default_enabled = false,
    }))

    local client = make_client(simple_root)
    client.id = 101
    clients = { client }

    local rust_buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_option_value("filetype", "rust", { buf = rust_buf })
    vim.lsp.get_buffers_by_client_id = function()
      return { rust_buf }
    end
    local scheduled, calls = capture_reattach()

    local applied = lsp.apply_default_profile_for_client(client, rust_buf)

    assert.is_true(applied)
    assert.are.same({ "serde" }, client.settings["rust-analyzer"].cargo.features)
    assert.is_true(client.settings["rust-analyzer"].cargo.noDefaultFeatures)
    assert.are.equal(1, client.notify_count)
    assert.are.equal(1, #scheduled)
    assert.are.same({ "serde" }, state.applied()[1].selected)

    scheduled[1].callback()
    assert.are.same({
      { "detach", rust_buf, 101 },
      { "attach", rust_buf, 101 },
      { "cmd", "redraw!" },
    }, calls)
  end)

  it("skips default profile apply on attach when explicit rust-analyzer config exists", function()
    config.setup({
      persistence = {
        apply_on_attach = true,
      },
    })
    stub_attached_context(manifest)
    assert.is_true(profiles.save_profile(nil, {
      manifest_path = manifest,
      workspace_root = simple_root,
      package_name = "simple",
      scope = "package",
      features = { "serde" },
    }))

    local client = make_client(simple_root, {
      settings = {
        ["rust-analyzer"] = {
          cargo = {
            features = { "metrics" },
          },
        },
      },
    })
    client.id = 101
    clients = { client }
    local scheduled = capture_reattach()

    local applied = lsp.apply_default_profile_for_client(client, 1)

    assert.is_false(applied)
    assert.is_nil(client.notified)
    assert.are.same({ "metrics" }, client.settings["rust-analyzer"].cargo.features)
    assert.are.equal(0, #scheduled)
  end)

  it("skips default profile apply on attach when explicit check feature config exists", function()
    config.setup({
      persistence = {
        apply_on_attach = true,
      },
    })
    stub_attached_context(manifest)
    assert.is_true(profiles.save_profile(nil, {
      manifest_path = manifest,
      workspace_root = simple_root,
      package_name = "simple",
      scope = "package",
      features = { "serde" },
    }))

    local client = make_client(simple_root, {
      settings = {
        ["rust-analyzer"] = {
          cargo = {},
          check = {
            features = { "metrics" },
          },
        },
      },
    })
    client.id = 101
    clients = { client }
    local scheduled = capture_reattach()

    local applied = lsp.apply_default_profile_for_client(client, 1)

    assert.is_false(applied)
    assert.is_nil(client.notified)
    assert.are.same({ "metrics" }, client.settings["rust-analyzer"].check.features)
    assert.are.equal(0, #scheduled)
  end)

  it("does not apply a named profile automatically on attach", function()
    config.setup({
      persistence = {
        apply_on_attach = true,
      },
    })
    stub_attached_context(manifest)
    assert.is_true(profiles.save_profile("debug", {
      manifest_path = manifest,
      workspace_root = simple_root,
      package_name = "simple",
      scope = "package",
      features = { "serde" },
    }))

    local client = make_client(simple_root)
    client.id = 101
    clients = { client }
    local scheduled = capture_reattach()

    local applied = lsp.apply_default_profile_for_client(client, 1)

    assert.is_false(applied)
    assert.is_nil(client.notified)
    assert.are.equal(0, #scheduled)
  end)

  it("does not apply on attach when the default profile is missing", function()
    config.setup({
      persistence = {
        apply_on_attach = true,
      },
    })
    stub_attached_context(manifest)

    local client = make_client(simple_root)
    client.id = 101
    clients = { client }
    local scheduled = capture_reattach()

    local applied = lsp.apply_default_profile_for_client(client, 1)

    assert.is_false(applied)
    assert.is_nil(client.notified)
    assert.are.equal(0, #scheduled)
  end)

  it("dedupes default profile apply per attached client context", function()
    config.setup({
      persistence = {
        apply_on_attach = true,
      },
    })
    stub_attached_context(manifest)
    assert.is_true(profiles.save_profile(nil, {
      manifest_path = manifest,
      workspace_root = simple_root,
      package_name = "simple",
      scope = "package",
      features = { "serde" },
    }))

    local client = make_client(simple_root)
    client.id = 101
    clients = { client }

    local rust_buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_option_value("filetype", "rust", { buf = rust_buf })
    vim.lsp.get_buffers_by_client_id = function()
      return { rust_buf }
    end
    local scheduled = capture_reattach()

    assert.is_true(lsp.apply_default_profile_for_client(client, rust_buf))
    assert.is_false(lsp.apply_default_profile_for_client(client, rust_buf))

    assert.are.equal(1, client.notify_count)
    assert.are.equal(1, #scheduled)
  end)

  it("uses a workspace default profile on attach when no package default profile exists", function()
    config.setup({
      persistence = {
        apply_on_attach = true,
      },
    })
    local member_manifest = vim.fs.joinpath(workspace_root, "crates", "a", "Cargo.toml")
    stub_attached_context(member_manifest, {
      manifest_path = member_manifest,
      workspace_root = workspace_root,
      package_name = "a",
      scope = "package",
    })
    assert.is_true(profiles.save_profile(nil, {
      manifest_path = vim.fs.joinpath(workspace_root, "Cargo.toml"),
      workspace_root = workspace_root,
      scope = "workspace",
      features = { "a/foo" },
    }))

    local client = make_client(workspace_root)
    client.id = 101
    clients = { client }

    local rust_buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_option_value("filetype", "rust", { buf = rust_buf })
    vim.lsp.get_buffers_by_client_id = function()
      return { rust_buf }
    end
    local scheduled = capture_reattach()

    local applied = lsp.apply_default_profile_for_client(client, rust_buf)

    assert.is_true(applied)
    assert.are.same({ "a/foo" }, client.settings["rust-analyzer"].cargo.features)
    assert.are.equal("workspace", state.applied()[1].scope)
    assert.are.equal(1, #scheduled)
  end)

  it("prefers package default profile over workspace default profile on attach", function()
    config.setup({
      persistence = {
        apply_on_attach = true,
      },
    })
    local member_manifest = vim.fs.joinpath(workspace_root, "crates", "a", "Cargo.toml")
    stub_attached_context(member_manifest, {
      manifest_path = member_manifest,
      workspace_root = workspace_root,
      package_name = "a",
      scope = "package",
    })
    assert.is_true(profiles.save_profile(nil, {
      manifest_path = member_manifest,
      workspace_root = workspace_root,
      package_name = "a",
      scope = "package",
      features = { "a/foo" },
    }))
    assert.is_true(profiles.save_profile(nil, {
      manifest_path = vim.fs.joinpath(workspace_root, "Cargo.toml"),
      workspace_root = workspace_root,
      scope = "workspace",
      features = { "b/bar" },
    }))

    local client = make_client(workspace_root)
    client.id = 101
    clients = { client }
    local rust_buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_option_value("filetype", "rust", { buf = rust_buf })
    vim.lsp.get_buffers_by_client_id = function()
      return { rust_buf }
    end

    local applied = lsp.apply_default_profile_for_client(client, rust_buf)

    assert.is_true(applied)
    assert.are.same({ "a/foo" }, client.settings["rust-analyzer"].cargo.features)
    assert.are.equal("package", state.applied()[1].scope)
  end)

  it(
    "reapplies remembered selections when reapply is enabled and no explicit feature settings exist",
    function()
      state.remember_applied({
        selected = { "serde" },
        manifest_path = manifest,
        scope = "package",
        has_default = true,
        default_enabled = false,
      })

      local client = make_client(simple_root)
      lsp.reapply_for_client(client)

      assert.are.same({ "serde" }, client.settings["rust-analyzer"].cargo.features)
      assert.is_true(client.settings["rust-analyzer"].cargo.noDefaultFeatures)
      assert.are.equal(1, client.notify_count)
    end
  )

  it("skips session reapply and notifies once when explicit cargo.features differs", function()
    state.remember_applied({
      selected = { "serde" },
      manifest_path = manifest,
      scope = "package",
    })

    local client = make_client(simple_root, {
      settings = {
        ["rust-analyzer"] = {
          cargo = {
            features = { "metrics" },
          },
        },
      },
    })
    client.id = 42

    lsp.reapply_for_client(client)
    lsp.reapply_for_client(client)

    assert.is_nil(client.notified)
    assert.are.same({ "metrics" }, client.settings["rust-analyzer"].cargo.features)
    assert.are.equal(1, #notifications)
    assert.are.equal(vim.log.levels.INFO, notifications[1].level)
    assert.matches("explicit Cargo feature settings", notifications[1].message)
  end)

  it(
    "does not overwrite explicit cargo.features when old reapply_policy config is provided",
    function()
      config.setup({
        lsp = {
          reapply_policy = "always",
        },
      })
      state.remember_applied({
        selected = { "serde" },
        manifest_path = manifest,
        scope = "package",
      })

      local client = make_client(simple_root, {
        settings = {
          ["rust-analyzer"] = {
            cargo = {
              features = { "metrics" },
            },
          },
        },
      })

      lsp.reapply_for_client(client)

      assert.is_nil(client.notified)
      assert.are.same({ "metrics" }, client.settings["rust-analyzer"].cargo.features)
      assert.are.equal(1, #notifications)
      assert.are.equal(vim.log.levels.INFO, notifications[1].level)
      assert.matches("explicit Cargo feature settings", notifications[1].message)
    end
  )

  it("skips session reapply without warning when explicit cargo.features is equivalent", function()
    state.remember_applied({
      selected = { "serde", "metrics" },
      manifest_path = manifest,
      scope = "package",
      has_default = true,
      default_enabled = true,
    })

    local client = make_client(simple_root, {
      settings = {
        ["rust-analyzer"] = {
          cargo = {
            features = { "metrics", "serde" },
            noDefaultFeatures = false,
          },
        },
      },
    })

    lsp.reapply_for_client(client)

    assert.is_nil(client.notified)
    assert.are.equal(0, #notifications)
    assert.are.same({ "metrics", "serde" }, client.settings["rust-analyzer"].cargo.features)
    assert.is_false(client.settings["rust-analyzer"].cargo.noDefaultFeatures)
  end)

  it("uses explicit feature lists for workspace apply", function()
    local client = make_client(workspace_root)
    clients = { client }

    local ok, err = lsp.apply({ "a/foo", "a/bar" }, {
      manifest_path = vim.fs.joinpath(workspace_root, "Cargo.toml"),
      scope = "workspace",
      all_enabled = true,
    })

    assert.is_true(ok, err)
    assert.are.same({ "a/bar", "a/foo" }, client.settings["rust-analyzer"].cargo.features)
  end)

  it("merges remembered member selections in one workspace", function()
    local client = make_client(workspace_root)
    clients = { client }

    assert.is_true(lsp.apply({ "a/foo" }, {
      manifest_path = vim.fs.joinpath(workspace_root, "crates", "a", "Cargo.toml"),
      workspace_root = workspace_root,
      package_name = "a",
      scope = "package",
      remember = true,
    }))

    assert.is_true(lsp.apply({ "b/bar" }, {
      manifest_path = vim.fs.joinpath(workspace_root, "crates", "b", "Cargo.toml"),
      workspace_root = workspace_root,
      package_name = "b",
      scope = "package",
      remember = true,
    }))

    assert.are.same({ "a/foo", "b/bar" }, client.settings["rust-analyzer"].cargo.features)
  end)

  it("reapplies remembered selections for one workspace with one merged configuration", function()
    state.remember_applied({
      selected = { "b/bar" },
      manifest_path = vim.fs.joinpath(workspace_root, "crates", "b", "Cargo.toml"),
      workspace_root = workspace_root,
      package_name = "b",
      scope = "package",
    })
    state.remember_applied({
      selected = { "a/foo" },
      manifest_path = vim.fs.joinpath(workspace_root, "crates", "a", "Cargo.toml"),
      workspace_root = workspace_root,
      package_name = "a",
      scope = "package",
    })

    local client = make_client(workspace_root)
    client.id = 42

    lsp.reapply_for_client(client)

    assert.are.same({ "a/foo", "b/bar" }, client.settings["rust-analyzer"].cargo.features)
    assert.are.equal(1, client.notify_count)
  end)

  it("does not reapply remembered selections from multiple workspace groups", function()
    state.remember_applied({
      selected = { "serde" },
      manifest_path = manifest,
      workspace_root = simple_root,
      package_name = "simple",
      scope = "package",
    })
    state.remember_applied({
      selected = { "a/foo" },
      manifest_path = vim.fs.joinpath(workspace_root, "crates", "a", "Cargo.toml"),
      workspace_root = workspace_root,
      package_name = "a",
      scope = "package",
    })

    local client = make_client(vim.fs.joinpath(cwd, "tests", "fixtures"))
    client.id = 42

    lsp.reapply_for_client(client)

    assert.is_nil(client.notified)
    assert.are.equal(1, #notifications)
    assert.matches("multiple Cargo workspaces", notifications[1].message)
  end)

  it("does not reapply more than once for the same client", function()
    state.remember_applied({
      selected = { "a/foo" },
      manifest_path = vim.fs.joinpath(workspace_root, "crates", "a", "Cargo.toml"),
      workspace_root = workspace_root,
      package_name = "a",
      scope = "package",
    })

    local client = make_client(workspace_root)
    client.id = 42

    lsp.reapply_for_client(client)
    lsp.reapply_for_client(client)

    assert.are.equal(1, client.notify_count)
  end)

  it("does not warn more than once for repeated ambiguous reapply on the same client", function()
    state.remember_applied({
      selected = { "serde" },
      manifest_path = manifest,
      workspace_root = simple_root,
      scope = "package",
    })
    state.remember_applied({
      selected = { "a/foo" },
      manifest_path = vim.fs.joinpath(workspace_root, "crates", "a", "Cargo.toml"),
      workspace_root = workspace_root,
      scope = "package",
    })

    local client = make_client(vim.fs.joinpath(cwd, "tests", "fixtures"))
    client.id = 42

    lsp.reapply_for_client(client)
    lsp.reapply_for_client(client)

    assert.is_nil(client.notified)
    assert.are.equal(1, #notifications)
  end)

  it("does not emit all during reapply for member selections", function()
    state.remember_applied({
      selected = { "a/foo" },
      manifest_path = vim.fs.joinpath(workspace_root, "crates", "a", "Cargo.toml"),
      workspace_root = workspace_root,
      package_name = "a",
      scope = "package",
      all_enabled = true,
    })
    state.remember_applied({
      selected = { "b/bar" },
      manifest_path = vim.fs.joinpath(workspace_root, "crates", "b", "Cargo.toml"),
      workspace_root = workspace_root,
      package_name = "b",
      scope = "package",
      all_enabled = true,
    })

    local client = make_client(workspace_root)
    lsp.reapply_for_client(client)

    assert.are.same({ "a/foo", "b/bar" }, client.settings["rust-analyzer"].cargo.features)
  end)

  it("does not collapse mixed remembered workspace and member selections to all", function()
    state.remember_applied({
      selected = { "a/foo", "b/bar" },
      manifest_path = vim.fs.joinpath(workspace_root, "Cargo.toml"),
      workspace_root = workspace_root,
      scope = "workspace",
      all_enabled = true,
    })
    state.remember_applied({
      selected = { "a/foo" },
      manifest_path = vim.fs.joinpath(workspace_root, "crates", "a", "Cargo.toml"),
      workspace_root = workspace_root,
      package_name = "a",
      scope = "package",
    })

    local client = make_client(workspace_root)
    lsp.reapply_for_client(client)

    assert.are.same({ "a/foo", "b/bar" }, client.settings["rust-analyzer"].cargo.features)
  end)

  it("reapplies a workspace all selection as an explicit feature list", function()
    state.remember_applied({
      selected = { "a/foo", "b/bar" },
      manifest_path = vim.fs.joinpath(workspace_root, "Cargo.toml"),
      workspace_root = workspace_root,
      scope = "workspace",
      all_enabled = true,
    })

    local client = make_client(workspace_root)
    lsp.reapply_for_client(client)

    assert.are.same({ "a/foo", "b/bar" }, client.settings["rust-analyzer"].cargo.features)
  end)

  it("does not set noDefaultFeatures for workspace member applies", function()
    local client = make_client(workspace_root)
    clients = { client }

    local ok, err = lsp.apply({ "a/foo" }, {
      manifest_path = vim.fs.joinpath(workspace_root, "crates", "a", "Cargo.toml"),
      workspace_root = workspace_root,
      package_name = "a",
      scope = "package",
      remember = true,
    })

    assert.is_true(ok, err)
    assert.is_nil(client.settings["rust-analyzer"].cargo.noDefaultFeatures)
  end)

  it("resolves conflicting remembered default states by keeping defaults enabled", function()
    state.remember_applied({
      selected = { "foo" },
      manifest_path = vim.fs.joinpath(workspace_root, "Cargo.toml"),
      workspace_root = workspace_root,
      scope = "workspace",
      has_default = true,
      default_enabled = false,
    })
    state.remember_applied({
      selected = { "bar" },
      manifest_path = vim.fs.joinpath(workspace_root, "crates", "a", "Cargo.toml"),
      workspace_root = workspace_root,
      scope = "package",
      has_default = true,
      default_enabled = true,
    })

    local client = make_client(workspace_root)
    lsp.reapply_for_client(client)

    assert.is_false(client.settings["rust-analyzer"].cargo.noDefaultFeatures)
  end)

  it("sets noDefaultFeatures when all remembered default states disable defaults", function()
    state.remember_applied({
      selected = { "foo" },
      manifest_path = vim.fs.joinpath(workspace_root, "Cargo.toml"),
      workspace_root = workspace_root,
      scope = "workspace",
      has_default = true,
      default_enabled = false,
    })
    state.remember_applied({
      selected = { "bar" },
      manifest_path = vim.fs.joinpath(workspace_root, "crates", "a", "Cargo.toml"),
      workspace_root = workspace_root,
      scope = "package",
      has_default = true,
      default_enabled = false,
    })

    local client = make_client(workspace_root)
    lsp.reapply_for_client(client)

    assert.is_true(client.settings["rust-analyzer"].cargo.noDefaultFeatures)
  end)

  it("debug_clients reports attachment roots and manifest coverage", function()
    local client = make_client(simple_root, { name = "rust-analyzer" })
    client.id = 7
    clients = { client }

    vim.lsp.get_clients = function(opts)
      opts = opts or {}
      if opts.bufnr then
        return { client }
      end
      return clients
    end

    local notified
    vim.notify = function(message)
      notified = message
    end

    local message = lsp.debug_clients({ bufnr = 1, manifest_path = manifest })

    assert.equals(message, notified)
    assert.matches("client 7", message)
    assert.matches("name: rust%-analyzer", message)
    assert.matches("attached: yes", message)
    assert.matches("covers manifest: yes", message)
  end)
end)
