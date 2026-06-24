--- Buffer rendering for the dotnet solution view.
---
--- Line format:
---   Solution/folder:  <indent><icon><name>
---   Project/item:     <indent><icon><name>  <path>
---
--- flat[i].kind is authoritative for existing lines.
--- New lines (pasted or typed) infer kind from path extension.
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
    path     = "DotnetSolutionPath",
    folder   = "DotnetSolutionFolder",
    item     = "DotnetSolutionItem",
    header   = "DotnetSolutionHeader",
    modified = "DotnetSolutionModified",
    missing  = "DotnetSolutionMissing",
}

local NS     = vim.api.nvim_create_namespace("dotnet_solution")
local INDENT = "  "
local SEP    = "  "  -- two-space separator between name and path

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
    if entry.is_solution      then return ICONS._solution, HL.header  end
    if entry.is_folder        then return ICONS._folder,   HL.folder  end
    if entry.is_solution_item then return ICONS._item,     HL.item    end
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
---@param cursor_lnum integer 1-indexed
---@param show_paths boolean  true = reveal paths (insert mode), false = conceal (normal mode)
local function apply_decorations(bufnr, flat, cursor_lnum, show_paths)
    vim.api.nvim_buf_clear_namespace(bufnr, NS, 0, -1)

    local state = require("dotnet.state")
    local s = state.get(bufnr)
    local sln_path  = s and s.sln_path or ""
    local line_count = vim.api.nvim_buf_line_count(bufnr)

    for i, row in ipairs(flat) do
        local lnum = i - 1
        if lnum >= line_count then break end

        local e            = row.node.entry
        local indent_bytes = #INDENT * row.depth
        local icon, icon_hl = entry_icon(e)
        local buf_line     = vim.api.nvim_buf_get_lines(bufnr, lnum, lnum + 1, false)[1]
        local line_len     = #buf_line

        -- Icon
        vim.api.nvim_buf_set_extmark(bufnr, NS, lnum, indent_bytes, {
            end_col  = math.min(indent_bytes + #icon, line_len),
            hl_group = icon_hl,
            priority = 10,
        })

        local name_col  = indent_bytes + #icon
        local is_missing = not e.is_folder and not e.is_solution
            and not file_exists(sln_path, e.path)

        -- Name
        local name_hl
        if e.is_solution    then name_hl = HL.header
        elseif is_missing   then name_hl = HL.missing
        elseif e.is_folder  then name_hl = HL.folder
        elseif e.is_solution_item then name_hl = HL.item
        else                     name_hl = HL.name
        end

        if name_col < line_len then
            vim.api.nvim_buf_set_extmark(bufnr, NS, lnum, name_col, {
                end_col  = math.min(name_col + #e.name, line_len),
                hl_group = name_hl,
                hl_mode  = "replace",
                priority = 20,
            })
        end

        -- Path: concealed in normal mode, revealed in insert mode.
        -- Missing files are always shown (red) regardless of mode.
        if not e.is_folder and not e.is_solution then
            local sep_col  = name_col + #e.name
            local path_col = sep_col + #SEP
            if path_col < line_len then
                local path_hl = is_missing and HL.missing
                    or (e.is_solution_item and HL.item or HL.path)
                if show_paths or is_missing then
                    vim.api.nvim_buf_set_extmark(bufnr, NS, lnum, sep_col, {
                        end_col  = line_len,
                        hl_group = path_hl,
                        hl_mode  = "replace",
                        priority = 15,
                    })
                else
                    vim.api.nvim_buf_set_extmark(bufnr, NS, lnum, sep_col, {
                        end_col  = line_len,
                        conceal  = "",
                        priority = 15,
                    })
                end
            end
        end
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
                local folder_depth = row.depth
                local last = i
                for j = i + 1, total do
                    if flat[j].depth <= folder_depth then break end
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
    wo.wrap         = false
    wo.signcolumn   = "no"
    wo.foldcolumn   = "1"
    wo.spell        = false
    wo.list         = false
    wo.cursorline   = true
    wo.foldmethod   = "manual"
    wo.foldlevel    = 99
    wo.conceallevel = 2  -- hides concealed path text in normal mode
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

    local lines = {}
    for _, row in ipairs(flat) do
        local e      = row.node.entry
        local indent = string.rep(INDENT, row.depth)
        local icon   = entry_icon(e)
        local line
        if e.is_folder or e.is_solution then
            line = indent .. icon .. e.name
        else
            line = indent .. icon .. e.name .. SEP .. (e.path or "")
        end
        table.insert(lines, line)
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

    apply_decorations(bufnr, flat, vim.api.nvim_win_get_cursor(0)[1], false)

    vim.schedule(function()
        if vim.api.nvim_buf_is_valid(bufnr) then
            apply_folds(bufnr, flat)
        end
    end)

    local aug = vim.api.nvim_create_augroup("DotnetView_" .. bufnr, { clear = true })

    vim.api.nvim_create_autocmd("CursorMoved", {
        group  = aug, buffer = bufnr,
        callback = function()
            local st = state.get(bufnr)
            if st and st.flat then
                apply_decorations(bufnr, st.flat, vim.api.nvim_win_get_cursor(0)[1], false)
            end
        end,
    })

    vim.api.nvim_create_autocmd("InsertEnter", {
        group  = aug, buffer = bufnr,
        callback = function()
            if vim.api.nvim_win_get_cursor(0)[1] == 1 then
                vim.schedule(function() vim.cmd("stopinsert") end)
                return
            end
            -- Reveal paths when entering insert mode
            local st = state.get(bufnr)
            if st and st.flat then
                apply_decorations(bufnr, st.flat, vim.api.nvim_win_get_cursor(0)[1], true)
            end
        end,
    })

    vim.api.nvim_create_autocmd("InsertLeave", {
        group  = aug, buffer = bufnr,
        callback = function()
            -- Conceal paths when leaving insert mode
            local st = state.get(bufnr)
            if st and st.flat then
                apply_decorations(bufnr, st.flat, vim.api.nvim_win_get_cursor(0)[1], false)
            end
        end,
    })

    vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
        group  = aug, buffer = bufnr,
        callback = function()
            local st = state.get(bufnr)
            if not st or not st.flat then return end
            local in_insert = vim.api.nvim_get_mode().mode:sub(1,1) == "i"
            apply_decorations(bufnr, st.flat, vim.api.nvim_win_get_cursor(0)[1], in_insert)
        end,
    })
end

-- Stub — not used with foldmethod=manual
function M.foldexpr(_) return "0" end

-- ---------------------------------------------------------------------------
-- parse_buffer
-- ---------------------------------------------------------------------------
--
-- Strategy:
--   For each buffer line i:
--     - flat[i] exists → use flat[i].kind, read name/path from text
--     - flat[i] nil (new/pasted line) → infer kind from path extension
--
-- Kind inference for new lines:
--   - No path → folder
--   - Path ends in *proj → project
--   - Anything else → solution item
--
-- Solution items are attached as children of their nearest folder ancestor.
-- On serialise, items that are children of a folder entry update that
-- folder's solution_items list.

---@param bufnr integer
---@param original_flat table[]
---@return table|nil root_node
function M.parse_buffer(bufnr, original_flat)
    if not original_flat or #original_flat == 0 then return nil end

    -- Build name+kind → ordered candidates map for fallback lookup
    -- Keyed as "kind:name" to handle duplicate names across kinds
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

    local buf_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

    for idx, line in ipairs(buf_lines) do
        if idx == 1 then goto continue end

        local raw, depth = strip_prefix(line)
        if raw == "" then goto continue end

        local name, path = raw:match("^(.-)  +(.+)$")
        if not name then name = raw; path = nil end
        name = vim.trim(name)
        path = path and vim.trim(path) or nil

        while #stack > 1 and stack[#stack].depth >= depth do
            table.remove(stack)
        end
        local parent = stack[#stack].node

        -- Determine kind from the line's icon (reliable since we control rendering)
        local line_kind
        do
            local i2 = 1
            while i2 <= #line and line:byte(i2) == 0x20 do i2 = i2 + 1 end
            local rest = line:sub(i2)
            if rest:sub(1, #ICONS._solution) == ICONS._solution then line_kind = "solution"
            elseif rest:sub(1, #ICONS._folder) == ICONS._folder   then line_kind = "folder"
            elseif rest:sub(1, #ICONS._item)   == ICONS._item     then line_kind = "item"
            else                                                        line_kind = "project"
            end
        end

        -- Positional match: use flat[idx] if its kind matches what we see on screen.
        -- Kind match handles renames (name changed, same kind = same entry).
        -- Kind mismatch means lines shifted after dd/p — fall through to name lookup.
        local orig_row = original_flat[idx]
        if orig_row and orig_row.kind ~= line_kind then
            orig_row = nil
        end

        -- Fallback: name+kind lookup for shifted/inserted lines
        if not orig_row then
            local key = line_kind .. ":" .. name
            local n   = consumed[key] or 0
            if candidates[key] and candidates[key][n + 1] then
                orig_row      = candidates[key][n + 1]
                consumed[key] = n + 1
            end
        end

        -- Determine kind
        local kind
        if orig_row then
            kind = orig_row.kind
        else
            if not path then kind = "folder"
            elseif path:match("%.[a-zA-Z]+proj$") or path:match("%.sln$") then kind = "project"
            else kind = "item" end
        end

        local node
        if orig_row then
            local entry = orig_row.node.entry
            if name ~= entry.name or (path and not entry.is_folder and path ~= entry.path) then
                entry = vim.deepcopy(entry)
                entry.name = name
                if path and not entry.is_folder then entry.path = path end
            end
            node = { entry = entry, children = {} }
        else
            if kind == "folder" then
                node = { entry = { name = name, path = name, type_guid = "2150E333-8FDC-42A3-9474-1A3956D46DE8", id = nil, is_folder = true }, children = {} }
            elseif kind == "item" then
                node = { entry = { name = name, path = path or name, is_solution_item = true, is_folder = false }, children = {} }
            else
                node = { entry = { name = name, path = path or "", type_guid = nil, id = nil, is_folder = false }, children = {} }
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

    -- Block insert on line 1
    for _, key in ipairs({ "i", "I", "a", "A", "o", "O", "s", "S", "c", "C", "r", "R" }) do
        vim.keymap.set("n", key, function()
            if vim.api.nvim_win_get_cursor(0)[1] == 1 then return end
            vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(key, true, false, true), "n", false)
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
        else
            local full = vim.fn.fnamemodify(s.sln_path, ":h") .. "/" .. e.path
            vim.cmd.edit(vim.fn.fnameescape(full))
        end
    end, opts)

    -- dd: fold-aware delete
    vim.keymap.set("n", "dd", function()
        local state = require("dotnet.state")
        local s = state.get(bufnr)
        if not s or not s.flat then vim.cmd("normal! dd"); return end
        local lnum = vim.api.nvim_win_get_cursor(0)[1]
        if lnum == 1 then return end
        local row = s.flat[lnum]
        if row and (row.kind == "folder" or row.kind == "solution") then
            local fold_end = vim.fn.foldclosedend(lnum)
            if fold_end ~= -1 then
                vim.cmd(lnum .. "," .. fold_end .. "d _")
            else
                local depth = row.depth
                local last  = lnum
                for i = lnum + 1, #s.flat do
                    if s.flat[i].depth <= depth then break end
                    last = i
                end
                vim.cmd(lnum .. "," .. last .. "d _")
            end
        else
            vim.cmd("normal! dd")
        end
        vim.schedule(function()
            local st = state.get(bufnr)
            if st and st.flat then
                apply_decorations(bufnr, st.flat, vim.api.nvim_win_get_cursor(0)[1], false)
            end
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
