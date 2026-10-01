local M = {}

---@class dotnet.KeymapsConfig
---@field toggle? string|false Toggle the solution view (default: "<leader>ds")
---@field enable? string|false Enable interception of .sln/.slnx/.slnf files (default: false)
---@field disable? string|false Disable interception of .sln/.slnx/.slnf files (default: false)
---@field packages? string|false Open the NuGet packages view for the solution or csproj (default: "<leader>dp")

---@class dotnet.Config
---@field enabled? boolean Whether the solution view intercepts .sln/.slnx/.slnf files (default: true)
---@field prerelease? boolean Include prerelease versions in the packages view: updates, search and version picker (default: false)
---@field keymaps? dotnet.KeymapsConfig Global keybinds. Set an entry to false to disable it.

---@type dotnet.Config
M.values = {
    enabled = true,
    prerelease = false,
    keymaps = {
        toggle = "<leader>ds",
        enable = false,
        disable = false,
        packages = "<leader>dp",
    },
}

---@param opts? dotnet.Config
function M.apply(opts)
    M.values = vim.tbl_deep_extend("force", M.values, opts or {})
end

return M
