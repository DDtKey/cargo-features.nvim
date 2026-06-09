local M = {}

---@param context table
---@return table[]
local function profile_candidates(context)
  local api = require("cargo-features")
  local candidates = {}
  local seen = {}

  local scopes = {
    {
      label = "package",
      context = vim.tbl_extend("force", context, {
        scope = "package",
      }),
    },
  }

  if context.workspace_root and context.workspace_root ~= "" then
    table.insert(scopes, {
      label = "workspace",
      context = vim.tbl_extend("force", context, {
        scope = "workspace",
      }),
    })
  end

  for _, scope in ipairs(scopes) do
    for _, name in ipairs(api.list_profiles(scope.context)) do
      local key = ("%s\n%s"):format(scope.label, name)
      if not seen[key] then
        seen[key] = true
        table.insert(candidates, {
          name = name,
          scope = scope.label,
          context = scope.context,
          display = ("%s (%s)"):format(name, scope.label),
        })
      end
    end
  end

  table.sort(candidates, function(a, b)
    if a.name == b.name then
      return a.scope < b.scope
    end
    return a.name < b.name
  end)

  return candidates
end

---@param candidates table[]
---@param name string
---@return table?
local function choose_candidate(candidates, name)
  local workspace_candidate = nil
  for _, candidate in ipairs(candidates) do
    if candidate.name == name then
      if candidate.scope == "package" then
        return candidate
      end
      workspace_candidate = workspace_candidate or candidate
    end
  end
  return workspace_candidate
end

function M.create()
  vim.api.nvim_create_user_command("CargoFeatures", function()
    require("cargo-features").open()
  end, {
    desc = "Open Cargo feature manager for rust-analyzer",
  })

  vim.api.nvim_create_user_command("CargoFeaturesDebug", function()
    require("cargo-features.lsp").debug_clients()
  end, {
    desc = "Show rust-analyzer client matching details",
  })

  vim.api.nvim_create_user_command("CargoFeaturesApplyProfile", function(opts)
    local api = require("cargo-features")
    local util = require("cargo-features.util")
    local name = opts.args ~= "" and opts.args or nil

    local function apply(candidate)
      local ok, err = api.apply_profile(candidate.name, candidate.context)
      if ok then
        util.notify(("Applied Cargo feature profile: %s"):format(candidate.display))
      else
        util.notify(err or "Unable to apply Cargo feature profile", vim.log.levels.ERROR)
      end
    end

    local context, err = api._resolve_context({ bufnr = vim.api.nvim_get_current_buf() })
    if not context then
      util.notify(err or "Unable to resolve Cargo feature profile context", vim.log.levels.ERROR)
      return
    end

    local candidates = profile_candidates(context)
    if name then
      local candidate = choose_candidate(candidates, name)
      if not candidate then
        util.notify(("Profile not found: %s"):format(name), vim.log.levels.ERROR)
        return
      end
      apply(candidate)
      return
    end

    if #candidates == 0 then
      util.notify("No Cargo feature profiles saved for this project", vim.log.levels.INFO)
      return
    end

    vim.ui.select(candidates, {
      prompt = "Cargo feature profile",
      format_item = function(candidate)
        return candidate.display
      end,
    }, function(choice)
      if not choice then
        return
      end
      apply(choice)
    end)
  end, {
    nargs = "?",
    desc = "Apply a saved Cargo feature profile to rust-analyzer",
  })

  vim.api.nvim_create_user_command("CargoFeaturesReset", function(opts)
    local ok, err = require("cargo-features").reset({ force = opts.bang })
    if ok then
      require("cargo-features.util").notify("Reset Cargo feature overrides for rust-analyzer")
    else
      require("cargo-features.util").notify(
        err or "Unable to reset Cargo feature overrides",
        vim.log.levels.ERROR
      )
    end
  end, {
    bang = true,
    desc = "Reset plugin-applied Cargo feature overrides for rust-analyzer",
  })
end

return M
