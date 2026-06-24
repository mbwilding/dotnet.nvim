--- Buffer rendering for the dotnet solution view.
---
--- Line format: <indent><icon><name>   (path is NOT in the buffer)
--- Paths live only in flat/state. Edit via gf (existing) or o/O (new).
--- foldmethod=manual with explicit fold ranges set after render.

local M = {}

local PROJECT_ICONS = {
    csproj  = "󰌛 ",
    fsproj  = "󰬟 ",
    vbproj  = "󰈝 ",
    esproj  = "\xEE\x98\x8C ",
    vdproj  = "󰒓 ",
    dbproj  = "󰆼 ",
    pyproj  = "󰌠 ",
    vcxproj = "󰙲 ",
    shproj  = "󰚩 ",
}

local ICONS = {
    _folder   = "󰉋 ",
    _solution = "󰘐 ",
    _item     = "󰈔 ",
    _default  = "󰈙 ",
}

local HL = {
    icon     = "DotnetSolutionIcon",
    name     = "DotnetSolutionProject",
    folder   = "DotnetSolutionFolder",
    item     = "DotnetSolutionItem",
    header   = "DotnetSolutionHeader",
    modified = "DotnetSolutionModified",
    missing  = "DotnetSolutionMissing",
}

local NS     = vim.api.nvim_create_namespace("dotnet_solution")
local INDENT = "  "

-- ---------------------------------------------------------------------------
-- Icon provider
-- ---------------------------------------------------------------------------

---@type fun(name: string): string, string
local _icon_fn = nil

local function get_icon_for_file(name)
    if not _icon_fn then
        local ok_mini, mini = pcall(require, "mini.icons")
        if ok_mini and _G.MiniIcons then
            _icon_fn = function(n)
                local icon, hl = mini.get("file", n)
                return icon .. " ", hl
            end
        else
            local ok_non, nonicons = pcall(require, "nonicons")
            if ok_non and nonicons.get_icon then
                local ok_dev, devicons = pcall(require, "nvim-web-devicons")
                _icon_fn = function(n)
                    local icon, hl = nonicons.get_icon(n)
                    if icon and icon ~= "" then return icon .. " ", hl or HL.icon end
                    if ok_dev then
                        local di, dh = devicons.get_icon(n)
                        if di and di ~= "" then return di .. " ", dh or HL.icon end
                    end
                    return ICONS._default, HL.icon
                end
            else
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
    if entry.is_solution      then return ICONS._solution, HL.header end
    if entry.is_folder        then return ICONS._folder,   HL.folder end
    if entry.is_solution_item then return ICONS._item,     HL.item   end
    local ext = entry.path and entry.path:match("%.([^%.]+)$")
    if ext and PROJECT_ICONS[ext:lower()] then
        return PROJECT_ICONS[ext:lower()], HL.icon
    end
    return get_icon_for_file(entry.name)
end

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

--- Strip leading indent + icon, return name and depth.
---@param line string
---@return string name, integer depth
local function strip_prefix(line)
    local spaces = 0
    local i = 1
    while i <= #line and line:byte(i) == 0x20 do spaces = spaces + 1; i = i + 1 end
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
    if not rel_path or rel_path == "" then return false end
    return vim.uv.fs_stat(vim.fn.fnamemodify(sln_path, ":h") .. "/" .. rel_path) ~= nil
end

-- ---------------------------------------------------------------------------
-- Decorations
-- ---------------------------------------------------------------------------

---@param bufnr integer
---@param flat table[]
local function apply_decorations(bufnr, flat)
    vim.api.nvim_buf_clear_namespace(bufnr, NS, 0, -1)

    local state = require("dotnet.state")
    local s = state.get(bufnr)
    local sln_path   = s and s.sln_path or ""
    local line_count = vim.api.nvim_buf_line_count(bufnr)

    for i, row in ipairs(flat) do
        local lnum = i - 1
        if lnum >= line_count then break end

        local e            = row.node.entry
        local indent_bytes = #INDENT * row.depth
        local icon, icon_hl = entry_icon(e)
        local buf_line     = vim.api.nvim_buf_get_lines(bufnr, lnum, lnum + 1, false)[1]
        local line_len     = #buf_line

        if line_len == 0 or indent_bytes >= line_len then goto next_row end

        -- Icon highlight
        vim.api.nvim_buf_set_extmark(bufnr, NS, lnum, indent_bytes, {
            end_col  = math.min(indent_bytes + #icon, line_len),
            hl_group = icon_hl,
            priority = 10,
        })

        -- Name highlight
        local name_col = indent_bytes + #icon
        local is_missing = not e.is_folder and not e.is_solution
            and not file_exists(sln_path, e.path)

        local name_hl
        if e.is_solution         then name_hl = HL.header
        elseif is_missing        then name_hl = HL.missing
        elseif e.is_folder       then name_hl = HL.folder
        elseif e.is_solution_item then name_hl = HL.item
        else                          name_hl = HL.name
        end

        if name_col < line_len then
            vim.api.nvim_buf_set_extmark(bufnr, NS, lnum, name_col, {
                end_col  = math.min(name_col + #e.name, line_len),
                hl_group = name_hl,
                hl_mode  = "replace",
                priority = 20,
            })
        end

        ::next_row::
    end
end

-- ---------------------------------------------------------------------------
-- Folds (manual)
-- ---------------------------------------------------------------------------

---@param bufnr integer
---@param flat table[]
local function apply_folds(bufnr, flat)
    local total = #flat
    vim.api.nvim_buf_call(bufnr, function()
        vim.cmd("silent! normal! zE")
        for i, row in ipairs(flat) do
            if row.kind == "solution" or row.kind == "folder" then
                local last = i
                for j = i + 1, total do
                    if flat[j].depth <= row.depth then break end
                    last = j
                end
                if last > i then
                    vim.cmd(string.format("silent! %d,%dfold", i, last))
                end
            end
        end
        vim.cmd("silent! normal! zR")
    end)
end

-- ---------------------------------------------------------------------------
-- Window options
-- ---------------------------------------------------------------------------

---@param winid integer
local function set_win_options(winid)
    local wo = vim.wo[winid]
    wo.wrap        = false
    wo.signcolumn  = "no"
    wo.foldcolumn  = "1"
    wo.spell       = false
    wo.list        = false
    wo.cursorline  = true
    wo.foldmethod  = "manual"
    wo.foldlevel   = 99
    wo.conceallevel = 0
end

-- ---------------------------------------------------------------------------
-- Picker helper (shared by gf and o/O)
-- ---------------------------------------------------------------------------

---@param bufnr integer
---@param sln_dir string
---@param kind "project"|"item"
---@param title string
---@param on_pick fun(rel: string)
local function open_file_picker(bufnr, sln_dir, kind, title, on_pick)
    local glob = kind == "item"
        and nil
        or "*.{csproj,fsproj,vbproj,esproj,vcxproj,pyproj,dbproj,shproj}"

    Snacks.picker.files({
        cwd     = sln_dir,
        glob    = glob,
        title   = title,
        confirm = function(picker, item)
            picker:close()
            if not item then return end
            on_pick(item.file or item.text)
        end,
    })
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
    local flat   = parser.flatten_tree(root, sln_path)

    local s = state.get(bufnr)
    if s then s.flat = flat end

    -- Buffer lines contain only: indent + icon + name  (NO path)
    local lines = {}
    for _, row in ipairs(flat) do
        local e      = row.node.entry
        local indent = string.rep(INDENT, row.depth)
        local icon   = entry_icon(e)
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

    apply_decorations(bufnr, flat)

    vim.schedule(function()
        if vim.api.nvim_buf_is_valid(bufnr) then
            apply_folds(bufnr, flat)
        end
    end)

    local aug = vim.api.nvim_create_augroup("DotnetView_" .. bufnr, { clear = true })

    vim.api.nvim_create_autocmd("CursorMoved", {
        group = aug, buffer = bufnr,
        callback = function()
            local st = state.get(bufnr)
            if st and st.flat then apply_decorations(bufnr, st.flat) end
        end,
    })

    vim.api.nvim_create_autocmd("InsertEnter", {
        group = aug, buffer = bufnr,
        callback = function()
            if vim.api.nvim_win_get_cursor(0)[1] == 1 then
                vim.schedule(function() vim.cmd("stopinsert") end)
            end
        end,
    })

    vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
        group = aug, buffer = bufnr,
        callback = function()
            local st = state.get(bufnr)
            if st and st.flat then apply_decorations(bufnr, st.flat) end
        end,
    })
end

-- Stub — not used with foldmethod=manual
function M.foldexpr(_) return "0" end

-- ---------------------------------------------------------------------------
-- parse_buffer
-- ---------------------------------------------------------------------------
-- Path is NOT read from buffer text — only name is.
-- Path comes from orig_row.node.entry.path (preserved from flat).
-- kind is determined from the icon on the line.

---@param bufnr integer
---@param original_flat table[]
---@return table|nil root_node
function M.parse_buffer(bufnr, original_flat)
    if not original_flat or #original_flat == 0 then return nil end

    local candidates = {}
    for _, row in ipairs(original_flat) do
        if row.kind ~= "solution" then
            local key = row.kind .. ":" .. row.node.entry.name
            if not candidates[key] then candidates[key] = {} end
            table.insert(candidates[key], row)
        end
    end
    local consumed = {}

    local root  = { entry = nil, children = {} }
    local stack = { { node = root, depth = 0 } }

    for idx, line in ipairs(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)) do
        if idx == 1 then goto continue end

        local name, depth = strip_prefix(line)
        if name == "" then goto continue end

        while #stack > 1 and stack[#stack].depth >= depth do
            table.remove(stack)
        end
        local parent = stack[#stack].node

        -- Detect kind from icon bytes
        local line_kind
        do
            local i2 = 1
            while i2 <= #line and line:byte(i2) == 0x20 do i2 = i2 + 1 end
            local rest = line:sub(i2)
            if     rest:sub(1, #ICONS._solution) == ICONS._solution then line_kind = "solution"
            elseif rest:sub(1, #ICONS._folder)   == ICONS._folder   then line_kind = "folder"
            elseif rest:sub(1, #ICONS._item)     == ICONS._item     then line_kind = "item"
            else                                                          line_kind = "project"
            end
        end

        -- Positional match (kind must agree — rename is fine, shift is not)
        local orig_row = original_flat[idx]
        if orig_row and orig_row.kind ~= line_kind then orig_row = nil end

        -- Name+kind fallback for shifted/pasted lines
        if not orig_row then
            local key = line_kind .. ":" .. name
            local n   = consumed[key] or 0
            if candidates[key] and candidates[key][n + 1] then
                orig_row      = candidates[key][n + 1]
                consumed[key] = n + 1
            end
        end

        local node
        if orig_row then
            local entry = orig_row.node.entry
            -- Only copy if name changed (path always preserved from entry)
            if name ~= entry.name then
                entry = vim.deepcopy(entry)
                entry.name = name
            end
            node = { entry = entry, children = {} }
        else
            -- New entry — path is empty until user sets it via gf
            if line_kind == "folder" then
                node = { entry = { name = name, path = name,
                    type_guid = "2150E333-8FDC-42A3-9474-1A3956D46DE8",
                    id = nil, is_folder = true }, children = {} }
            elseif line_kind == "item" then
                node = { entry = { name = name, path = "",
                    is_solution_item = true, is_folder = false }, children = {} }
            else
                node = { entry = { name = name, path = "",
                    type_guid = nil, id = nil, is_folder = false }, children = {} }
            end
        end

        table.insert(parent.children, node)
        table.insert(stack, { node = node, depth = depth })

        ::continue::
    end

    return root
end

-- ---------------------------------------------------------------------------
-- Highlights
-- ---------------------------------------------------------------------------

function M.setup_highlights()
    local defs = {
        [HL.icon]     = { link = "Function" },
        [HL.name]     = { link = "Normal" },
        [HL.folder]   = { link = "Directory" },
        [HL.item]     = { link = "Comment" },
        [HL.header]   = { fg = 0x9B4FBA, bold = true },
        [HL.modified] = { link = "DiagnosticWarn" },
        [HL.missing]  = { link = "DiagnosticError" },
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

    -- Block insert on solution root line (line 1)
    for _, key in ipairs({ "i", "I", "a", "A", "s", "S", "c", "C", "r", "R" }) do
        vim.keymap.set("n", key, function()
            if vim.api.nvim_win_get_cursor(0)[1] == 1 then return end
            vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(key, true, false, true), "n", false)
        end, opts)
    end

    -- o/O: open picker to add a new project below/above current line
    for _, key in ipairs({ "o", "O" }) do
        vim.keymap.set("n", key, function()
            local state = require("dotnet.state")
            local s = state.get(bufnr)
            if not s or not s.flat then return end
            local lnum = vim.api.nvim_win_get_cursor(0)[1]

            -- O on line 1 makes no sense (nothing above the solution root)
            if lnum == 1 and key == "O" then return end

            local buf_insert  = key == "o" and lnum or lnum - 1
            local flat_insert = key == "o" and lnum + 1 or lnum

            -- Infer depth from the adjacent line; solution root → depth 1
            local ref_idx = key == "o" and lnum + 1 or lnum - 1
            local ref_row = s.flat[ref_idx]
            local depth
            if lnum == 1 then
                depth = 1  -- inserting directly under the solution root
            else
                depth = ref_row and ref_row.depth or (s.flat[lnum] and s.flat[lnum].depth or 1)
            end

            local sln_dir = vim.fn.fnamemodify(s.sln_path, ":h")
            open_file_picker(bufnr, sln_dir, "project", "Add project", function(rel)
                local name    = rel:match("([^/\\]+)$") or rel
                local ext     = rel:match("%.([^%.]+)$")
                local is_item = not (ext and PROJECT_ICONS[ext:lower()])
                local new_entry = {
                    name             = name,
                    path             = rel,
                    type_guid        = nil,
                    id               = nil,
                    is_folder        = false,
                    is_solution_item = is_item,
                }
                local icon     = entry_icon(new_entry)
                local new_line = string.rep(INDENT, depth) .. icon .. name

                vim.bo[bufnr].modifiable = true
                vim.api.nvim_buf_set_lines(bufnr, buf_insert, buf_insert, false, { new_line })
                vim.bo[bufnr].modified   = true
                vim.bo[bufnr].modifiable = true

                table.insert(s.flat, flat_insert, {
                    node  = { entry = new_entry, children = {} },
                    depth = depth,
                    kind  = is_item and "item" or "project",
                })
                apply_decorations(bufnr, s.flat)
                vim.api.nvim_win_set_cursor(0, { buf_insert + 1, 0 })
            end)
        end, opts)
    end

    -- <CR>: open project/item or toggle fold
    vim.keymap.set("n", "<CR>", function()
        local state = require("dotnet.state")
        local s = state.get(bufnr)
        if not s or not s.flat then return end
        local lnum = vim.api.nvim_win_get_cursor(0)[1]
        local row  = s.flat[lnum]
        if not row then return end
        local e = row.node.entry
        if e.is_solution or e.is_folder then
            vim.cmd("normal! za")
        elseif e.path and e.path ~= "" then
            vim.cmd.edit(vim.fn.fnameescape(vim.fn.fnamemodify(s.sln_path, ":h") .. "/" .. e.path))
        else
            vim.notify("[dotnet] No path set — use gf to pick a file", vim.log.levels.WARN)
        end
    end, opts)

    -- dd: fold-aware delete, splices flat immediately
    vim.keymap.set("n", "dd", function()
        local state = require("dotnet.state")
        local s = state.get(bufnr)
        if not s or not s.flat then vim.cmd("normal! dd"); return end
        local lnum = vim.api.nvim_win_get_cursor(0)[1]
        if lnum == 1 then return end
        local row = s.flat[lnum]

        local first, last = lnum, lnum
        if row and (row.kind == "folder" or row.kind == "solution") then
            local fold_end = vim.fn.foldclosedend(lnum)
            if fold_end ~= -1 then
                last = fold_end
            else
                local depth = row.depth
                for i = lnum + 1, #s.flat do
                    if s.flat[i].depth <= depth then break end
                    last = i
                end
            end
            vim.cmd(first .. "," .. last .. "d _")
        else
            vim.cmd("normal! dd")
        end

        for _ = first, last do table.remove(s.flat, first) end
        apply_decorations(bufnr, s.flat)
    end, opts)

    -- gf: pick/update path for entry under cursor
    vim.keymap.set("n", "gf", function()
        local state = require("dotnet.state")
        local s = state.get(bufnr)
        if not s or not s.flat then return end
        local lnum = vim.api.nvim_win_get_cursor(0)[1]
        local row  = s.flat[lnum]
        if not row or row.kind == "solution" or row.kind == "folder" then return end

        local sln_dir = vim.fn.fnamemodify(s.sln_path, ":h")
        open_file_picker(bufnr, sln_dir, row.kind, "Path for " .. row.node.entry.name,
            function(rel)
                local e    = row.node.entry
                e.path = rel
                e.name = rel:match("([^/\\]+)$") or rel

                -- Rewrite buffer line with updated icon and name
                local indent   = string.rep(INDENT, row.depth)
                local icon     = entry_icon(e)
                vim.bo[bufnr].modifiable = true
                vim.api.nvim_buf_set_lines(bufnr, lnum - 1, lnum, false,
                    { indent .. icon .. e.name })
                vim.bo[bufnr].modified   = true
                vim.bo[bufnr].modifiable = true

                local st = state.get(bufnr)
                if st and st.flat then apply_decorations(bufnr, st.flat) end
            end)
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
