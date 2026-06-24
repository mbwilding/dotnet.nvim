--- dotnet.nvim – main module.
--- When neovim opens a .sln / .slnx / .slnf file, BufReadCmd fires and we
--- hijack the buffer to show our editable solution tree view.
--- :w serialises the view back to the file on disk (BufWriteCmd).

local M = {}

local aug = vim.api.nvim_create_augroup("DotnetSln", { clear = true })

--- Find the first solution file in `dir` (or cwd).
---@param dir? string
---@return string|nil absolute path
function M.find_solution(dir)
    dir = dir or vim.fn.getcwd()
    for _, glob in ipairs({ "*.sln", "*.slnx", "*.slnf" }) do
        local matches = vim.fn.globpath(dir, glob, false, true)
        if #matches > 0 then return matches[1] end
    end
end

--- Open (or focus) the solution buffer for `sln_path`.
---@param sln_path? string Absolute path. Auto-detected from cwd when nil.
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
                vim.api.nvim_set_current_win(win)
                return
            end
        end
        vim.api.nvim_set_current_buf(existing)
        return
    end

    vim.cmd.edit(vim.fn.fnameescape(sln_path))
end

--- Toggle the solution buffer.
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

--- Load (or reload) a solution buffer from disk.
---@param bufnr integer
---@param sln_path string Absolute path to the solution file
function M.load_buffer(bufnr, sln_path)
    local parser = require("dotnet.parser")
    local view   = require("dotnet.view")
    local state  = require("dotnet.state")

    local ok, raw = pcall(vim.fn.readfile, sln_path)
    if not ok then
        vim.notify("[dotnet] Cannot read: " .. sln_path, vim.log.levels.ERROR)
        return
    end
    local text = table.concat(raw, "\n")
    local fmt  = parser.detect(sln_path)

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

    state.set(bufnr, {
        sln_path = sln_path,
        fmt      = fmt,
        raw      = text,
        root     = root,
        nesting  = nesting,
        flat     = {}, -- populated by view.render
    })

    vim.bo[bufnr].buftype   = "acwrite"
    vim.bo[bufnr].swapfile  = false
    vim.bo[bufnr].bufhidden = "hide"
    vim.bo[bufnr].filetype  = "dotnet-sln"
    vim.b[bufnr].EditorConfig_disable = 1

    view.render(bufnr, sln_path, root)
    view.setup_keymaps(bufnr)
    vim.api.nvim_buf_call(bufnr, view.apply_win_options)

    vim.api.nvim_create_autocmd("BufWipeout", {
        group  = aug,
        buffer = bufnr,
        once   = true,
        callback = function() state.clear(bufnr) end,
    })
end

--- Save the buffer back to the solution file on disk.
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

    -- Apply any name edits from the buffer into the tree (structure unchanged)
    local new_root = view.parse_buffer(bufnr, s.root, s.flat)

    local new_raw
    if s.fmt == "slnx" then
        new_raw = parser.serialize_slnx(s.raw, new_root)
    elseif s.fmt == "slnf" then
        new_raw = parser.serialize_slnf(s.raw, new_root)
    else
        -- Collect all entries from the tree for the sln serialiser
        local flat = parser.flatten_tree(new_root)
        local entries = {}
        for _, item in ipairs(flat) do
            table.insert(entries, item.node.entry)
        end
        new_raw = parser.serialize_sln(s.raw, entries, s.nesting)
    end

    local lines = vim.split(new_raw, "\n", { plain = true })
    while #lines > 0 and lines[#lines] == "" do table.remove(lines) end

    local write_ok, err = pcall(vim.fn.writefile, lines, s.sln_path)
    if not write_ok then
        vim.notify("[dotnet] Write failed: " .. tostring(err), vim.log.levels.ERROR)
        return
    end

    s.raw  = new_raw
    s.root = new_root
    vim.bo[bufnr].modified = false
    vim.notify("[dotnet] Saved " .. vim.fn.fnamemodify(s.sln_path, ":t"), vim.log.levels.INFO)

    view.render(bufnr, s.sln_path, new_root)
end

-- ---------------------------------------------------------------------------
-- Bootstrap
-- ---------------------------------------------------------------------------

local view = require("dotnet.view")
view.setup_highlights()

vim.api.nvim_create_autocmd("ColorScheme", {
    group    = aug,
    callback = view.setup_highlights,
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
end, {
    desc     = "Open dotnet solution viewer",
    nargs    = "?",
    complete = "file",
})

vim.keymap.set("n", "<leader>ds", M.toggle, { desc = "Dotnet: toggle solution view" })

return M
