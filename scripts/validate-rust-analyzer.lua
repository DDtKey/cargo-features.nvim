if vim.fn.executable("rust-analyzer") ~= 1 then
  error("rust-analyzer executable not found")
end

vim.opt.runtimepath:append(vim.uv.cwd())

local function validate(root, manifest, source, feature)
  vim.cmd.edit(source)

  local bufnr = vim.api.nvim_get_current_buf()
  local client_id = vim.lsp.start({
    name = "rust-analyzer",
    cmd = { "rust-analyzer" },
    capabilities = {
      workspace = {
        didChangeWatchedFiles = {
          dynamicRegistration = false,
        },
      },
    },
    root_dir = root,
    settings = {
      ["rust-analyzer"] = {
        cargo = {
          features = {},
          noDefaultFeatures = true,
        },
      },
    },
  })

  assert(client_id, "failed to start rust-analyzer")

  local client = vim.lsp.get_client_by_id(client_id)
  assert(client, "rust-analyzer client not found")

  vim.lsp.buf_attach_client(bufnr, client_id)

  local function diagnostics_contain(pattern)
    for _, diagnostic in ipairs(vim.diagnostic.get(bufnr)) do
      if diagnostic.message:match(pattern) then
        return true
      end
    end
    return false
  end

  local saw_disabled = vim.wait(20000, function()
    return diagnostics_contain("gated") or diagnostics_contain("not found")
  end, 100)

  assert(saw_disabled, "rust-analyzer did not report the cfg-gated missing function")

  local ok, err = require("cargo-features.lsp").apply({ feature }, {
    bufnr = bufnr,
    manifest_path = manifest,
    scope = "package",
    remember = false,
  })

  assert(ok, err)

  local cleared = vim.wait(20000, function()
    return not diagnostics_contain("gated") and not diagnostics_contain("not found")
  end, 100)

  assert(cleared, "rust-analyzer diagnostics did not update after didChangeConfiguration")

  client:stop(false)
end

local single_root = vim.fs.normalize(vim.fs.joinpath(vim.uv.cwd(), "tests", "fixtures", "live-ra"))
validate(
  single_root,
  vim.fs.joinpath(single_root, "Cargo.toml"),
  vim.fs.joinpath(single_root, "src", "lib.rs"),
  "extra"
)

local workspace_root = vim.fs.normalize(vim.fs.joinpath(vim.uv.cwd(), "tests", "fixtures", "live-workspace"))
validate(
  workspace_root,
  vim.fs.joinpath(workspace_root, "crates", "a", "Cargo.toml"),
  vim.fs.joinpath(workspace_root, "crates", "a", "src", "lib.rs"),
  "a/extra"
)

print("validated rust-analyzer live apply: " .. vim.fn.system({ "rust-analyzer", "--version" }):gsub("%s+$", ""))
