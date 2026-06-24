--- Buffer rendering for the dotnet solution view.
---
--- One line per tree row, indented by depth * 2 spaces.
--- Folders fold via foldmethod=manual with explicit fold ranges set after render.
--- Solution items render as dimmed leaves; they cannot be folded.
---
--- Moving entries: cut lines with dd (fold-aware for folders), paste at the
--- desired indent level. parse_buffer reconstructs the full tree from
--- indentation on :w.

local M = {}

local ICONS = {
    _folder   = "󰉋 ",
    _solution = "󰘐 ",
    _item     = "󰈙 ",
    _default  = "󰈙 ",
}

local HL = {
    icon     = "DotnetSolutionIcon",
    name     = "DotnetSolutionProject",
    path     = "DotnetSolutionPath",
    folder   = "DotnetSolutionFolder",
    item     = "DotnetSolutionItem",
    header   = "DotnetSolutionHeader",
    modified = "DotnetSolutionModified",
    missing  = "DotnetSolutionMissing",
}

local NS = vim.api.nvim_create_namespace("dotnet_solution")
local INDENT = "  "

-- ---------------------------------------------------------------------------
-- Icon provider (mirrors canola's priority: MiniIcons > nonicons+devicons > devicons)
-- ---------------------------------------------------------------------------

---@type fun(name: string): string, string  Returns icon, hl_group
local _icon_fn = nil

local function get_icon_for_file(name)
    if not _icon_fn then
        -- Try MiniIcons first
        local ok_mini, mini = pcall(require, "mini.icons")
        if ok_mini and _G.MiniIcons then
            _icon_fn = function(n) return mini.get("file", n) end
        else
            -- Try nonicons + optional devicons fallback
            local ok_non, nonicons = pcall(require, "nonicons")
            if ok_non and nonicons.get_icon then
                local ok_dev, devicons = pcall(require, "nvim-web-devicons")
                _icon_fn = function(n)
                    local icon, hl = nonicons.get_icon(n)
                    if icon and icon ~= "" then return icon, hl or HL.icon end
                    if ok_dev then
                        local di, dh = devicons.get_icon(n)
                        if di and di ~= "" then return di, dh or HL.icon end
                    end
                    return ICONS._default, HL.icon
                end
            else
                -- devicons only
                local ok_dev, devicons = pcall(require, "nvim-web-devicons")
                if ok_dev then
                    _icon_fn = function(n)
                        local icon, hl = devicons.get_icon(n)
                        if icon and icon ~= "" then return icon .. " ", hl or HL.icon end
                        return ICONS._default, HL.icon
                    end
                else
                    _icon_fn = function(_) return ICONS._default, HL.icon end
                end
            end
        end
    end
    return _icon_fn(name)
end

---@param entry table
---@return string icon, string hl
local function entry_icon(entry)
    if entry.is_solution then return ICONS._solution, HL.header end
    if entry.is_folder   then return ICONS._folder, HL.folder end
    if entry.is_solution_item then
        local icon, hl = get_icon_for_file(entry.name)
        return icon, hl
    end
    -- Real project: get icon from filename
    local icon, hl = get_icon_for_file(entry.name)
    return icon, hl
end

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

--- Strip leading indent spaces + multi-byte icon, return name and depth.
---@param line string
---@return string name, integer depth
local function strip_prefix(line)
    local spaces = 0
    local i = 1
    while i <= #line and line:byte(i) == 0x20 do
        spaces = spaces + 1
        i = i + 1
    end
    local depth = math.floor(spaces / #INDENT)
    while i <= #line do
        local b = line:byte(i)
        if b >= 0x21 and b <= 0x7E then break end
        if b < 0x80 then i = i + 1
        elseif b >= 0xF0 then i = i + 4
        elseif b >= 0xE0 then i = i + 3
        elseif b >= 0xC0 then i = i + 2
        else i = i + 1 end
    end
    return vim.trim(line:sub(i)), depth
end

---@param sln_path string
---@param rel_path string
---@return boolean
local function file_exists(sln_path, rel_path)
    if rel_path == "" then return false end
    return vim.uv.fs_stat(vim.fn.fnamemodify(sln_path, ":h") .. "/" .. rel_path) ~= nil
end

-- ---------------------------------------------------------------------------
-- Decorations
-- ---------------------------------------------------------------------------

---@param bufnr integer
---@param flat table[]
---@param cursor_lnum integer 1-indexed
local function apply_decorations(bufnr, flat, cursor_lnum)
    vim.api.nvim_buf_clear_namespace(bufnr, NS, 0, -1)

    local state = require("dotnet.state")
    local cfg   = require("dotnet.config")
    local s = state.get(bufnr)
    local path_on_cursor_only = cfg.values.path_on_cursor_only
    local sln_path = s and s.sln_path or ""

    for i, row in ipairs(flat) do
        local lnum = i - 1
        local e = row.node.entry
        local indent_bytes = #INDENT * row.depth
        local icon, icon_hl = entry_icon(e)

        vim.api.nvim_buf_set_extmark(bufnr, NS, lnum, indent_bytes, {
            end_col  = indent_bytes + #icon,
            hl_group = icon_hl,
            priority = 10,
        })

        local name_col = indent_bytes + #icon
        local is_missing = false
        if not e.is_folder and not e.is_solution then
            is_missing = not file_exists(sln_path, e.path)
        end

        local name_hl
        if e.is_solution then
            name_hl = HL.header
        elseif is_missing then
            name_hl = HL.missing
        elseif e.is_solution_item then
            name_hl = HL.item
        elseif e.is_folder then
            name_hl = HL.folder
        else
            name_hl = HL.name
        end

        vim.api.nvim_buf_set_extmark(bufnr, NS, lnum, name_col, {
            end_col  = name_col + #e.name,
            hl_group = name_hl,
            priority = 10,
        })

        if not e.is_folder and not e.is_solution then
            local show_path = not path_on_cursor_only or (i == cursor_lnum)
            if show_path then
                local path_hl = is_missing and HL.missing or (e.is_solution_item and HL.item or HL.path)
                vim.api.nvim_buf_set_extmark(bufnr, NS, lnum, 0, {
                    virt_text     = { { "  " .. e.path, path_hl } },
                    virt_text_pos = "eol",
                    priority      = 5,
                })
            end
        end
    end
end

-- ---------------------------------------------------------------------------
-- Folds
-- ---------------------------------------------------------------------------

--- Set manual folds for every folder node with children.
--- foldmethod=manual means these never recalculate spontaneously.
---@param bufnr integer
---@param flat table[]
local function apply_folds(bufnr, flat)
    -- Build a map: line number -> last line of its subtree
    -- A folder at line L owns lines L+1 .. L+N where N = all descendants
    local total = #flat

    -- For each folder line, find the last line that belongs to it
    -- (i.e. the last line whose depth > folder depth, contiguous)
    vim.api.nvim_buf_call(bufnr, function()
        -- Must be in a window context; use the first window showing this buf
        vim.cmd("silent! normal! zE") -- wipe existing manual folds

        for i, row in ipairs(flat) do
            if row.node.entry.is_folder or row.kind == "solution" then
                local folder_depth = row.depth
                local last = i
                for j = i + 1, total do
                    if flat[j].depth <= folder_depth then break end
                    last = j
                end
                if last > i then
                    -- Create fold from line i to last (1-indexed)
                    vim.cmd(string.format("silent! %d,%dfold", i, last))
                end
            end
        end

        vim.cmd("silent! normal! zR") -- open all folds (foldlevel=99 equivalent)
    end)
end

-- ---------------------------------------------------------------------------
-- Window options
-- ---------------------------------------------------------------------------

---@param winid integer
local function set_win_options(winid)
    local wo = vim.wo[winid]
    wo.wrap         = false
    wo.signcolumn   = "no"
    wo.foldcolumn   = "1"
    wo.spell        = false
    wo.list         = false
    wo.cursorline   = true
    wo.foldmethod   = "manual"
    wo.foldlevel    = 99
    wo.conceallevel = 0
end

-- ---------------------------------------------------------------------------
-- Render
-- ---------------------------------------------------------------------------

---@param bufnr integer
---@param sln_path string
---@param root table
function M.render(bufnr, sln_path, root)
    local parser = require("dotnet.parser")
    local state  = require("dotnet.state")
    local flat = parser.flatten_tree(root, sln_path)

    -- Set flat before writing lines so anything that reads it during redraw
    -- (e.g. foldexpr if still active) sees valid data
    local s = state.get(bufnr)
    if s then s.flat = flat end

    local lines = {}
    for _, row in ipairs(flat) do
        local e = row.node.entry
        local indent = string.rep(INDENT, row.depth)
        local icon = entry_icon(e)
        table.insert(lines, indent .. icon .. e.name)
    end

    vim.bo[bufnr].modifiable = true
    vim.bo[bufnr].readonly   = false
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
    vim.bo[bufnr].modified   = false
    vim.bo[bufnr].modifiable = true

    if vim.api.nvim_buf_line_count(bufnr) == 0 then
        vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "" })
        vim.bo[bufnr].modified = false
    end

    local cursor_lnum = vim.api.nvim_win_get_cursor(0)[1]
    apply_decorations(bufnr, flat, cursor_lnum)

    -- Apply folds after the buffer content is settled
    vim.schedule(function()
        if not vim.api.nvim_buf_is_valid(bufnr) then return end
        apply_folds(bufnr, flat)
    end)

    local aug = vim.api.nvim_create_augroup("DotnetView_" .. bufnr, { clear = true })

    vim.api.nvim_create_autocmd("CursorMoved", {
        group  = aug,
        buffer = bufnr,
        callback = function()
            local st = state.get(bufnr)
            if not st or not st.flat then return end
            apply_decorations(bufnr, st.flat, vim.api.nvim_win_get_cursor(0)[1])
        end,
    })

    -- Safety net: block insert on line 1
    vim.api.nvim_create_autocmd("InsertEnter", {
        group  = aug,
        buffer = bufnr,
        callback = function()
            if vim.api.nvim_win_get_cursor(0)[1] == 1 then
                vim.schedule(function() vim.cmd("stopinsert") end)
            end
        end,
    })

    -- TextChanged: only refresh decorations, never re-apply folds
    -- (folds are manual and survive text changes)
    vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
        group  = aug,
        buffer = bufnr,
        callback = function()
            local st = state.get(bufnr)
            if not st or not st.flat then return end
            apply_decorations(bufnr, st.flat, vim.api.nvim_win_get_cursor(0)[1])
        end,
    })
end

-- ---------------------------------------------------------------------------
-- Foldexpr (kept for compatibility but not used with foldmethod=manual)
-- ---------------------------------------------------------------------------

function M.foldexpr(_) return "0" end

-- ---------------------------------------------------------------------------
-- parse_buffer
-- ---------------------------------------------------------------------------

--- Reconstruct the full tree from indented buffer lines.
--- Line 1 is the solution row — skip it.
---@param bufnr integer
---@param original_flat table[]
---@return table root_node
function M.parse_buffer(bufnr, original_flat)
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

    local orig_by_name = {}
    for _, row in ipairs(original_flat) do
        if row.kind ~= "solution" then
            local name = row.node.entry.name
            if not orig_by_name[name] then orig_by_name[name] = {} end
            table.insert(orig_by_name[name], row)
        end
    end
    local orig_consumed = {}

    local root = { entry = nil, children = {} }
    local stack = { { node = root, depth = 0 } }

    for idx, line in ipairs(lines) do
        if idx == 1 then goto continue end -- solution root line

        local name, depth = strip_prefix(line)
        if name == "" then goto continue end

        while #stack > 1 and stack[#stack].depth >= depth do
            table.remove(stack)
        end
        local parent = stack[#stack].node

        local orig_row
        local consumed_count = orig_consumed[name] or 0
        local candidates = orig_by_name[name]
        if candidates and candidates[consumed_count + 1] then
            orig_row = candidates[consumed_count + 1]
            orig_consumed[name] = consumed_count + 1
        end

        local node
        if orig_row then
            node = { entry = orig_row.node.entry, children = {} }
        else
            local is_item   = line:find(ICONS._item,   1, true) ~= nil
            local is_folder = line:find(ICONS._folder, 1, true) ~= nil
            node = {
                entry = {
                    name             = name,
                    path             = name,
                    type_guid        = is_folder and "2150E333-8FDC-42A3-9474-1A3956D46DE8" or nil,
                    id               = nil,
                    is_folder        = is_folder,
                    is_solution_item = is_item,
                },
                children = {},
            }
        end

        table.insert(parent.children, node)

        if not node.entry.is_solution_item then
            table.insert(stack, { node = node, depth = depth })
        end

        ::continue::
    end

    return root
end

-- ---------------------------------------------------------------------------
-- Highlights
-- ---------------------------------------------------------------------------

function M.setup_highlights()
    local err_fg = vim.api.nvim_get_hl(0, { name = "DiagnosticError" }).fg
    local defs = {
        [HL.icon]     = { link = "Function" },
        [HL.name]     = { link = "Normal" },
        [HL.path]     = { link = "Comment" },
        [HL.folder]   = { link = "Directory" },
        [HL.item]     = { link = "Comment" },
        [HL.header]   = { fg = 0x9B4FBA, bold = true },
        [HL.modified] = { link = "DiagnosticWarn" },
        [HL.missing]  = { undercurl = true, sp = err_fg, fg = err_fg },
    }
    for name, opts in pairs(defs) do
        vim.api.nvim_set_hl(0, name, vim.tbl_extend("keep", { default = true }, opts))
    end
end

-- ---------------------------------------------------------------------------
-- Keymaps
-- ---------------------------------------------------------------------------

---@param bufnr integer
function M.setup_keymaps(bufnr)
    local opts = { buffer = bufnr, silent = true, noremap = true }

    -- Block insert-entry keys on line 1
    for _, key in ipairs({ "i", "I", "a", "A", "o", "O", "s", "S", "c", "C", "r", "R" }) do
        vim.keymap.set("n", key, function()
            if vim.api.nvim_win_get_cursor(0)[1] == 1 then return end
            vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(key, true, false, true), "n", false)
        end, opts)
    end

    vim.keymap.set("n", "<CR>", function()
        local state = require("dotnet.state")
        local s = state.get(bufnr)
        if not s or not s.flat then return end
        local lnum = vim.api.nvim_win_get_cursor(0)[1]
        local row = s.flat[lnum]
        if not row then return end
        local e = row.node.entry
        if e.is_solution or e.is_folder then
            vim.cmd("normal! za")
        else
            local base = vim.fn.fnamemodify(s.sln_path, ":h")
            vim.cmd.edit(vim.fn.fnameescape(base .. "/" .. e.path))
        end
    end, opts)

    vim.keymap.set("n", "dd", function()
        local state = require("dotnet.state")
        local s = state.get(bufnr)
        if not s or not s.flat then
            vim.cmd("normal! dd")
            return
        end
        local lnum = vim.api.nvim_win_get_cursor(0)[1]
        if lnum == 1 then return end
        local row = s.flat[lnum]
        if row and row.node.entry.is_folder then
            local fold_end = vim.fn.foldclosedend(lnum)
            if fold_end ~= -1 then
                vim.cmd(lnum .. "," .. fold_end .. "d _")
            else
                local depth = row.depth
                local last = lnum
                for i = lnum + 1, #s.flat do
                    if s.flat[i].depth <= depth then break end
                    last = i
                end
                vim.cmd(lnum .. "," .. last .. "d _")
            end
        else
            vim.cmd("normal! dd")
        end
        local st = state.get(bufnr)
        if st then st.flat = nil end
    end, opts)

    vim.keymap.set("n", "q", "<CMD>bdelete<CR>", opts)

    vim.keymap.set("n", "gp", function()
        local state = require("dotnet.state")
        local s = state.get(bufnr)
        if s then vim.cmd.edit(vim.fn.fnameescape(s.sln_path)) end
    end, opts)

    vim.keymap.set("n", "<C-r>", function()
        local state = require("dotnet.state")
        local s = state.get(bufnr)
        if s then require("dotnet").load_buffer(bufnr, s.sln_path) end
    end, opts)
end

function M.apply_win_options()
    set_win_options(vim.api.nvim_get_current_win())
end

return M
