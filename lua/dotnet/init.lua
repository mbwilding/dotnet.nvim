--- dotnet.nvim – main module.
--- When neovim opens a .sln / .slnx / .slnf file, BufReadCmd fires and we
--- hijack the buffer to show our editable solution tree view.
--- :w serialises the view back to the file on disk (BufWriteCmd).

local M = {}

local aug = vim.api.nvim_create_augroup("DotnetSln", { clear = true })

---@param dir? string
---@return string|nil
function M.find_solution(dir)
    dir = dir or vim.fn.getcwd()
    for _, glob in ipairs({ "*.sln", "*.slnx", "*.slnf" }) do
        local matches = vim.fn.globpath(dir, glob, false, true)
        if #matches > 0 then return matches[1] end
    end
end

---@param sln_path? string
function M.open(sln_path)
    sln_path = sln_path or M.find_solution()
    if not sln_path then
        vim.notify("[dotnet] No solution file found in " .. vim.fn.getcwd(), vim.log.levels.WARN)
        return
    end
    sln_path = vim.fn.fnamemodify(sln_path, ":p")
    local existing = vim.fn.bufnr(sln_path)
    if existing ~= -1 and vim.api.nvim_buf_is_loaded(existing) then
        for _, win in ipairs(vim.api.nvim_list_wins()) do
            if vim.api.nvim_win_get_buf(win) == existing then
                vim.api.nvim_set_current_win(win); return
            end
        end
        vim.api.nvim_set_current_buf(existing); return
    end
    vim.cmd.edit(vim.fn.fnameescape(sln_path))
end

---@param sln_path? string
function M.toggle(sln_path)
    local state = require("dotnet.state")
    for _, win in ipairs(vim.api.nvim_list_wins()) do
        local buf = vim.api.nvim_win_get_buf(win)
        if state.get(buf) then
            if vim.api.nvim_get_current_buf() == buf then
                vim.cmd.bdelete()
            else
                vim.api.nvim_set_current_win(win)
            end
            return
        end
    end
    M.open(sln_path)
end

---@param bufnr integer
---@param sln_path string
function M.load_buffer(bufnr, sln_path)
    local parser = require("dotnet.parser")
    local view   = require("dotnet.view")
    local state  = require("dotnet.state")

    -- Read raw bytes to preserve BOM and line endings
    local fh = io.open(sln_path, "rb")
    if not fh then
        vim.notify("[dotnet] Cannot read: " .. sln_path, vim.log.levels.ERROR)
        return
    end
    local raw_bytes = fh:read("*a")
    fh:close()
    -- Normalise CRLF for internal processing
    local text = raw_bytes:gsub("\r\n", "\n")

    local fmt = parser.detect(sln_path)
    local root, nesting

    if fmt == "slnx" then
        root    = parser.parse_slnx(text)
        nesting = {}
    elseif fmt == "slnf" then
        local _, r = parser.parse_slnf(text)
        root    = r
        nesting = {}
    else
        local entries, nest = parser.parse_sln(text)
        nesting = nest
        root    = parser.build_tree(entries, nest)
    end

    -- Build original nesting_ordered from parsed nesting map, preserving sln file order
    local nesting_ordered = {}
    do
        -- Re-parse the order from the raw text directly
        local nested_block = text:match("GlobalSection%(NestedProjects%)[^\n]*\n(.-)EndGlobalSection")
        if nested_block then
            for child, parent in nested_block:gmatch("{([A-Fa-f0-9%-]+)}%s*=%s*{([A-Fa-f0-9%-]+)}") do
                table.insert(nesting_ordered, { child = child:upper(), parent = parent:upper() })
            end
        end
    end

    state.set(bufnr, {
        sln_path         = sln_path,
        fmt              = fmt,
        raw              = text,
        raw_bytes        = raw_bytes,
        root             = root,
        nesting          = nesting,
        nesting_ordered  = nesting_ordered,
        flat             = {},
    })

    vim.bo[bufnr].buftype   = "acwrite"
    vim.bo[bufnr].swapfile  = false
    vim.bo[bufnr].bufhidden = "hide"
    vim.bo[bufnr].filetype  = "dotnet-sln"
    vim.bo[bufnr].syntax    = ""
    vim.b[bufnr].EditorConfig_disable = 1

    view.render(bufnr, sln_path, root)
    view.setup_keymaps(bufnr)
    vim.api.nvim_buf_call(bufnr, view.apply_win_options)

    vim.api.nvim_create_autocmd("BufWipeout", {
        group = aug, buffer = bufnr, once = true,
        callback = function() state.clear(bufnr) end,
    })
end

---@param bufnr integer
function M.save_buffer(bufnr)
    local parser = require("dotnet.parser")
    local view   = require("dotnet.view")
    local state  = require("dotnet.state")

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

    -- Before serialising, update solution_items on each folder entry
    -- from its item children in the reconstructed tree.
    -- nil   = folder had no items originally and still doesn't (preserve verbatim)
    -- {}    = folder had items but they were all moved away (clear ProjectSection)
    -- {...} = folder has items (inject/replace ProjectSection)
    local function update_solution_items(node)
        if node.entry and node.entry.is_folder then
            local had_items = node.entry.solution_items ~= nil
            local items = {}
            local non_item_children = {}
            for _, child in ipairs(node.children) do
                if child.entry and child.entry.is_solution_item then
                    table.insert(items, (child.entry.path:gsub("/", "\\")))
                else
                    table.insert(non_item_children, child)
                    update_solution_items(child)
                end
            end
            if #items > 0 then
                -- Has items — inject/replace
                node.entry.solution_items = items
            elseif had_items then
                -- Had items but all moved away — signal to clear the section
                node.entry.solution_items = {}
            else
                -- Never had items — leave nil so serialize_sln preserves verbatim
                node.entry.solution_items = nil
            end
            node.children = non_item_children
        else
            for _, child in ipairs(node.children) do
                update_solution_items(child)
            end
        end
    end
    update_solution_items(new_root)

    local new_raw
    if s.fmt == "slnx" then
        new_raw = parser.serialize_slnx(s.raw, new_root)
    elseif s.fmt == "slnf" then
        new_raw = parser.serialize_slnf(s.raw, new_root)
    else
        local new_nesting, new_nesting_ordered = parser.nesting_from_tree(new_root)

        -- Merge: preserve original order, update changed parents, drop removed entries, append new
        local orig_ordered = s.nesting_ordered or {}
        local seen = {}
        local merged = {}
        for _, pair in ipairs(orig_ordered) do
            local new_parent = new_nesting[pair.child]
            if new_parent then
                table.insert(merged, { child = pair.child, parent = new_parent })
                seen[pair.child] = true
            end
            -- if new_parent is nil, entry was removed — skip it
        end
        -- Append entries that are new (not in original)
        for _, pair in ipairs(new_nesting_ordered) do
            if not seen[pair.child] then
                table.insert(merged, pair)
            end
        end

        local flat    = parser.flatten_tree(new_root, s.sln_path)
        local entries = {}
        for _, row in ipairs(flat) do
            if row.kind ~= "solution" and row.kind ~= "item" then
                table.insert(entries, row.node.entry)
            end
        end
        new_raw = parser.serialize_sln(s.raw, entries, new_nesting, merged)

        -- Update stored nesting_ordered for next save
        s.nesting_ordered = merged
    end

    -- Restore CRLF if original used it
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

    s.raw      = new_raw:gsub("\r\n", "\n")
    s.raw_bytes = new_raw
    s.root     = new_root
    vim.bo[bufnr].modified = false
    vim.notify("[dotnet] Saved " .. vim.fn.fnamemodify(s.sln_path, ":t"), vim.log.levels.INFO)

    view.render(bufnr, s.sln_path, new_root)
end

-- ---------------------------------------------------------------------------
-- Bootstrap
-- ---------------------------------------------------------------------------

function M.setup(opts)
    require("dotnet.config").apply(opts)
end

local view = require("dotnet.view")
view.setup_highlights()

vim.api.nvim_create_autocmd("ColorScheme", {
    group = aug, callback = view.setup_highlights,
})

vim.api.nvim_create_autocmd("BufReadCmd", {
    group   = aug,
    pattern = { "*.sln", "*.slnx", "*.slnf" },
    nested  = true,
    callback = function(ev)
        M.load_buffer(ev.buf, vim.fn.fnamemodify(ev.file, ":p"))
    end,
})

vim.api.nvim_create_autocmd("BufWriteCmd", {
    group   = aug,
    pattern = { "*.sln", "*.slnx", "*.slnf" },
    nested  = true,
    callback = function(ev)
        M.save_buffer(ev.buf)
    end,
})

vim.api.nvim_create_user_command("DotnetSolution", function(args)
    M.open(args.args ~= "" and args.args or nil)
end, { desc = "Open dotnet solution viewer", nargs = "?", complete = "file" })

local cfg = require("dotnet.config")
if cfg.values.keymap then
    vim.keymap.set("n", cfg.values.keymap, M.toggle, { desc = "Dotnet: toggle solution view" })
end

return M
