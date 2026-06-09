# cargo-features.nvim

Native Cargo feature switching for `rust-analyzer` in Neovim.

`cargo-features.nvim` opens a floating UI for the nearest `Cargo.toml`,
lets you toggle features, and applies the selection to active rust-analyzer
clients. It has no runtime dependencies.

## Requirements

- Neovim 0.10+
- An active `rust-analyzer` LSP client
- `cargo` for best feature discovery

## Why

Rust projects often put important code behind Cargo features. In Neovim, changing
the feature set usually means editing LSP settings, running a rustaceanvim
command, or keeping a local helper around.

This plugin gives that workflow an interactive UI:

```vim
:CargoFeatures
```

It talks to existing rust-analyzer clients, so it works with the LSP setup you
already use. The plugin recognizes the canonical `rust-analyzer` client name,
the `rust_analyzer` compatibility alias, and custom-named clients launched with
the `rust-analyzer` executable.

## Installation

### lazy.nvim

Tagged releases are recommended for normal users. `main` may contain breaking
or experimental pre-release changes.

```lua
{
  "ddtkey/cargo-features.nvim",
  version = "*",
  ft = "rust",
  cmd = { "CargoFeatures", "CargoFeaturesReset", "CargoFeaturesDebug" },
  keys = {
    {
      "<leader>rf",
      function()
        require("cargo-features").open()
      end,
      desc = "Cargo Features",
    },
  },
  opts = {},
}
```

For development/latest, use the same spec but replace `version` with:

```lua
branch = "main",
```

## Usage

Open the picker:

```vim
:CargoFeatures
```

If the plugin cannot find the expected LSP client, run:

```vim
:CargoFeaturesDebug
```

Remove plugin-applied overrides and return to the rust-analyzer/Cargo defaults:

```vim
:CargoFeaturesReset
```

`CargoFeaturesReset!` is available when you explicitly want to clear matching
live Cargo feature settings even if the plugin has no in-memory ownership record
for them.

Default keys:

| Key | Action |
| --- | --- |
| `<CR>` / `<Space>` | Toggle feature |
| `A` | Toggle all |
| `W` | Apply |
| `R` | Reset plugin-applied override |
| `q` / `<Esc>` | Close |

Lua helpers:

```lua
require("cargo-features").reset(opts)
```

`reset()` resolves the current buffer by default. Pass `force = true` to clear
matching live Cargo feature settings even without a remembered plugin-applied
override.

Experimental profile helpers are public for pre-1.0 feedback:

```lua
require("cargo-features").save_profile("debug", opts)
require("cargo-features").load_profile("debug", opts)
require("cargo-features").delete_profile("debug", opts)
require("cargo-features").list_profiles(opts)
```

`save_profile()` requires `opts.manifest_path` and accepts `features`,
`default_enabled`, `scope`, `workspace_root`, and `package_name`.
`load_profile()`, `delete_profile()`, and `list_profiles()` require enough
context to find the profile key: package profiles use `manifest_path`;
workspace profiles use `workspace_root` when `scope = "workspace"`.

## Configuration

Defaults:

```lua
require("cargo-features").setup({
  cargo = {
    use_metadata = true,
    metadata_timeout = 3000,
    metadata_extra_args = {},
    metadata_env = {},
    metadata_cwd = nil,
  },
  lsp = {
    notify = true,
    reapply_policy = "if_empty", -- "never" | "if_empty" | "always"
    refresh_after_apply = true,
    sync_check_features = "if_set", -- "never" | "if_set" | "always"
    use_all_features_token = false,
  },
  persistence = {
    enabled = false,
    default_profile = "default",
    auto_save = false,
    auto_load = "never", -- "never" | "if_no_client" | "always"
  },
  ui = {
    ascii_icons = false,
    border = "rounded",
    height = 18,
    title = "Cargo Features",
    width = 60,
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
  },
})
```

## Behavior

- Feature discovery uses async `cargo metadata --no-deps` when available.
- If metadata fails, a small fallback parser reads simple local `[features]`
  keys.
- Applying features updates `rust-analyzer.cargo.features` and
  `rust-analyzer.cargo.noDefaultFeatures`, then sends
  `workspace/didChangeConfiguration`.
- Unchecking every feature applies an explicit empty feature set. Reset is
  different: it removes the plugin-applied override and lets rust-analyzer use
  Cargo.toml/default Cargo behavior again.
- After apply/reset, `lsp.refresh_after_apply = true` requests a semantic-token
  refresh when supported by Neovim. This is best-effort and scoped to currently
  loaded Rust buffers attached to the updated rust-analyzer clients. It does not
  reload buffers, open unloaded buffers, or restart rust-analyzer.
- `:CargoFeaturesReset` clears plugin-applied live overrides remembered in the
  current Neovim session and does not delete disk profiles. `:CargoFeaturesReset!`
  can clear matching live Cargo feature settings without an ownership record.
- Selections applied from the UI are remembered in memory and reapplied to
  matching rust-analyzer clients that attach later in the same Neovim session.
- Live rust-analyzer settings are treated as the source of truth while a client
  is attached. In-memory state is only restart/LspAttach recovery.
- `lsp.reapply_policy` controls whether remembered plugin state may overwrite
  explicit rust-analyzer Cargo feature config. The default, `"if_empty"`, only
  reapplies when the new client has no explicit feature settings. Use `"always"`
  if you want remembered plugin state to win after restarts.
- Reapply groups remembered selections by Cargo workspace. If one
  rust-analyzer client appears to cover multiple unrelated Cargo workspaces,
  automatic reapply is skipped instead of sending a mixed `cargo.features` list.
- Lua callers that use `require("cargo-features").apply()` should pass
  `remember = true` when they want the same restart resilience.
- When applying from a Rust buffer, an attached rust-analyzer client is used
  even if its root metadata is missing or unusual.
- `rust-analyzer.check.features` is only updated when configured to do so. Reset
  restores check settings the plugin changed; forced reset clears check settings
  only when `lsp.sync_check_features = "always"`.
- Workspace member features are sent as `package/feature` when needed.
- Virtual workspace default features are not shown as normal checkboxes because
  `cargo.noDefaultFeatures` is workspace-global.
- If remembered default-feature states ever conflict inside one workspace,
  reapply keeps defaults enabled when any remembered entry enables them.
- Disk persistence is profile-shaped from the first release. `auto_save` stores
  the configured `default_profile`; named profile UI can be added later without
  changing the file format.
- Profile auto-load is conservative by default. Live rust-analyzer settings are
  the source of truth; profiles override them only with
  `persistence.auto_load = "always"`. Use `"if_no_client"` to load a profile
  only when no matching rust-analyzer client is available.

Live apply can be checked locally with `just validate-ra`.

## Highlights

The UI uses semantic highlight groups linked to common Neovim groups:

| Group | Default link |
| --- | --- |
| `CargoFeaturesTitle` | `Title` |
| `CargoFeaturesEnabled` | `DiagnosticOk` |
| `CargoFeaturesDisabled` | `Comment` |
| `CargoFeaturesSelection` | `CursorLine` |
| `CargoFeaturesBorder` | `FloatBorder` |
| `CargoFeaturesHelp` | `Comment` |
| `CargoFeaturesError` | `DiagnosticError` |

Example:

```lua
vim.api.nvim_set_hl(0, "CargoFeaturesEnabled", { link = "String" })
```

## Manual Sandbox

For manual smoke testing, open
[examples/rust-workspace](examples/rust-workspace/README.md). It contains a
small artificial workspace with visible `#[cfg(feature = "...")]` branches and
an intentional `unstable` feature diagnostic.

## Development

Plenary unit tests run in CI. The plugin itself does not depend on Plenary at
runtime.

```sh
git clone --depth 1 https://github.com/nvim-lua/plenary.nvim .deps/plenary.nvim
just test
```

Optional checks:

```sh
just fmt-check
just validate-ra
```

`just validate-ra` starts a real `rust-analyzer` client against local fixtures.
It is manual validation, not part of the fast CI unit test suite, and prints
the rust-analyzer version it used.

## License

MIT
