local M = {}

---@param value any
---@return boolean
function M.is_array(value)
  if type(value) ~= "table" then
    return false
  end

  local count = 0
  for key, _ in pairs(value) do
    if type(key) ~= "number" then
      return false
    end
    count = count + 1
  end

  return count == #value
end

---@param path string
---@return string
function M.normalize(path)
  return vim.fs.normalize(path)
end

---@param values string[]
---@return string[]
function M.unique_sorted(values)
  local seen = {}
  local out = {}
  for _, value in ipairs(values) do
    if value ~= "" and not seen[value] then
      seen[value] = true
      table.insert(out, value)
    end
  end
  table.sort(out)
  return out
end

---@param path string
---@return string
function M.abspath(path)
  return M.normalize(vim.fn.fnamemodify(path, ":p"))
end

---@param path string
---@return string
function M.basename(path)
  return vim.fs.basename(path:gsub("[/\\]$", ""))
end

---@param path string
---@return string
function M.dirname(path)
  return vim.fs.dirname(path)
end

---@param msg string
---@param level? integer
function M.notify(msg, level)
  vim.notify(msg, level or vim.log.levels.INFO, { title = "cargo-features.nvim" })
end

return M
