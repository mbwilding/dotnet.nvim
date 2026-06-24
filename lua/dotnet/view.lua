--- Buffer rendering for the dotnet solution view.
---
--- One line per tree node, indented by depth.
--- Folders are foldable via foldmethod=indent (native Neovim folds).
--- Project paths are shown as dimmed EOL virtual text.

local M = {}

local ICONS = {
    csproj    = "󰌛 ",
    fsproj    = "󰬟 ",
    vbproj    = "󰈝 ",
    esproj    = "󰌚 ",
    _folder   = " ",
    _solution = "󰘐 ",
    _default  = " ",
}

local HL = {
    icon     = "DotnetSolutionIcon",
    name     = "DotnetSolutionProject",
    path     = "DotnetSolutionPath",
    folder   = "DotnetSolutionFolder",
    header   = "DotnetSolutionHeader",
    modified = "DotnetSolutionModified",
}

local NS = vim.api.nvim_create_namespace("dotnet_solution")

-- Two spaces per indent level
local INDENT = "  "

---@param entry table
---@return string icon, string hl
local function entry_icon(entry)
    local parser = require("dotnet.parser")
    if entry.is_folder then
        return ICONS._folder, HL.folder
    end
    local t = parser.project_type(entry.type_guid, entry.path)
    return (ICONS[t] or ICONS._default), HL.icon
end

--- Strip the leading indent + icon bytes from a buffer line, returning just the name.
--- Works by scanning past non-ASCII (icon) bytes and leading spaces.
---@param line string
---@return string name, integer depth
local function strip_prefix(line)
    -- Count indent depth (each level = #INDENT spaces)
    local spaces = 0
    local i = 1
    while i <= #line and line:byte(i) == 0x20 do
        spaces = spaces + 1
        i = i + 1
    end
    local depth = math.floor(spaces / #INDENT)

    -- Skip multi-byte icon + trailing space
    while i <= #line do
        local b = line:byte(i)
        if b >= 0x21 and b <= 0x7E then
            break -- first ASCII printable = start of name
        elseif b < 0x80 then
            i = i + 1
        elseif b >= 0xF0 then
            i = i + 4
        elseif b >= 0xE0 then
            i = i + 3
        elseif b >= 0xC0 then
            i = i + 2
        else
            i = i + 1
        end
    end

    return vim.trim(line:sub(i)), depth
end

--- Apply extmark highlights and virtual path text for all rendered rows.
---@param bufnr integer
---@param flat table[]  { node, depth } list matching buffer lines 1-N
local function apply_decorations(bufnr, flat)
    vim.api.nvim_buf_clear_namespace(bufnr, NS, 0, -1)

    -- Re-anchor the header virt_line above row 0
    local state = require("dotnet.state")
    local s = state.get(bufnr)
    if s then
        local parser = require("dotnet.parser")
        local fmt_labels = { sln = ".sln", slnx = ".slnx", slnf = ".slnf" }
        local sln_name = vim.fn.fnamemodify(s.sln_path, ":t")
        local header = ICONS._solution .. sln_name .. "  " .. (fmt_labels[s.fmt] or "")
        vim.api.nvim_buf_set_extmark(bufnr, NS, 0, 0, {
            virt_lines_above = true,
            virt_lines = { { { header, HL.header } } },
        })
    end

    for i, item in ipairs(flat) do
        local lnum = i - 1 -- 0-indexed
        local e = item.node.entry
        local indent_bytes = #INDENT * item.depth
        local icon, icon_hl = entry_icon(e)

        -- Icon highlight
        vim.api.nvim_buf_set_extmark(bufnr, NS, lnum, indent_bytes, {
            end_col = indent_bytes + #icon,
            hl_group = icon_hl,
            priority = 10,
        })

        -- Name highlight
        local name_col = indent_bytes + #icon
        local name_hl = e.is_folder and HL.folder or HL.name
        vim.api.nvim_buf_set_extmark(bufnr, NS, lnum, name_col, {
            end_col = name_col + #e.name,
            hl_group = name_hl,
            priority = 10,
        })

        -- Path as EOL virtual text (projects only)
        if not e.is_folder then
            vim.api.nvim_buf_set_extmark(bufnr, NS, lnum, 0, {
                virt_text = { { "  " .. e.path, HL.path } },
                virt_text_pos = "eol",
                priority = 5,
            })
        end
    end
end

--- Set up window-local options.
---@param winid integer
local function set_win_options(winid)
    local wo = vim.wo[winid]
    wo.wrap        = false
    wo.signcolumn  = "no"
    wo.foldcolumn  = "0"
    wo.spell       = false
    wo.list        = false
    wo.cursorline  = true
    wo.foldmethod  = "indent"
    wo.foldlevel   = 99 -- start fully expanded
    wo.conceallevel = 0
end

--- Render the buffer from a flattened tree.
---@param bufnr integer
---@param sln_path string
---@param root table  Root tree node from parser
function M.render(bufnr, sln_path, root)
    local parser = require("dotnet.parser")
    local flat = parser.flatten_tree(root)

    local lines = {}
    for _, item in ipairs(flat) do
        local e = item.node.entry
        local indent = string.rep(INDENT, item.depth)
        local icon = entry_icon(e)
        table.insert(lines, indent .. icon .. e.name)
    end

    vim.bo[bufnr].modifiable = true
    vim.bo[bufnr].readonly   = false
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
    vim.bo[bufnr].modified   = false
    vim.bo[bufnr].modifiable = true

    -- Need at least one line for extmark anchoring
    if vim.api.nvim_buf_line_count(bufnr) == 0 then
        vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "" })
        vim.bo[bufnr].modified = false
    end

    apply_decorations(bufnr, flat)

    -- Store flat on state so keymaps can look up by line number
    local state = require("dotnet.state")
    local s = state.get(bufnr)
    if s then
        s.flat = flat
    end

    -- Refresh decorations live while editing (icon updates, etc.)
    vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
        group = vim.api.nvim_create_augroup("DotnetView_" .. bufnr, { clear = true }),
        buffer = bufnr,
        callback = function()
            local st = state.get(bufnr)
            if st and st.flat then
                apply_decorations(bufnr, st.flat)
            end
        end,
    })
end

--- Parse the current buffer back into a tree.
--- Only renames are honoured; structure (nesting) is preserved from state.
--- Returns the modified root node.
---@param bufnr integer
---@param root table  Original root node
---@param flat table[]  Original flat list (same order as buffer lines)
---@return table root
function M.parse_buffer(bufnr, root, flat)
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

    -- Walk lines and patch names in-place on the existing nodes
    for i, line in ipairs(lines) do
        local item = flat[i]
        if item then
            local name = strip_prefix(line)
            if name ~= "" then
                item.node.entry.name = name
            end
        end
    end

    return root
end

--- Initialise highlight groups.
function M.setup_highlights()
    local defs = {
        [HL.icon]     = { link = "Function" },
        [HL.name]     = { link = "Normal" },
        [HL.path]     = { link = "Comment" },
        [HL.folder]   = { link = "Directory" },
        [HL.header]   = { link = "Title" },
        [HL.modified] = { link = "DiagnosticWarn" },
    }
    for name, opts in pairs(defs) do
        vim.api.nvim_set_hl(0, name, vim.tbl_extend("keep", { default = true }, opts))
    end
end

--- Set up buffer-local keymaps.
---@param bufnr integer
function M.setup_keymaps(bufnr)
    local opts = { buffer = bufnr, silent = true, noremap = true }

    -- <CR>: open project file, or toggle fold for folders
    vim.keymap.set("n", "<CR>", function()
        local state = require("dotnet.state")
        local s = state.get(bufnr)
        if not s or not s.flat then return end
        local lnum = vim.api.nvim_win_get_cursor(0)[1]
        local item = s.flat[lnum]
        if not item then return end
        if item.node.entry.is_folder then
            vim.cmd("normal! za")
        else
            local full = vim.fn.fnamemodify(s.sln_path, ":h") .. "/" .. item.node.entry.path
            vim.cmd.edit(vim.fn.fnameescape(full))
        end
    end, opts)

    -- q: close
    vim.keymap.set("n", "q", "<CMD>bdelete<CR>", opts)

    -- gp: open the raw solution file
    vim.keymap.set("n", "gp", function()
        local state = require("dotnet.state")
        local s = state.get(bufnr)
        if s then vim.cmd.edit(vim.fn.fnameescape(s.sln_path)) end
    end, opts)

    -- <C-r>: reload from disk
    vim.keymap.set("n", "<C-r>", function()
        local state = require("dotnet.state")
        local s = state.get(bufnr)
        if s then require("dotnet").load_buffer(bufnr, s.sln_path) end
    end, opts)
end

--- Apply window options to the current window.
function M.apply_win_options()
    set_win_options(vim.api.nvim_get_current_win())
end

return M
