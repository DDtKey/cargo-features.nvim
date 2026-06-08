local cargo = require("cargo-features.cargo")
local config = require("cargo-features.config")

describe("cargo metadata timeout handling", function()
  it("reports synchronous metadata timeouts explicitly", function()
    config.setup({
      cargo = {
        use_metadata = true,
        metadata_timeout = 50,
        metadata_env = {
          PATH = vim.fs.joinpath(vim.uv.cwd(), "tests", "fixtures", "slow-cargo-bin")
            .. ":"
            .. vim.env.PATH,
        },
      },
    })

    local manifest, err = cargo.metadata("tests/fixtures/simple/Cargo.toml")

    assert.is_nil(manifest)
    assert.equals("cargo metadata timed out", err)
  end)
end)
