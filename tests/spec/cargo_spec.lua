local cargo = require("cargo-features.cargo")

describe("cargo feature parsing", function()
  it("extracts feature names from a simple manifest", function()
    local manifest = vim.fs.normalize("tests/fixtures/simple/Cargo.toml")
    local parsed = assert(cargo.parse_toml(manifest))
    local names = vim.tbl_map(function(feature)
      return feature.name
    end, parsed.features)

    assert.are.same({ "default", "metrics", "quoted-feature", "serde", "tokio" }, names)
    assert.equals("simple", parsed.package_name)
  end)

  it("loads feature metadata with cargo metadata", function()
    local metadata = assert(cargo.metadata("tests/fixtures/simple/Cargo.toml"))

    assert.equals("simple", metadata.package_name)
    assert.equals("package", metadata.scope)
    assert.equals(5, #metadata.features)
  end)
end)
