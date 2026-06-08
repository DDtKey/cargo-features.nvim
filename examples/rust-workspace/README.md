# Manual Rust Workspace Sandbox

This workspace is a small, artificial project for manually checking
`cargo-features.nvim` against a real `rust-analyzer` client.

It is not used by the automated test suite.

## Try It

1. Open this directory in Neovim:

   ```sh
   nvim examples/rust-workspace/crates/app/src/lib.rs
   ```

2. Start rust-analyzer as usual through your Neovim config.

3. Run:

   ```vim
   :CargoFeatures
   ```

4. Toggle `metrics`, `serde`, and `unstable`, then apply with `W`.

## What to Look For

- `serde` changes which `serialization_mode()` branch rust-analyzer sees.
- `metrics` enables the `record_metric()` function.
- `unstable` intentionally enables a type mismatch in `unstable_probe()`.
  When enabled, rust-analyzer should report a diagnostic in
  `crates/app/src/lib.rs`. When disabled, that diagnostic should disappear.

If you open the virtual workspace root, package features may appear as
`example-app/metrics` or `example-core/tracing`. From a package manifest or
package source file, the plugin focuses on the nearest package.
