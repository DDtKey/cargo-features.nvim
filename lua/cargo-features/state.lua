local util = require("cargo-features.util")

local M = {}

---@class CargoFeaturesAppliedSelection
---@field selected string[]
---@field manifest_path string
---@field workspace_root? string
---@field package_name? string
---@field scope? "package"|"workspace"
---@field has_default? boolean
---@field default_enabled? boolean
---@field all_enabled? boolean
---@field allow_all_features_token? boolean

-- In-memory restart resilience. These entries are always session-local and are
-- reapplied to matching rust_analyzer clients after user-triggered restarts.
---@type table<string, CargoFeaturesAppliedSelection>
local applied = {}

---@param opts CargoFeaturesAppliedSelection
---@return string
local function applied_key(opts)
  local parts = {
    util.abspath(opts.manifest_path),
    opts.workspace_root and util.abspath(opts.workspace_root) or "",
    opts.package_name or "",
    opts.scope or "",
  }
  return table.concat(parts, "\n")
end

---@param opts CargoFeaturesAppliedSelection
function M.remember_applied(opts)
  if not opts.manifest_path then
    return
  end

  local copy = vim.deepcopy(opts)
  copy.manifest_path = util.abspath(copy.manifest_path)
  if copy.workspace_root then
    copy.workspace_root = util.abspath(copy.workspace_root)
  end
  copy.selected = util.unique_sorted(copy.selected or {})
  applied[applied_key(copy)] = copy
end

---@return CargoFeaturesAppliedSelection[]
function M.applied()
  local out = {}
  for _, entry in pairs(applied) do
    table.insert(out, vim.deepcopy(entry))
  end
  table.sort(out, function(a, b)
    return applied_key(a) < applied_key(b)
  end)
  return out
end

function M.clear_applied()
  applied = {}
end

return M
