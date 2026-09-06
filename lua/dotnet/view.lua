local M = {}

local PROJECT_ICONS = {
    csproj = "󰌛 ",
    fsproj = "󰬟 ",
    vbproj = "󰈝 ",
    esproj = "\xEE\x98\x8C ",
    vdproj = "󰒓 ",
    dbproj = "󰆼 ",
    pyproj = "󰌠 ",
    vcxproj = "󰙲 ",
    shproj = "󰚩 ",
}

local ICONS = {
    _folder = "󰉋 ",
    _solution = "󰘐 ",
    _default = "󰈙 ",
}

local HL = {
    icon = "DotnetSolutionIcon",
    name = "DotnetSolutionProject",
    folder = "DotnetSolutionFolder",
    item = "DotnetSolutionItem",
    header = "DotnetSolutionHeader",
    modified = "DotnetSolutionModified",
    missing = "DotnetSolutionMissing",
}

local NS = vim.api.nvim_create_namespace("dotnet_solution")
local INDENT = "  "

local _mini, _nonicons, _devicons
local _providers_loaded = false

local function load_providers()
    if _providers_loaded then
        return
    end
    _providers_loaded = true

    local ok_mini, mini = pcall(require, "mini.icons")
    if ok_mini and _G.MiniIcons then
        _mini = mini
    end

    local ok_non, nonicons = pcall(require, "nonicons")
    if ok_non and nonicons.get_icon then
        _nonicons = nonicons
    end

    local ok_dev, devicons = pcall(require, "nvim-web-devicons")
    if ok_dev then
        _devicons = devicons
    end
end

---@param name string
---@return string|nil icon, string|nil hl
local function get_icon_for_file(name)
    load_providers()

    if _mini then
        local icon, hl, is_default = _mini.get("file", name)
        if icon and icon ~= "" and not is_default then
            return icon .. " ", hl
        end
    end
    if _nonicons then
        local icon, hl = _nonicons.get_icon(name)
        if icon and icon ~= "" then
            return icon .. " ", hl or HL.icon
        end
    end
    if _devicons then
        local icon, hl = _devicons.get_icon(name)
        if icon and icon ~= "" then
            return icon .. " ", hl or HL.icon
        end
    end
    if _mini then
        local icon, hl = _mini.get("file", name)
        if icon and icon ~= "" then
            return icon .. " ", hl
        end
    end

    return ICONS._default, HL.icon
end

---@param entry table
---@return string icon, string hl
local function entry_icon(entry)
    if entry.is_solution then
        return ICONS._solution, HL.header
    end
    if entry.is_folder then
        return ICONS._folder, HL.folder
    end
    local filename = entry.path and entry.path:match("([^/\\]+)$") or entry.name
    local ext = filename and filename:match("%.([^%.]+)$")
    if ext and PROJECT_ICONS[ext:lower()] then
        return PROJECT_ICONS[ext:lower()], HL.icon
    end
    return get_icon_for_file(filename or entry.name)
end

---@param line string
---@return integer
local function leading_space_bytes(line)
    local spaces = 0
    while spaces < #line and line:byte(spaces + 1) == 0x20 do
        spaces = spaces + 1
    end
    return spaces
end

---@param line string
---@return string name, integer depth
local function strip_prefix(line)
    local spaces = leading_space_bytes(line)
    local i = spaces + 1
    local depth = math.floor(spaces / #INDENT)
    while i <= #line do
        local b = line:byte(i)
        if b >= 0x21 and b <= 0x7E then
            break
        end
        if b < 0x80 then
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

---@param sln_path string
---@param rel_path string
---@return boolean
local function file_exists(sln_path, rel_path)
    if not rel_path or rel_path == "" then
        return false
    end
    return vim.uv.fs_stat(vim.fn.fnamemodify(sln_path, ":h") .. "/" .. rel_path) ~= nil
end

---@param bufnr integer
---@param flat table[]
local function apply_decorations(bufnr, flat)
    vim.api.nvim_buf_clear_namespace(bufnr, NS, 0, -1)

    local state = require("dotnet.state")
    local s = state.get(bufnr)
    local sln_path = s and s.sln_path or ""
    local line_count = vim.api.nvim_buf_line_count(bufnr)

    for i, row in ipairs(flat) do
        local lnum = i - 1
        if lnum >= line_count then
            break
        end

        local e = row.node.entry
        local icon, icon_hl = entry_icon(e)
        local buf_line = vim.api.nvim_buf_get_lines(bufnr, lnum, lnum + 1, false)[1]
        local line_len = #buf_line

        if line_len == 0 then
            goto next_row
        end
        local indent_bytes = leading_space_bytes(buf_line)
        if indent_bytes >= line_len then
            goto next_row
        end

        vim.api.nvim_buf_set_extmark(bufnr, NS, lnum, indent_bytes, {
            end_col = math.min(indent_bytes + #icon, line_len),
            hl_group = icon_hl,
            priority = 10,
        })

        local name_col = indent_bytes + #icon
        local is_missing = not e.is_folder and not e.is_solution and not file_exists(sln_path, e.path)

        local name_hl
        if e.is_solution then
            name_hl = HL.header
        elseif is_missing then
            name_hl = HL.missing
        elseif e.is_folder then
            name_hl = HL.folder
        elseif e.is_solution_item then
            name_hl = HL.item
        else
            name_hl = HL.name
        end

        if name_col < line_len then
            vim.api.nvim_buf_set_extmark(bufnr, NS, lnum, name_col, {
                end_col = math.min(name_col + #e.name, line_len),
                hl_group = name_hl,
                hl_mode = "replace",
                priority = 20,
            })
        end

        ::next_row::
    end
end

---@param bufnr integer
---@param flat table[]
local function apply_folds(bufnr, flat)
    local total = #flat
    vim.api.nvim_buf_call(bufnr, function()
        vim.cmd("silent! normal! zE")
        for i = total, 1, -1 do
            local row = flat[i]
            if row.kind == "solution" or row.kind == "folder" then
                local last = i
                for j = i + 1, total do
                    if flat[j].depth <= row.depth then
                        break
                    end
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

---@param winid integer
local function set_win_options(winid)
    local wo = vim.wo[winid]
    wo.wrap = false
    wo.signcolumn = "no"
    wo.foldcolumn = "1"
    wo.spell = false
    wo.list = false
    wo.cursorline = true
    wo.foldmethod = "manual"
    wo.foldlevel = 99
    wo.conceallevel = 0
    wo.foldtext = ""
end

---@param bufnr integer
---@param s dotnet.State
---@return table[]
local function current_flat(bufnr, s)
    local parser = require("dotnet.parser")
    local root = M.parse_buffer(bufnr, s.flat)
    if not root then
        return s.flat
    end
    parser.consolidate_items(root)
    return parser.flatten_tree(root, s.sln_path)
end

---@param s dotnet.State
---@param row table
local function ensure_tracked(s, row)
    for _, r in ipairs(s.flat) do
        if r.node.entry == row.node.entry then
            return
        end
    end
    table.insert(s.flat, row)
end

---@param bufnr integer
---@param sln_path string
---@param root table
function M.render(bufnr, sln_path, root)
    local parser = require("dotnet.parser")
    local state = require("dotnet.state")
    local flat = parser.flatten_tree(root, sln_path)

    local s = state.get(bufnr)
    if s then
        s.flat = flat
        s.rendering = true
    end

    local lines = {}
    for _, row in ipairs(flat) do
        local e = row.node.entry
        local indent = string.rep(INDENT, row.depth)
        local icon = entry_icon(e)
        table.insert(lines, indent .. icon .. e.name)
    end

    vim.bo[bufnr].modifiable = true
    vim.bo[bufnr].readonly = false
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
    vim.bo[bufnr].modified = false
    vim.bo[bufnr].modifiable = true
    vim.bo[bufnr].undolevels = vim.bo[bufnr].undolevels

    if s then
        s.rendering = false
    end

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

    -- Other plugins (e.g. nvim-ufo) reassert their own 'foldtext' on every
    -- BufWinEnter, racing with apply_win_options — reassert ours last so it wins.
    vim.api.nvim_create_autocmd("BufWinEnter", {
        group = aug,
        buffer = bufnr,
        callback = function()
            vim.wo[vim.api.nvim_get_current_win()].foldtext = ""
        end,
    })

    vim.api.nvim_create_autocmd("CursorMoved", {
        group = aug,
        buffer = bufnr,
        callback = function()
            local st = state.get(bufnr)
            if st and st.flat then
                apply_decorations(bufnr, current_flat(bufnr, st))
            end
        end,
    })

    vim.api.nvim_create_autocmd("InsertEnter", {
        group = aug,
        buffer = bufnr,
        callback = function()
            if vim.api.nvim_win_get_cursor(0)[1] == 1 then
                vim.schedule(function()
                    vim.cmd("stopinsert")
                end)
            end
        end,
    })

    vim.api.nvim_create_autocmd("TextChangedI", {
        group = aug,
        buffer = bufnr,
        callback = function()
            local st = state.get(bufnr)
            if st and st.flat and not st.rendering then
                apply_decorations(bufnr, current_flat(bufnr, st))
            end
        end,
    })

    vim.api.nvim_create_autocmd("TextChanged", {
        group = aug,
        buffer = bufnr,
        callback = function()
            local st = state.get(bufnr)
            if st and st.flat and not st.rendering then
                local live_flat = current_flat(bufnr, st)
                apply_decorations(bufnr, live_flat)
                apply_folds(bufnr, live_flat)
            end
        end,
    })
end

---@param _ integer
---@return string
function M.foldexpr(_)
    return "0"
end

---@param kind string
---@return string
local function norm_kind(kind)
    if kind == "item" or kind == "project" then
        return "file"
    end
    return kind
end

---@param line string
---@return string|nil
local function line_folder_prefix(line)
    local i2 = 1
    while i2 <= #line and line:byte(i2) == 0x20 do
        i2 = i2 + 1
    end
    return line:sub(i2)
end

---@param bufnr integer
---@param original_flat table[]
---@return table|nil root_node
function M.parse_buffer(bufnr, original_flat)
    if not original_flat or #original_flat == 0 then
        return nil
    end

    local candidates = {}
    for _, row in ipairs(original_flat) do
        if row.kind ~= "solution" then
            local key = norm_kind(row.kind) .. ":" .. row.node.entry.name
            if not candidates[key] then
                candidates[key] = {}
            end
            table.insert(candidates[key], row)
        end
    end
    local consumed = {}

    local infos = {}
    for idx, line in ipairs(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)) do
        if idx == 1 then
            goto continue
        end
        local name, depth = strip_prefix(line)
        if name == "" then
            goto continue
        end
        local is_new_folder = vim.endswith(name, "/")
        if is_new_folder then
            name = name:sub(1, -2)
        end
        local line_kind
        if is_new_folder then
            line_kind = "folder"
        else
            local rest = line_folder_prefix(line)
            line_kind = (rest:sub(1, #ICONS._folder) == ICONS._folder) and "folder" or "file"
        end
        table.insert(
            infos,
            { idx = idx, name = name, depth = depth, line_kind = line_kind, is_new_folder = is_new_folder }
        )
        ::continue::
    end

    local resolved = {}
    for _, info in ipairs(infos) do
        if not info.is_new_folder then
            local key = info.line_kind .. ":" .. info.name
            local n = consumed[key] or 0
            if candidates[key] and candidates[key][n + 1] then
                resolved[info] = candidates[key][n + 1]
                consumed[key] = n + 1
            end
        end
    end

    local used_rows = {}
    for _, orig_row in pairs(resolved) do
        used_rows[orig_row] = true
    end
    for _, info in ipairs(infos) do
        if not resolved[info] and not info.is_new_folder then
            local orig_row = original_flat[info.idx]
            if orig_row and norm_kind(orig_row.kind) == info.line_kind and not used_rows[orig_row] then
                resolved[info] = orig_row
                used_rows[orig_row] = true
            end
        end
    end

    local root = { entry = nil, children = {} }
    local stack = { { node = root, depth = 0 } }

    for _, info in ipairs(infos) do
        while #stack > 1 and stack[#stack].depth >= info.depth do
            table.remove(stack)
        end
        local parent = stack[#stack].node
        local orig_row = resolved[info]

        local parent_entry = parent.entry
        local parent_has_items = parent_entry and parent_entry.is_folder and parent_entry.solution_items ~= nil

        local node
        if orig_row then
            local entry = orig_row.node.entry
            if info.name ~= entry.name then
                entry = vim.deepcopy(entry)
                entry.name = info.name
            end
            node = { entry = entry, children = {} }
        elseif info.line_kind == "folder" then
            node = {
                entry = {
                    name = info.name,
                    path = info.name,
                    type_guid = "2150E333-8FDC-42A3-9474-1A3956D46DE8",
                    id = nil,
                    is_folder = true,
                },
                children = {},
            }
        elseif parent_has_items then
            node = {
                entry = { name = info.name, path = info.name, is_solution_item = true, is_folder = false },
                children = {},
            }
        else
            node = {
                entry = { name = info.name, path = "", type_guid = nil, id = nil, is_folder = false },
                children = {},
            }
        end

        table.insert(parent.children, node)
        table.insert(stack, { node = node, depth = info.depth })
    end

    return root
end

function M.setup_highlights()
    local defs = {
        [HL.icon] = { link = "Function" },
        [HL.name] = { link = "Normal" },
        [HL.folder] = { link = "Directory" },
        [HL.item] = { link = "Comment" },
        [HL.header] = { fg = 0x9B4FBA, bold = true },
        [HL.modified] = { link = "DiagnosticWarn" },
        [HL.missing] = { link = "DiagnosticError" },
    }
    for name, opts in pairs(defs) do
        vim.api.nvim_set_hl(0, name, vim.tbl_extend("keep", { default = true }, opts))
    end
end

local KEYMAP_KEYS = { "i", "I", "a", "A", "s", "S", "c", "C", "r", "R", "o", "O", "<CR>", "dd", "gf", "gp", "<C-r>" }

---@param bufnr integer
function M.teardown_keymaps(bufnr)
    for _, key in ipairs(KEYMAP_KEYS) do
        pcall(vim.keymap.del, "n", key, { buffer = bufnr })
    end
end

---@param bufnr integer
function M.clear(bufnr)
    vim.api.nvim_buf_clear_namespace(bufnr, NS, 0, -1)
    pcall(vim.api.nvim_del_augroup_by_name, "DotnetView_" .. bufnr)
    if vim.api.nvim_buf_is_valid(bufnr) then
        vim.api.nvim_buf_call(bufnr, function()
            vim.cmd("silent! normal! zE")
        end)
    end
end

---@param bufnr integer
function M.revert_to_plain(bufnr)
    M.clear(bufnr)
    M.teardown_keymaps(bufnr)

    vim.bo[bufnr].buftype = ""
    vim.bo[bufnr].filetype = ""
    vim.b[bufnr].EditorConfig_disable = nil

    vim.api.nvim_buf_call(bufnr, function()
        vim.cmd("noautocmd edit!")
    end)
end

---@param bufnr integer
function M.setup_keymaps(bufnr)
    local opts = { buffer = bufnr, silent = true, noremap = true }

    for _, key in ipairs({ "i", "I", "a", "A", "s", "S", "c", "C", "r", "R" }) do
        vim.keymap.set("n", key, function()
            if vim.api.nvim_win_get_cursor(0)[1] == 1 then
                return
            end
            vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(key, true, false, true), "n", false)
        end, opts)
    end

    for _, key in ipairs({ "o", "O" }) do
        vim.keymap.set("n", key, function()
            local state = require("dotnet.state")
            local s = state.get(bufnr)
            if not s or not s.flat then
                return
            end
            local lnum = vim.api.nvim_win_get_cursor(0)[1]

            if lnum == 1 and key == "O" then
                return
            end

            local buf_insert = key == "o" and lnum or lnum - 1

            local flat = current_flat(bufnr, s)
            local ref_idx = key == "o" and lnum + 1 or lnum - 1
            local ref_row = flat[ref_idx]
            local depth
            if lnum == 1 then
                depth = 1
            else
                depth = ref_row and ref_row.depth or (flat[lnum] and flat[lnum].depth or 1)
            end

            local indent = string.rep(INDENT, depth)
            vim.bo[bufnr].modifiable = true
            vim.api.nvim_buf_set_lines(bufnr, buf_insert, buf_insert, false, { indent })
            vim.bo[bufnr].modifiable = true

            vim.api.nvim_win_set_cursor(0, { buf_insert + 1, #indent })
            vim.cmd("startinsert!")
        end, opts)
    end

    vim.keymap.set("n", "<CR>", function()
        local state = require("dotnet.state")
        local s = state.get(bufnr)
        if not s or not s.flat then
            return
        end
        local lnum = vim.api.nvim_win_get_cursor(0)[1]
        local row = current_flat(bufnr, s)[lnum]
        if not row then
            return
        end
        local e = row.node.entry
        if e.is_solution or e.is_folder then
            vim.cmd("normal! za")
        elseif e.path and e.path ~= "" then
            vim.cmd.edit(vim.fn.fnameescape(vim.fn.fnamemodify(s.sln_path, ":h") .. "/" .. e.path))
        else
            vim.notify("[dotnet] No path set — use gf to pick a file", vim.log.levels.WARN)
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
        if lnum == 1 then
            return
        end
        local flat = current_flat(bufnr, s)
        local row = flat[lnum]

        local first, last = lnum, lnum
        if row and (row.kind == "folder" or row.kind == "solution") then
            local fold_end = vim.fn.foldclosedend(lnum)
            if fold_end ~= -1 then
                last = fold_end
            else
                local depth = row.depth
                for i = lnum + 1, #flat do
                    if flat[i].depth <= depth then
                        break
                    end
                    last = i
                end
            end
            vim.cmd(first .. "," .. last .. "d _")
        else
            vim.cmd("normal! dd")
        end
    end, opts)

    vim.keymap.set("n", "gf", function()
        local state = require("dotnet.state")
        local s = state.get(bufnr)
        if not s or not s.flat then
            return
        end
        local lnum = vim.api.nvim_win_get_cursor(0)[1]
        local row = current_flat(bufnr, s)[lnum]

        local buf_line = vim.api.nvim_buf_get_lines(bufnr, lnum - 1, lnum, false)[1] or ""
        local line_name = strip_prefix(buf_line)
        line_name = line_name:gsub("/$", "")

        if row and (row.kind == "solution" or row.kind == "folder") then
            return
        end

        if not _G.Snacks or not Snacks.picker then
            vim.notify("[dotnet] gf requires snacks.nvim (picker)", vim.log.levels.ERROR)
            return
        end

        local initial = (row and row.node.entry.path ~= "" and row.node.entry.path) or line_name or ""
        local sln_dir = vim.fn.fnamemodify(s.sln_path, ":h")
        local kind = row and row.kind or "project"
        local glob = kind == "item" and nil or "*.{csproj,fsproj,vbproj,esproj,vcxproj,pyproj,dbproj,shproj}"

        Snacks.picker.files({
            cwd = sln_dir,
            glob = glob,
            title = "Path for " .. (initial ~= "" and initial or "new entry"),
            pattern = initial,
            confirm = function(picker, item)
                picker:close()
                if not item then
                    return
                end
                local rel = item.file or item.text
                local name = rel:match("([^/\\]+)$") or rel
                local icon = entry_icon({ path = rel, name = name, is_folder = false })
                local indent = row and string.rep(INDENT, row.depth) or (buf_line:match("^(%s*)") or "")

                vim.bo[bufnr].modifiable = true
                vim.api.nvim_buf_set_lines(bufnr, lnum - 1, lnum, false, { indent .. icon .. name })
                vim.bo[bufnr].modified = true
                vim.bo[bufnr].modifiable = true

                if row then
                    local e = row.node.entry
                    e.path = rel
                    e.name = name
                    ensure_tracked(s, row)
                end

                local st = state.get(bufnr)
                if st and st.flat then
                    apply_decorations(bufnr, current_flat(bufnr, st))
                end
            end,
        })
    end, opts)

    vim.keymap.set("n", "gp", function()
        local state = require("dotnet.state")
        local s = state.get(bufnr)
        if s then
            vim.cmd.edit(vim.fn.fnameescape(s.sln_path))
        end
    end, opts)

    vim.keymap.set("n", "<C-r>", function()
        local state = require("dotnet.state")
        local s = state.get(bufnr)
        if s then
            require("dotnet").load_buffer(bufnr, s.sln_path)
        end
    end, opts)
end

function M.apply_win_options()
    set_win_options(vim.api.nvim_get_current_win())
end

---@param bufnr integer
function M.apply_buf_options(bufnr)
    -- Depth is derived from indent width / #INDENT, so <</>> must shift by
    -- exactly one INDENT, regardless of the user's own shiftwidth/tabstop.
    vim.bo[bufnr].shiftwidth = #INDENT
    vim.bo[bufnr].tabstop = #INDENT
    vim.bo[bufnr].softtabstop = #INDENT
    vim.bo[bufnr].expandtab = true
end

return M
