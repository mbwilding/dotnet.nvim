local M = {}

---@class dotnet.State
---@field sln_path string
---@field fmt "sln"|"slnx"|"slnf"
---@field raw string
---@field raw_bytes string
---@field root table
---@field nesting table<string,string>
---@field nesting_ordered table[]
---@field flat table[]
---@field rendering boolean?

---@type table<integer, dotnet.State>
local _state = {}

---@param bufnr integer
---@param entry dotnet.State
function M.set(bufnr, entry)
    _state[bufnr] = entry
end

---@param bufnr integer
---@return dotnet.State|nil
function M.get(bufnr)
    return _state[bufnr]
end

---@param bufnr integer
function M.clear(bufnr)
    _state[bufnr] = nil
end

return M
