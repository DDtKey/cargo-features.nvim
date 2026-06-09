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

-- In-memory session reapply state. These entries are always session-local and
-- reapplied only to safe matching rust-analyzer clients on LspAttach.
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

---@param opts { manifest_path?: string, workspace_root?: string }
function M.forget_applied(opts)
  if not opts or not opts.manifest_path then
    return
  end

  local key = opts.workspace_root and util.abspath(opts.workspace_root) or util.abspath(opts.manifest_path)
  for entry_key, entry in pairs(applied) do
    local entry_workspace = entry.workspace_root and util.abspath(entry.workspace_root) or util.abspath(entry.manifest_path)
    if entry_workspace == key then
      applied[entry_key] = nil
    end
  end
end

return M
