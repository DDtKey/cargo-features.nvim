local cargo = require("cargo-features.cargo")

describe("workspace feature discovery", function()
  it("uses package-qualified features for virtual workspace roots", function()
    local metadata = assert(cargo.metadata("tests/fixtures/workspace/Cargo.toml"))
    local names = vim.tbl_map(function(feature)
      return feature.name
    end, metadata.features)

    assert.equals("workspace", metadata.scope)
    assert.equals("workspace", metadata.context)
    assert.is_true(vim.tbl_contains(names, "a/foo"))
    assert.is_true(vim.tbl_contains(names, "a/bar"))
    assert.is_false(vim.tbl_contains(names, "a/default"))
    assert.is_true(metadata.default_features_supported)

    local foo = vim.tbl_filter(function(feature)
      return feature.name == "a/foo"
    end, metadata.features)[1]
    assert.is_true(foo.default_included)
  end)

  it("uses package-qualified features for workspace members", function()
    local member = assert(cargo.metadata("tests/fixtures/workspace/crates/a/Cargo.toml"))
    local names = vim.tbl_map(function(feature)
      return feature.name
    end, member.features)
    local apply_names = vim.tbl_map(function(feature)
      return feature.apply_name
    end, member.features)

    assert.equals("package", member.scope)
    assert.equals("member", member.context)
    assert.is_true(vim.tbl_contains(names, "foo"))
    assert.is_true(vim.tbl_contains(names, "bar"))
    assert.is_false(vim.tbl_contains(names, "a/foo"))
    assert.is_true(vim.tbl_contains(apply_names, "a/foo"))
    assert.is_true(vim.tbl_contains(apply_names, "a/bar"))
    assert.is_false(vim.tbl_contains(apply_names, "a/default"))
    assert.is_true(member.default_features_supported)

    local foo = vim.tbl_filter(function(feature)
      return feature.apply_name == "a/foo"
    end, member.features)[1]
    assert.is_true(foo.default_included)
  end)
end)
