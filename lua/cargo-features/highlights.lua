local config = require("cargo-features.config")

local M = {}
local autocmd_created = false

---@param force? boolean
function M.setup(force)
  for group, link in pairs(config.get().highlights) do
    vim.api.nvim_set_hl(0, group, { link = link, default = not force })
  end
end

function M.create_autocmd()
  if autocmd_created then
    return
  end
  autocmd_created = true

  local group = vim.api.nvim_create_augroup("CargoFeaturesHighlights", { clear = true })
  vim.api.nvim_create_autocmd("ColorScheme", {
    group = group,
    callback = function()
      M.setup(true)
    end,
  })
end

return M
