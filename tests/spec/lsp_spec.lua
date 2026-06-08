local config = require("cargo-features.config")
local lsp = require("cargo-features.lsp")
local state = require("cargo-features.state")

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
  local original_notify
  local clients
  local notifications
  local restart_called

  before_each(function()
    config.setup({
      lsp = {
        notify = true,
        sync_check_features = "if_set",
        use_all_features_token = false,
      },
    })
    state.clear_applied()

    original_get_clients = vim.lsp.get_clients
    original_cmd = vim.cmd
    original_notify = vim.notify
    clients = {}
    notifications = {}
    restart_called = false

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
  end)

  after_each(function()
    vim.lsp.get_clients = original_get_clients
    vim.cmd = original_cmd
    vim.notify = original_notify
    state.clear_applied()
    lsp._clear_reapplied_clients()
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

  it("defaults to conservative reapply when the client has no explicit feature settings", function()
    config.setup()

    assert.are.equal("if_empty", config.get().lsp.reapply_policy)
  end)

  it("normalizes invalid reapply_policy to if_empty", function()
    config.setup({
      lsp = {
        reapply_policy = "if-empty",
      },
    })

    assert.are.equal("if_empty", config.get().lsp.reapply_policy)

    config.setup({
      lsp = {
        reapply_policy = false,
      },
    })
    assert.are.equal("if_empty", config.get().lsp.reapply_policy)
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

  it("does not reapply remembered selections when reapply_policy is never", function()
    config.setup({
      lsp = {
        reapply_policy = "never",
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

  it("reapplies remembered selections with if_empty when no explicit feature settings exist", function()
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
  end)

  it("skips if_empty reapply and notifies once when explicit cargo.features differs", function()
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

  it("does not overwrite explicit cargo.features when reapply_policy is invalid", function()
    config.setup({
      lsp = {
        reapply_policy = "if-empty",
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
  end)

  it("skips if_empty reapply without warning when explicit cargo.features is equivalent", function()
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

  it("overwrites explicit cargo.features when reapply_policy is always", function()
    config.setup({
      lsp = {
        reapply_policy = "always",
      },
    })
    state.remember_applied({
      selected = { "serde" },
      manifest_path = manifest,
      scope = "package",
      has_default = true,
      default_enabled = false,
    })

    local client = make_client(simple_root, {
      settings = {
        ["rust-analyzer"] = {
          cargo = {
            features = { "metrics" },
            noDefaultFeatures = false,
          },
        },
      },
    })

    lsp.reapply_for_client(client)

    assert.are.same({ "serde" }, client.settings["rust-analyzer"].cargo.features)
    assert.is_true(client.settings["rust-analyzer"].cargo.noDefaultFeatures)
    assert.are.equal(1, client.notify_count)
    assert.are.equal(0, #notifications)
  end)

  it("can use cargo.features all only when explicitly configured and workspace-scoped", function()
    config.setup({
      lsp = {
        notify = true,
        sync_check_features = "if_set",
        use_all_features_token = true,
      },
    })

    local client = make_client(workspace_root)
    clients = { client }

    local ok, err = lsp.apply({ "a/foo", "a/bar" }, {
      manifest_path = vim.fs.joinpath(workspace_root, "Cargo.toml"),
      scope = "workspace",
      all_enabled = true,
      allow_all_features_token = true,
    })

    assert.is_true(ok, err)
    assert.are.equal("all", client.settings["rust-analyzer"].cargo.features)
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
    config.setup({
      lsp = {
        notify = true,
        sync_check_features = "if_set",
        use_all_features_token = true,
      },
    })
    state.remember_applied({
      selected = { "a/foo" },
      manifest_path = vim.fs.joinpath(workspace_root, "crates", "a", "Cargo.toml"),
      workspace_root = workspace_root,
      package_name = "a",
      scope = "package",
      all_enabled = true,
      allow_all_features_token = true,
    })
    state.remember_applied({
      selected = { "b/bar" },
      manifest_path = vim.fs.joinpath(workspace_root, "crates", "b", "Cargo.toml"),
      workspace_root = workspace_root,
      package_name = "b",
      scope = "package",
      all_enabled = true,
      allow_all_features_token = true,
    })

    local client = make_client(workspace_root)
    lsp.reapply_for_client(client)

    assert.are.same({ "a/foo", "b/bar" }, client.settings["rust-analyzer"].cargo.features)
  end)

  it("does not collapse mixed remembered workspace and member selections to all", function()
    config.setup({
      lsp = {
        notify = true,
        sync_check_features = "if_set",
        use_all_features_token = true,
      },
    })
    state.remember_applied({
      selected = { "a/foo", "b/bar" },
      manifest_path = vim.fs.joinpath(workspace_root, "Cargo.toml"),
      workspace_root = workspace_root,
      scope = "workspace",
      all_enabled = true,
      allow_all_features_token = true,
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

  it("can reapply all for one unambiguous workspace all selection", function()
    config.setup({
      lsp = {
        notify = true,
        sync_check_features = "if_set",
        use_all_features_token = true,
      },
    })
    state.remember_applied({
      selected = { "a/foo", "b/bar" },
      manifest_path = vim.fs.joinpath(workspace_root, "Cargo.toml"),
      workspace_root = workspace_root,
      scope = "workspace",
      all_enabled = true,
      allow_all_features_token = true,
    })

    local client = make_client(workspace_root)
    lsp.reapply_for_client(client)

    assert.are.equal("all", client.settings["rust-analyzer"].cargo.features)
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
