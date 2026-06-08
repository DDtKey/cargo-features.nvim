
# Project Specification: cargo-features.nvim

## Overview

Build a modern Neovim plugin that provides a graphical interface for managing Cargo features used by rust-analyzer.

The plugin should solve a common Rust development problem:

Today enabling/disabling rust-analyzer Cargo features usually requires manually editing Neovim configuration and restarting rust-analyzer.

The goal is to provide an interactive UI that allows developers to:

* inspect available Cargo features
* enable/disable them interactively
* apply changes immediately to rust-analyzer
* switch between feature sets quickly during development

The plugin should feel native to modern Neovim and integrate well with:

* lazy.nvim
* LazyVim
* rustaceanvim
* nvim-lspconfig

without requiring any of them.

---

# Research Tasks

Before implementation, perform a detailed analysis of:

## Existing Solutions

Investigate whether similar functionality already exists in:

* rustaceanvim
* crates.nvim
* cargo.nvim
* overseer.nvim
* telescope extensions
* snacks.nvim integrations
* RustRover
* VSCode rust-analyzer integrations

Questions:

* How do users currently switch Cargo features?
* What pain points exist?
* Are there existing UI patterns worth copying?
* Is there a gap that this plugin can fill?

Document findings.

---

# Design Goals

## Primary Goal

Interactive Cargo feature management for rust-analyzer.

## Secondary Goals

Provide a foundation for future Rust workspace tooling.

Potential future modules:

* feature presets
* cargo command launcher
* workspace package switcher
* target triple selector
* rust-analyzer config inspector

Architecture should allow future expansion.

---

# Non Goals

Do not:

* manage Rust toolchains
* install rust-analyzer
* configure Mason
* configure rustaceanvim
* configure LSP startup

The plugin operates only on already-running rust-analyzer clients.

---

# UI Requirements

## General Principles

UI should:

* feel native to Neovim
* have zero required dependencies
* work with any colorscheme
* avoid hardcoded colors
* be keyboard-first
* work in terminals and GUIs

Native Neovim APIs should be the primary implementation.

Preferred:

* vim.api.nvim_open_win
* extmarks
* namespaces
* highlight groups

Avoid requiring:

* telescope.nvim
* mini.pick
* nui.nvim
* snacks.nvim

Optional integrations may be added later.

---

## Theme Compatibility

This is extremely important.

The UI must remain usable regardless of:

* Catppuccin
* TokyoNight
* Gruvbox
* Kanagawa
* Everforest
* Rose Pine
* Default Vim themes
* custom themes

Do not assume any color palette.

Instead:

Create semantic highlight groups:

CargoFeaturesTitle
CargoFeaturesEnabled
CargoFeaturesDisabled
CargoFeaturesSelection
CargoFeaturesBorder

Link them to existing Neovim groups where possible.

Example:

CargoFeaturesEnabled -> DiagnosticOk
CargoFeaturesDisabled -> Comment
CargoFeaturesSelection -> CursorLine

Users should be able to override all groups.

---

## Floating Window

Centered floating window.

Requirements:

* configurable dimensions
* configurable border
* configurable title
* cursorline enabled
* no line numbers
* no statusline
* no signcolumn

Example:

┌ Cargo Features ─────────────────────┐
│ ☑ serde                            │
│ ☑ tracing                          │
│ ☐ metrics                          │
│ ☐ tokio                            │
│                                     │
│ A Toggle All                       │
│ W Apply                            │
│ Q Close                            │
└─────────────────────────────────────┘

---

## Feature List

Display:

enabled:

☑ feature_name

disabled:

☐ feature_name

Prefer unicode icons.

Fallback support should exist.

Configurable icons:

checked
unchecked

---

# User Interactions

## Toggle Feature

Keys:

* Enter
* Space

Toggle currently selected feature.

UI updates immediately.

---

## Toggle All

Key:

A

Behavior:

If all enabled:

* disable all

Otherwise:

* enable all

---

## Apply

Default key:

W

Behavior:

* update rust-analyzer settings
* notify workspace/didChangeConfiguration
* optionally restart rust-analyzer

---

## Close

Keys:

* q
* Esc

No changes applied.

---

# Cargo Parsing

## Discovery

Find nearest Cargo.toml.

Search upward from current buffer.

Use:

vim.fs.find()

Requirements:

* work in workspaces
* work in nested crates
* work from tests/examples directories

---

## Feature Parsing

Parse:

[features]

section.

Extract only feature names.

Ignore:

* comments
* values
* arrays

Example:

[features]
default = ["serde"]
tokio = []
metrics = []
tracing = []

Should produce:

default
tokio
metrics
tracing

Research whether a proper TOML parser should be used.

Questions:

* Is manual parsing sufficient?
* Is there a lightweight TOML parser suitable for Neovim?

Provide recommendation.

---

# rust-analyzer Integration

## Client Discovery

Find active rust-analyzer client.

Support:

* rustaceanvim
* nvim-lspconfig

Must not care how client was started.

Only identify by:

client.name == "rust_analyzer"

---

## Settings Update

Update:

rust-analyzer.cargo.features

Example:

{
"serde",
"tokio"
}

Set:

rust-analyzer.cargo.allFeatures = false

Optional:

sync rust-analyzer.check.features

Research whether this is recommended.

---

## Configuration Reload

Send:

workspace/didChangeConfiguration

notification.

Research current rust-analyzer behavior.

Determine:

* whether restart is actually necessary
* whether notification alone is enough

Prefer avoiding restart if possible.

Restart should be configurable.

---

# Persistence

Research whether users would benefit from project-local persistence.

Potential approaches:

Option A:
No persistence.

Option B:
Store under:

stdpath("state")

Option C:
Store inside:

.project/.nvim/

Evaluate pros/cons.

Provide recommendation.

---

# Plugin Architecture

Target structure:

lua/
cargo-features/
init.lua
config.lua
state.lua
cargo.lua
lsp.lua
ui.lua
highlights.lua
commands.lua

plugin/
cargo-features.lua

Responsibilities:

config.lua

* defaults
* setup

cargo.lua

* Cargo.toml discovery
* feature parsing

lsp.lua

* rust-analyzer interaction

ui.lua

* floating window
* rendering
* keymaps

state.lua

* session state

highlights.lua

* highlight definitions

commands.lua

* user commands

---

# Public API

Desired:

require("cargo-features").setup()

require("cargo-features").open()

Commands:

:CargoFeatures

Potential future:

:CargoFeaturesApply
:CargoFeaturesReset
:CargoFeaturesPreset

---

# lazy.nvim Compatibility

Plugin must support:

{
"author/cargo-features.nvim",
ft = "rust",
cmd = "CargoFeatures",
opts = {},
}

No special setup required.

---

# LazyVim Compatibility

Plugin should work out of the box.

Example:

{
"author/cargo-features.nvim",
ft = "rust",
keys = {
{
"<leader>cF",
function()
require("cargo-features").open()
end,
desc = "Cargo Features",
},
},
}

---

# Optional Future Integrations

Not part of MVP.

Potential optional modules:

## Telescope

Feature picker.

## mini.pick

Feature picker.

## snacks.nvim

Native snacks picker.

These should be optional adapters.

Core plugin must not depend on them.

---

# Potential Future Expansion

If the plugin succeeds, investigate:

## Feature Presets

Examples:

* default
* full
* wasm
* no_std
* tests

## Workspace Package Picker

For large workspaces.

## Cargo Command Center

Run:

cargo test
cargo check
cargo clippy
cargo bench
cargo nextest

with current feature selection.

## rust-analyzer Inspector

Display:

* active features
* allFeatures
* target
* check features

## cfg Visualization

Show why code is disabled.

Potentially integrate with rust-analyzer diagnostics.

---

# Deliverables

1. Research report
2. Architecture proposal
3. UX proposal
4. MVP implementation
5. README
6. lazy.nvim examples
7. LazyVim examples
8. Screenshot/GIF examples
9. Future roadmap
