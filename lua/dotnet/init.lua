local M = {}

local aug = vim.api.nvim_create_augroup("DotnetSln", { clear = true })

---@type string|nil
local last_sln_path = nil

---@param dir? string
---@return string|nil
function M.find_solution(dir)
    dir = dir or vim.fn.getcwd()
    for _, glob in ipairs({ "*.sln", "*.slnx", "*.slnf" }) do
        local matches = vim.fn.globpath(dir, glob, false, true)
        if #matches > 0 then
            return matches[1]
        end
    end
end

---@param sln_path? string
function M.open(sln_path)
    sln_path = sln_path or M.find_solution() or last_sln_path
    if not sln_path then
        vim.notify("[dotnet] No solution file found in " .. vim.fn.getcwd(), vim.log.levels.WARN)
        return
    end
    sln_path = vim.fn.fnamemodify(sln_path, ":p")
    local existing = vim.fn.bufnr(sln_path)
    if existing ~= -1 and vim.api.nvim_buf_is_loaded(existing) then
        local state = require("dotnet.state")
        if not state.get(existing) and require("dotnet.config").values.enabled then
            M.load_buffer(existing, sln_path)
        end
        for _, win in ipairs(vim.api.nvim_list_wins()) do
            if vim.api.nvim_win_get_buf(win) == existing then
                vim.api.nvim_set_current_win(win)
                return
            end
        end
        vim.api.nvim_set_current_buf(existing)
        return
    end
    vim.cmd.edit(vim.fn.fnameescape(sln_path))
end

---@param sln_path? string
function M.toggle(sln_path)
    local state = require("dotnet.state")
    local view = require("dotnet.view")
    for _, win in ipairs(vim.api.nvim_list_wins()) do
        local buf = vim.api.nvim_win_get_buf(win)
        if state.get(buf) then
            if vim.api.nvim_get_current_buf() ~= buf then
                vim.api.nvim_set_current_win(win)
                return
            end
            view.revert_to_plain(buf)
            state.clear(buf)
            return
        end
    end
    M.open(sln_path)
end

---@param bufnr integer
---@param sln_path string
function M.load_buffer(bufnr, sln_path)
    local parser = require("dotnet.parser")
    local view = require("dotnet.view")
    local state = require("dotnet.state")

    last_sln_path = sln_path

    local fh = io.open(sln_path, "rb")
    if not fh then
        vim.notify("[dotnet] Cannot read: " .. sln_path, vim.log.levels.ERROR)
        return
    end
    local raw_bytes = fh:read("*a")
    fh:close()
    local text = raw_bytes:gsub("\r\n", "\n")

    local fmt = parser.detect(sln_path)
    local root, nesting

    if fmt == "slnx" then
        root = parser.parse_slnx(text)
        nesting = {}
    elseif fmt == "slnf" then
        local _, r = parser.parse_slnf(text)
        root = r
        nesting = {}
    else
        local entries, nest = parser.parse_sln(text)
        nesting = nest
        root = parser.build_tree(entries, nest)
    end

    local nesting_ordered = {}
    do
        local nested_block = text:match("GlobalSection%(NestedProjects%)[^\n]*\n(.-)EndGlobalSection")
        if nested_block then
            for child, parent in nested_block:gmatch("{([A-Fa-f0-9%-]+)}%s*=%s*{([A-Fa-f0-9%-]+)}") do
                table.insert(nesting_ordered, { child = child:upper(), parent = parent:upper() })
            end
        end
    end

    state.set(bufnr, {
        sln_path = sln_path,
        fmt = fmt,
        raw = text,
        raw_bytes = raw_bytes,
        root = root,
        nesting = nesting,
        nesting_ordered = nesting_ordered,
        flat = {},
    })

    vim.bo[bufnr].buftype = "acwrite"
    vim.bo[bufnr].swapfile = false
    vim.bo[bufnr].bufhidden = "hide"
    vim.bo[bufnr].filetype = "dotnet-sln"
    vim.bo[bufnr].syntax = ""
    vim.b[bufnr].EditorConfig_disable = 1
    view.apply_buf_options(bufnr)

    view.render(bufnr, sln_path, root)
    view.setup_keymaps(bufnr)
    vim.api.nvim_buf_call(bufnr, view.apply_win_options)

    vim.api.nvim_create_autocmd("BufWipeout", {
        group = aug,
        buffer = bufnr,
        once = true,
        callback = function()
            state.clear(bufnr)
        end,
    })
end

---@param bufnr integer
function M.save_buffer(bufnr)
    local parser = require("dotnet.parser")
    local view = require("dotnet.view")
    local state = require("dotnet.state")

    local s = state.get(bufnr)
    if not s then
        vim.notify("[dotnet] No solution state for buffer " .. bufnr, vim.log.levels.ERROR)
        return
    end

    if not s.flat or #s.flat == 0 then
        vim.notify("[dotnet] Cannot save — solution state is stale. Reload with <C-r>.", vim.log.levels.ERROR)
        return
    end

    local new_root = view.parse_buffer(bufnr, s.flat)
    if not new_root then
        vim.notify("[dotnet] Cannot save — failed to parse buffer. Reload with <C-r>.", vim.log.levels.ERROR)
        return
    end

    if #s.flat > 1 and #new_root.children == 0 then
        vim.notify(
            "[dotnet] Cannot save — the buffer looks emptied out (e.g. from an undo gone too far). Reload with <C-r> if this isn't intentional.",
            vim.log.levels.ERROR
        )
        return
    end

    local function find_orphan_item(node, parent_is_folder)
        if node.entry and node.entry.is_solution_item and not parent_is_folder then
            return node.entry.name
        end
        local is_folder = node.entry and node.entry.is_folder or false
        for _, child in ipairs(node.children) do
            local bad = find_orphan_item(child, is_folder)
            if bad then
                return bad
            end
        end
        return nil
    end
    local orphan_item = find_orphan_item(new_root, false)
    if orphan_item then
        vim.notify(
            "[dotnet] Cannot save — '"
                .. orphan_item
                .. "' must stay nested inside a folder. Move it back under one or delete it.",
            vim.log.levels.ERROR
        )
        return
    end

    parser.consolidate_items(new_root)

    local new_raw
    if s.fmt == "slnx" then
        new_raw = parser.serialize_slnx(s.raw, new_root)
    elseif s.fmt == "slnf" then
        new_raw = parser.serialize_slnf(s.raw, new_root)
    else
        local new_nesting, new_nesting_ordered = parser.nesting_from_tree(new_root)

        local orig_ordered = s.nesting_ordered or {}
        local seen = {}
        local merged = {}
        for _, pair in ipairs(orig_ordered) do
            local new_parent = new_nesting[pair.child]
            if new_parent then
                table.insert(merged, { child = pair.child, parent = new_parent })
                seen[pair.child] = true
            end
        end
        for _, pair in ipairs(new_nesting_ordered) do
            if not seen[pair.child] then
                table.insert(merged, pair)
            end
        end

        local flat = parser.flatten_tree(new_root, s.sln_path)
        local entries = {}
        for _, row in ipairs(flat) do
            if row.kind ~= "solution" and row.kind ~= "item" then
                table.insert(entries, row.node.entry)
            end
        end
        new_raw = parser.serialize_sln(s.raw, entries, new_nesting, merged)

        s.nesting_ordered = merged
    end

    if s.raw_bytes and s.raw_bytes:find("\r\n") then
        new_raw = new_raw:gsub("\n", "\r\n")
    end

    local wfh = io.open(s.sln_path, "wb")
    if not wfh then
        vim.notify("[dotnet] Write failed: cannot open " .. s.sln_path, vim.log.levels.ERROR)
        return
    end
    wfh:write(new_raw)
    wfh:close()

    s.raw = new_raw:gsub("\r\n", "\n")
    s.raw_bytes = new_raw
    s.root = new_root
    vim.bo[bufnr].modified = false
    vim.notify("[dotnet] Saved " .. vim.fn.fnamemodify(s.sln_path, ":t"), vim.log.levels.INFO)

    view.render(bufnr, s.sln_path, new_root)
end

---@param opts? dotnet.Config
function M.setup(opts)
    require("dotnet.config").apply(opts)
end

---@return integer[]
local function sln_bufs()
    local bufs = {}
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_is_loaded(buf) and vim.api.nvim_buf_get_name(buf):match("%.sln[fx]?$") then
            table.insert(bufs, buf)
        end
    end
    return bufs
end

function M.enable()
    require("dotnet.config").values.enabled = true
    local state = require("dotnet.state")
    for _, buf in ipairs(sln_bufs()) do
        if not state.get(buf) then
            if vim.bo[buf].modified then
                vim.notify(
                    "[dotnet] "
                        .. vim.fn.fnamemodify(vim.api.nvim_buf_get_name(buf), ":t")
                        .. " has unsaved changes — save or reload it to switch to the tree view.",
                    vim.log.levels.WARN
                )
            else
                M.load_buffer(buf, vim.fn.fnamemodify(vim.api.nvim_buf_get_name(buf), ":p"))
            end
        end
    end
    vim.notify("[dotnet] Enabled", vim.log.levels.INFO)
end

function M.disable()
    require("dotnet.config").values.enabled = false
    local state = require("dotnet.state")
    local view = require("dotnet.view")
    for _, buf in ipairs(sln_bufs()) do
        if state.get(buf) then
            view.revert_to_plain(buf)
            state.clear(buf)
        end
    end
    vim.notify("[dotnet] Disabled", vim.log.levels.INFO)
end

local view = require("dotnet.view")
view.setup_highlights()

vim.api.nvim_create_autocmd("ColorScheme", {
    group = aug,
    callback = view.setup_highlights,
})

vim.api.nvim_create_autocmd("BufReadCmd", {
    group = aug,
    pattern = { "*.sln", "*.slnx", "*.slnf" },
    nested = true,
    callback = function(ev)
        local cfg = require("dotnet.config")
        if not cfg.values.enabled then
            vim.cmd("noautocmd edit " .. vim.fn.fnameescape(ev.file))
            return
        end
        M.load_buffer(ev.buf, vim.fn.fnamemodify(ev.file, ":p"))
    end,
})

vim.api.nvim_create_autocmd("BufWriteCmd", {
    group = aug,
    pattern = { "*.sln", "*.slnx", "*.slnf" },
    nested = true,
    callback = function(ev)
        if not require("dotnet.state").get(ev.buf) then
            vim.cmd("noautocmd write")
            return
        end
        M.save_buffer(ev.buf)
    end,
})

local SUBCOMMANDS = { "toggle", "enable", "disable" }

vim.api.nvim_create_user_command("Dotnet", function(args)
    local sub = args.fargs[1]
    if sub == "toggle" then
        M.toggle()
    elseif sub == "enable" then
        M.enable()
    elseif sub == "disable" then
        M.disable()
    else
        M.open(args.args ~= "" and args.args or nil)
    end
end, {
    desc = "Open/toggle the dotnet solution viewer, or enable/disable it",
    nargs = "?",
    complete = function(arg_lead, cmd_line)
        if #vim.split(cmd_line, "%s+") <= 2 then
            local completions = vim.list_extend(vim.deepcopy(SUBCOMMANDS), {})
            vim.list_extend(completions, vim.fn.getcompletion(arg_lead, "file"))
            return vim.tbl_filter(function(c)
                return vim.startswith(c, arg_lead)
            end, completions)
        end
        return {}
    end,
})

local cfg = require("dotnet.config")
local KEYMAP_ACTIONS = {
    toggle = { fn = M.toggle, desc = "Dotnet: toggle solution view" },
    enable = { fn = M.enable, desc = "Dotnet: enable solution view" },
    disable = { fn = M.disable, desc = "Dotnet: disable solution view" },
}
for name, action in pairs(KEYMAP_ACTIONS) do
    local lhs = cfg.values.keymaps and cfg.values.keymaps[name]
    if lhs then
        vim.keymap.set("n", lhs, action.fn, { desc = action.desc })
    end
end

return M
