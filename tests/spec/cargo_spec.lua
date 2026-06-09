local cargo = require("cargo-features.cargo")

describe("cargo feature parsing", function()
  it("extracts feature names from a simple manifest", function()
    local manifest = vim.fs.normalize("tests/fixtures/simple/Cargo.toml")
    local parsed = assert(cargo.parse_toml(manifest))
    local names = vim.tbl_map(function(feature)
      return feature.name
    end, parsed.features)

    assert.are.same({ "metrics", "quoted-feature", "serde", "tokio" }, names)
    assert.equals("simple", parsed.package_name)
    assert.equals("standalone", parsed.context)
    assert.is_true(parsed.default_features_supported)
    assert.is_true(parsed.features[3].default_included)
  end)

  it("loads feature metadata with cargo metadata", function()
    local metadata = assert(cargo.metadata("tests/fixtures/simple/Cargo.toml"))

    assert.equals("simple", metadata.package_name)
    assert.equals("package", metadata.scope)
    assert.equals("standalone", metadata.context)
    assert.equals(4, #metadata.features)
    assert.is_true(metadata.default_features_supported)
    local serde = vim.tbl_filter(function(feature)
      return feature.name == "serde"
    end, metadata.features)[1]
    assert.is_true(serde.default_included)
  end)
end)
