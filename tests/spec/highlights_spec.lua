describe("highlight setup", function()
  it("lets configured highlight links override eager defaults", function()
    require("cargo-features").setup({
      highlights = {
        CargoFeaturesEnabled = "String",
      },
    })

    local hl = vim.api.nvim_get_hl(0, { name = "CargoFeaturesEnabled", link = true })
    assert.equals("String", hl.link)
  end)
end)
