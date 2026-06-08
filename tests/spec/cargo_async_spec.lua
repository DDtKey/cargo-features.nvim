local cargo = require("cargo-features.cargo")
local config = require("cargo-features.config")

local manifest_path = "tests/fixtures/simple/Cargo.toml"

local function load_async()
  local manifest
  local err
  local done = false

  cargo.load_manifest_async(manifest_path, function(result, load_err)
    manifest = result
    err = load_err
    done = true
  end)

  vim.wait(5000, function()
    return done
  end)

  assert.is_true(done)
  return manifest, err
end

describe("async cargo discovery", function()
  before_each(function()
    config.setup({
      cargo = {
        use_metadata = true,
        metadata_timeout = 3000,
      },
    })
  end)

  it("loads cargo metadata asynchronously", function()
    local manifest, err = load_async()

    assert.is_not_nil(manifest, err)
    assert.equals("simple", manifest.package_name)
    assert.is_true(manifest.source == "cargo metadata" or manifest.source == "toml fallback")
  end)

  it("falls back to TOML parsing when async metadata fails", function()
    config.setup({
      cargo = {
        use_metadata = true,
        metadata_timeout = 3000,
        metadata_extra_args = { "--invalid-cargo-features-nvim-test-arg" },
      },
    })

    local manifest, err = load_async()

    assert.is_not_nil(manifest, err)
    assert.equals("simple", manifest.package_name)
    assert.equals("toml fallback", manifest.source)
  end)
end)
