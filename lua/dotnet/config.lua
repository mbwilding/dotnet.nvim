local M = {}

---@class dotnet.KeymapsConfig
---@field toggle string|false Toggle the solution view (default: "<leader>ds")
---@field enable string|false Enable interception of .sln/.slnx/.slnf files (default: false)
---@field disable string|false Disable interception of .sln/.slnx/.slnf files (default: false)

---@class dotnet.Config
---@field enabled boolean Whether the solution view intercepts .sln/.slnx/.slnf files (default: true)
---@field keymaps dotnet.KeymapsConfig Global keybinds. Set an entry to false to disable it.

---@type dotnet.Config
M.values = {
    enabled = true,
    keymaps = {
        toggle = "<leader>ds",
        enable = false,
        disable = false,
    },
}

---@param opts? dotnet.Config
function M.apply(opts)
    M.values = vim.tbl_deep_extend("force", M.values, opts or {})
end

return M
