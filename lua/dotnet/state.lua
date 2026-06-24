--- Lightweight buffer-keyed state store.

local M = {}

---@type table<integer, {sln_path: string, fmt: string, raw: string, raw_bytes: string, root: table, nesting: table, nesting_ordered: table[], flat: table[], rendering: boolean}>
local _state = {}

function M.set(bufnr, entry) _state[bufnr] = entry end
function M.get(bufnr) return _state[bufnr] end
function M.clear(bufnr) _state[bufnr] = nil end

return M
