--- Default configuration for dotnet.nvim.
--- Call require("dotnet").setup(opts) to override.

local M = {}

---@class dotnet.Config
---@field keymap string|false Global keymap to toggle the solution view (default: "<leader>ds")

---@type dotnet.Config
M.values = {
    keymap = "<leader>ds",
}

---@param opts? dotnet.Config
function M.apply(opts)
    M.values = vim.tbl_deep_extend("force", M.values, opts or {})
end

return M
