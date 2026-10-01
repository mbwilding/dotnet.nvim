local M = {}

local PROJECT_PATTERN = "%.[cfv][sb]?proj$"
local NS = vim.api.nvim_create_namespace("dotnet_packages")

---@class dotnet.Usage
---@field project string
---@field requested string
---@field resolved string
---@field latest string
---@field transitive boolean
---@field outdated boolean

---@class dotnet.Package
---@field id string
---@field latest string
---@field outdated boolean
---@field transitive boolean
---@field deps table<string, string>
---@field via table<string, boolean>
---@field usages dotnet.Usage[]

---@param path string
---@return boolean
function M.is_project(path)
    return path:match(PROJECT_PATTERN) ~= nil or path:match("%.esproj$") ~= nil
end

---@param all table
---@param outdated table|nil
---@return dotnet.Package[]
function M.parse(all, outdated)
    local latest = {}
    for _, proj in ipairs(outdated and outdated.projects or {}) do
        for _, fw in ipairs(proj.frameworks or {}) do
            for _, list in ipairs({ fw.topLevelPackages or {}, fw.transitivePackages or {} }) do
                for _, p in ipairs(list) do
                    local key = proj.path .. "\0" .. p.id
                    if p.latestVersion and not latest[key] then
                        latest[key] = p.latestVersion
                    end
                end
            end
        end
    end

    local by_id, order = {}, {}
    for _, proj in ipairs(all.projects or {}) do
        local seen = {}
        for _, fw in ipairs(proj.frameworks or {}) do
            for _, transitive in ipairs({ false, true }) do
                local list = transitive and fw.transitivePackages or fw.topLevelPackages
                for _, p in ipairs(list or {}) do
                    if not seen[p.id] then
                        seen[p.id] = true
                        local current = transitive and (p.resolvedVersion or "") or (p.requestedVersion or "")
                        local lat = latest[proj.path .. "\0" .. p.id] or current
                        local pkg = by_id[p.id]
                        if not pkg then
                            pkg = { id = p.id, latest = lat, outdated = false, transitive = true, usages = {} }
                            by_id[p.id] = pkg
                            table.insert(order, pkg)
                        end
                        local is_outdated = not transitive and lat:lower() ~= current:lower()
                        if is_outdated then
                            pkg.outdated = true
                            pkg.latest = lat
                        end
                        if not transitive then
                            pkg.transitive = false
                        end
                        table.insert(pkg.usages, {
                            project = proj.path,
                            requested = current,
                            resolved = p.resolvedVersion or "",
                            latest = lat,
                            transitive = transitive,
                            outdated = is_outdated,
                        })
                    end
                end
            end
        end
    end
    table.sort(order, function(a, b)
        return a.id:lower() < b.id:lower()
    end)
    return order
end

---@param scope string
---@param extra string[]
---@param no_restore boolean
---@param cb fun(json: table|nil, err: string|nil)
local function list_json(scope, extra, no_restore, cb)
    local cmd = { "dotnet", "list", scope, "package", "--include-transitive", "--format", "json" }
    vim.list_extend(cmd, extra)
    if no_restore then
        table.insert(cmd, "--no-restore")
    end
    vim.system(
        cmd,
        { text = true },
        vim.schedule_wrap(function(res)
            local ok, json = pcall(vim.json.decode, res.stdout or "")
            if not ok or type(json) ~= "table" then
                local msg = vim.trim((res.stderr or "") .. "\n" .. (res.stdout or ""))
                cb(nil, msg ~= "" and msg or "dotnet list package failed")
                return
            end
            cb(json)
        end)
    )
end

---@param json table
---@return string[]
local function problems_of(json)
    local out, seen = {}, {}
    for _, p in ipairs(json.problems or {}) do
        local text = (p.text or ""):gsub("`", ""):gsub("%.? Run restore.*$", " (needs restore)")
        local line = (p.project and (vim.fn.fnamemodify(p.project, ":t:r") .. ": ") or "") .. text
        if not seen[line] then
            seen[line] = true
            table.insert(out, line)
        end
    end
    return out
end

---@param path string
---@return table|nil
local function read_assets(path)
    local fh = io.open(path, "rb")
    if not fh then
        return nil
    end
    local text = fh:read("*a")
    fh:close()
    local ok, json = pcall(vim.json.decode, text)
    return ok and type(json) == "table" and json or nil
end

---@param pkgs dotnet.Package[]
---@param all table
local function attach_graph(pkgs, all)
    local by_id = {}
    for _, pkg in ipairs(pkgs) do
        by_id[pkg.id:lower()] = pkg
        pkg.deps = {}
        pkg.via = {}
    end
    for _, proj in ipairs(all.projects or {}) do
        local assets = read_assets(vim.fs.joinpath(vim.fs.dirname(proj.path), "obj", "project.assets.json"))
        if assets and assets.targets then
            local roots = {}
            for _, pkg in ipairs(pkgs) do
                for _, u in ipairs(pkg.usages) do
                    if u.project == proj.path and not u.transitive then
                        table.insert(roots, pkg)
                        break
                    end
                end
            end
            for _, target in pairs(assets.targets) do
                local index = {}
                for key, entry in pairs(target) do
                    local id, version = key:match("^(.-)/(.+)$")
                    if id and entry.type == "package" then
                        index[id:lower()] = { id = id, version = version, deps = entry.dependencies or {} }
                    end
                end
                for _, root in ipairs(roots) do
                    local seen = {}
                    local function walk(id)
                        local node = index[id:lower()]
                        if not node then
                            return
                        end
                        for dep in pairs(node.deps) do
                            local d = index[dep:lower()]
                            if d and not seen[dep:lower()] then
                                seen[dep:lower()] = true
                                root.deps[d.id] = d.version
                                local target_pkg = by_id[d.id:lower()]
                                if target_pkg and target_pkg ~= root then
                                    target_pkg.via[root.id] = true
                                end
                                walk(dep)
                            end
                        end
                    end
                    walk(root.id)
                end
            end
        end
    end
end

---@param all table
---@return string[]
local function project_paths(all)
    local out = {}
    for _, proj in ipairs(all.projects or {}) do
        table.insert(out, proj.path)
    end
    table.sort(out)
    return out
end

---@param scope string
---@param prerelease boolean
---@param cb fun(pkgs: dotnet.Package[]|nil, problems: string[], projects: string[]|nil)
function M.discover(scope, prerelease, cb)
    local function fetch(no_restore)
        list_json(scope, {}, no_restore, function(all, err)
            if not all then
                cb(nil, { err })
                return
            end
            if not all.projects or #all.projects == 0 then
                if not no_restore then
                    return fetch(true)
                end
                cb(nil, problems_of(all))
                return
            end
            list_json(scope, prerelease and { "--outdated", "--include-prerelease" } or { "--outdated" }, true, function(outdated)
                local pkgs = M.parse(all, outdated)
                attach_graph(pkgs, all)
                cb(pkgs, problems_of(all), project_paths(all))
            end)
        end)
    end
    fetch(false)
end

---@param text string
---@param tag string
---@param id string
---@param version string
---@return string|nil new_text
---@return string|nil err
local function set_in_tag(text, tag, id, version)
    local lid = id:lower()
    local pos = 1
    local function sub(old_value)
        if old_value:find("$(", 1, true) then
            return nil
        end
        return version
    end
    while true do
        local s, e = text:find("<" .. tag .. "%s[^>]*>", pos)
        if not s then
            return nil
        end
        local open = text:sub(s, e)
        local inc = open:match('Include%s*=%s*"([^"]*)"')
        if inc and inc:lower() == lid then
            for _, attr in ipairs({ "VersionOverride", "Version" }) do
                local old = open:match("%f[%w]" .. attr .. '%s*=%s*"([^"]*)"')
                if old then
                    local v = sub(old)
                    if not v then
                        return nil, "version is an MSBuild property"
                    end
                    local new_open = open:gsub("(%f[%w]" .. attr .. '%s*=%s*")[^"]*(")', function(a, b)
                        return a .. v .. b
                    end)
                    return text:sub(1, s - 1) .. new_open .. text:sub(e + 1)
                end
            end
            if not open:match("/>$") then
                local close_s = text:find("</" .. tag .. ">", e, true)
                local body = text:sub(e + 1, (close_s or #text + 1) - 1)
                for _, el in ipairs({ "VersionOverride", "Version" }) do
                    local old = body:match("<" .. el .. ">%s*([^<]-)%s*</" .. el .. ">")
                    if old then
                        local v = sub(old)
                        if not v then
                            return nil, "version is an MSBuild property"
                        end
                        local new_body = body:gsub("(<" .. el .. ">%s*)[^<]-(%s*</" .. el .. ">)", function(a, b)
                            return a .. v .. b
                        end, 1)
                        return text:sub(1, e) .. new_body .. text:sub(e + 1 + #body)
                    end
                end
            end
            return nil
        end
        pos = e + 1
    end
end

---@param dir string
---@return string|nil
local function find_central(dir)
    local found = vim.fs.find("Directory.Packages.props", { upward = true, path = dir, type = "file" })
    return found[1]
end

---@param path string
---@return string|nil
local function read(path)
    local fh = io.open(path, "rb")
    if not fh then
        return nil
    end
    local s = fh:read("*a")
    fh:close()
    return s
end

---@param path string
---@param text string
---@return boolean
local function write(path, text)
    local fh = io.open(path, "wb")
    if not fh then
        return false
    end
    fh:write(text)
    fh:close()
    return true
end

---@param project string
---@param id string
---@param version string
---@return string|nil file edited
---@return string|nil err
function M.set_version(project, id, version)
    local text = read(project)
    if not text then
        return nil, "cannot read " .. project
    end
    local new, err = set_in_tag(text, "PackageReference", id, version)
    if new then
        if write(project, new) then
            return project
        end
        return nil, "cannot write " .. project
    end
    if err then
        return nil, err
    end
    local central = find_central(vim.fs.dirname(project))
    if central then
        local ctext = read(central)
        local cnew, cerr = ctext and set_in_tag(ctext, "PackageVersion", id, version)
        if cnew then
            if write(central, cnew) then
                return central
            end
            return nil, "cannot write " .. central
        end
        if cerr then
            return nil, cerr
        end
    end
    return nil, "version declaration not found"
end

---@param jobs { project: string, id: string, version: string }[]
---@return integer ok
---@return string[] errors
function M.apply(jobs)
    local ok, errors, done = 0, {}, {}
    for _, job in ipairs(jobs) do
        local central_key = job.id .. "@" .. job.version
        local file, err = M.set_version(job.project, job.id, job.version)
        if file then
            local key = file .. "|" .. central_key
            if not done[key] then
                done[key] = true
                ok = ok + 1
            end
        else
            table.insert(errors, string.format("%s %s: %s", vim.fn.fnamemodify(job.project, ":t"), job.id, err))
        end
    end
    return ok, errors
end

---@class dotnet.PackagesView
---@field buf integer
---@field scope string
---@field pkgs dotnet.Package[]
---@field problems string[]
---@field rows table[]
---@field selected table<string, boolean>
---@field status string
---@field expanded table<string, boolean>
---@field tab "installed"|"upgrades"|"consolidate"|"browse"
---@field projects string[]
---@field query string
---@field results table[]
---@field loading boolean
---@field browse_versions table<string, string>
---@field prerelease boolean
---@field positioned boolean?
---@field vlines table[]
---@field win integer?
---@field width integer

---@type table<integer, dotnet.PackagesView>
local views = {}

local TABS = { "installed", "transitive", "upgrades", "consolidate", "browse" }
local TAB_TITLES = {
    installed = "Installed",
    transitive = "Transitive",
    upgrades = "Upgrades",
    consolidate = "Consolidate",
    browse = "Browse",
}
local MAX_NAME = 48

---@param ver string
---@return number[] nums
---@return string pre
local function split_version(ver)
    local core, pre = ver:match("^([^%-+]*)%-?([^+]*)")
    local nums = {}
    for n in (core or ""):gmatch("%d+") do
        table.insert(nums, tonumber(n))
    end
    return nums, pre or ""
end

---@param a string
---@param b string
---@return integer
local function compare_versions(a, b)
    local an, ap = split_version(a)
    local bn, bp = split_version(b)
    for i = 1, math.max(#an, #bn) do
        local x, y = an[i] or 0, bn[i] or 0
        if x ~= y then
            return x < y and -1 or 1
        end
    end
    if ap == bp then
        return 0
    end
    if ap == "" then
        return 1
    end
    if bp == "" then
        return -1
    end
    return ap < bp and -1 or 1
end

---@param pkg dotnet.Package
---@return string[] distinct declared versions of direct usages
---@return string highest
local function direct_versions(pkg)
    local set, list, highest = {}, {}, ""
    for _, u in ipairs(pkg.usages) do
        if not u.transitive and not set[u.requested] then
            set[u.requested] = true
            table.insert(list, u.requested)
            if highest == "" or compare_versions(u.requested, highest) > 0 then
                highest = u.requested
            end
        end
    end
    return list, highest
end

local function row_key(row)
    if row.kind == "result" then
        return "result\0" .. row.res.id
    end
    if row.kind == "pkg" then
        return row.pkg.id
    end
    return row.pkg.id .. "\0" .. row.usage.project
end

---@param v dotnet.PackagesView
---@param key string
---@param default boolean
local function is_open(v, key, default)
    local state = v.expanded[key]
    if state == nil then
        return default
    end
    return state
end

---@param pkg dotnet.Package
---@return string
local function current_text(pkg)
    local list = direct_versions(pkg)
    if #list == 0 then
        local u = pkg.usages[1]
        return u and u.requested or ""
    end
    return #list == 1 and list[1] or "mixed"
end

---@param v dotnet.PackagesView
---@return table<string, integer>
local function counts(v)
    local c = { installed = 0, transitive = 0, upgrades = 0, consolidate = 0, browse = #v.results }
    for _, pkg in ipairs(v.pkgs) do
        c[pkg.transitive and "transitive" or "installed"] = c[pkg.transitive and "transitive" or "installed"] + 1
        if pkg.outdated then
            c.upgrades = c.upgrades + 1
        end
        if #direct_versions(pkg) > 1 then
            c.consolidate = c.consolidate + 1
        end
    end
    return c
end

local ICON = {
    open = vim.fn.nr2char(0xf0d7),
    closed = vim.fn.nr2char(0xf0da),
    on = vim.fn.nr2char(0xf046),
    off = vim.fn.nr2char(0xf096),
}

local function setup_highlights()
    require("volt.highlights")
    local function get(name)
        local ok, h = pcall(vim.api.nvim_get_hl, 0, { name = name, link = false })
        return ok and h or {}
    end
    local normal = get("Normal")
    local band = get("ExBlack2Bg").bg or get("CursorLine").bg
    local band2 = get("ExBlack3Bg").bg or get("Visual").bg
    local blue = get("ExBlue").fg or get("Function").fg
    local green = get("ExGreen").fg or get("DiagnosticOk").fg
    local yellow = get("ExYellow").fg or get("DiagnosticWarn").fg
    local muted = get("CommentFg").fg or get("Comment").fg
    local set = vim.api.nvim_set_hl
    set(0, "DotnetPkgBand", { bg = band, fg = normal.fg })
    set(0, "DotnetPkgTitle", { bg = band, fg = blue, bold = true })
    set(0, "DotnetPkgMuted", { bg = band, fg = muted })
    set(0, "DotnetPkgKey", { bg = band, fg = yellow, bold = true })
    set(0, "DotnetPkgTabOn", { bg = blue, fg = normal.bg or 0, bold = true })
    set(0, "DotnetPkgTabOff", { bg = band2, fg = muted })
    set(0, "DotnetPkgColHead", { bg = band2, fg = muted, bold = true })
    set(0, "DotnetPkgGroup", { bg = band2, fg = blue, bold = true })
    set(0, "DotnetPkgName", { fg = normal.fg })
    set(0, "DotnetPkgLink", { fg = blue })
    set(0, "DotnetPkgDim", { fg = muted })
    set(0, "DotnetPkgOk", { fg = green })
    set(0, "DotnetPkgWarn", { fg = yellow })
    set(0, "DotnetPkgRule", { fg = band2 or muted })
end

---@param v dotnet.PackagesView
local function paint(v)
    local buf = v.buf
    if not vim.api.nvim_buf_is_valid(buf) then
        return
    end
    setup_highlights()
    local cursor = v.win and vim.api.nvim_win_is_valid(v.win) and vim.api.nvim_win_get_cursor(v.win) or nil
    local volt = require("volt")
    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_clear_namespace(buf, NS, 0, -1)
    volt.gen_data({
        {
            buf = buf,
            ns = NS,
            xpad = 0,
            layout = {
                {
                    name = "list",
                    lines = function()
                        return vim.deepcopy(v.vlines)
                    end,
                },
            },
        },
    })
    volt.run(buf, { h = #v.vlines, w = v.width })
    if cursor then
        pcall(vim.api.nvim_win_set_cursor, v.win, { math.min(cursor[1], #v.vlines), cursor[2] })
    end
end

local HINTS = {
    { "<CR>", "fold" },
    { "<Tab>", "select" },
    { "u", "update" },
    { "U", "update all" },
    { "v", "version" },
    { "a", "add" },
    { "d", "remove" },
    { "/", "search" },
    { "P", "prerelease" },
    { "[ ]", "tabs" },
    { "r", "refresh" },
    { "q", "close" },
}

local COLUMNS = {
    installed = { "Package", "Installed", "Latest", "Used by" },
    transitive = { "Package", "Resolved", "Required by", "Used by" },
    upgrades = { "Package", "Installed", "Latest", "Used by" },
    consolidate = { "Package", "Declared", "Target", "Used by" },
    browse = { "Package", "Version", "Downloads", "Status" },
}

---@param text string
---@param w integer
---@return string
local function fit(text, w)
    local len = vim.fn.strwidth(text)
    if len > w then
        return vim.fn.strcharpart(text, 0, w - 1) .. "…"
    end
    return text .. string.rep(" ", w - len)
end

---@param v dotnet.PackagesView
local function render(v)
    local c = counts(v)
    local vl, rows = {}, {}
    local W = v.width

    local function line(cells)
        table.insert(vl, cells)
        return #vl
    end
    local function band(cells, hl)
        local used = 0
        for _, cell in ipairs(cells) do
            used = used + vim.fn.strwidth(cell[1])
        end
        table.insert(cells, { string.rep(" ", math.max(W - used, 0)), hl })
        return line(cells)
    end
    local function rule()
        line({ { string.rep("─", W), "DotnetPkgRule" } })
    end

    local title = {
        { "  ", "DotnetPkgBand" },
        { " NuGet ", "DotnetPkgTabOn" },
        { "  " .. vim.fn.fnamemodify(v.scope, ":t"), "DotnetPkgTitle" },
    }
    if v.prerelease then
        table.insert(title, { "  prerelease", "DotnetPkgKey" })
    end
    if v.status ~= "" then
        table.insert(title, { "  " .. v.status, "DotnetPkgMuted" })
    end
    if v.tab == "browse" then
        table.insert(title, { "   search: ", "DotnetPkgMuted" })
        table.insert(title, { v.query ~= "" and v.query or "press /", "DotnetPkgBand" })
    end
    band(title, "DotnetPkgBand")

    local tabs = { { "  ", "DotnetPkgBand" } }
    for _, t in ipairs(TABS) do
        table.insert(tabs, {
            string.format(" %s  %d ", TAB_TITLES[t], c[t]),
            t == v.tab and "DotnetPkgTabOn" or "DotnetPkgTabOff",
            function()
                v.tab = t
                v.selected = {}
                render(v)
            end,
        })
        table.insert(tabs, { " ", "DotnetPkgBand" })
    end
    band(tabs, "DotnetPkgBand")

    local hints = { { "  ", "DotnetPkgBand" } }
    for _, h in ipairs(HINTS) do
        table.insert(hints, { h[1], "DotnetPkgKey" })
        table.insert(hints, { " " .. h[2] .. "   ", "DotnetPkgMuted" })
    end
    band(hints, "DotnetPkgBand")

    local namew = 12
    local verw = 14
    for _, pkg in ipairs(v.pkgs) do
        namew = math.max(namew, math.min(#pkg.id, MAX_NAME))
        verw = math.max(verw, math.min(#current_text(pkg), 24), math.min(#pkg.latest, 24))
    end
    namew = namew + 2
    verw = verw + 2

    local cols = COLUMNS[v.tab]
    band({
        { "    " .. fit(cols[1], namew), "DotnetPkgColHead" },
        { fit(cols[2], verw), "DotnetPkgColHead" },
        { fit(cols[3], v.tab == "transitive" and verw + 22 or verw), "DotnetPkgColHead" },
        { cols[4], "DotnetPkgColHead" },
    }, "DotnetPkgColHead")

    local function target(pkg)
        if v.tab == "consolidate" then
            local _, highest = direct_versions(pkg)
            return highest
        end
        return pkg.latest
    end

    local function needs_update(pkg, u)
        if u.transitive then
            return false
        end
        if v.tab == "consolidate" then
            local _, highest = direct_versions(pkg)
            return u.requested ~= highest
        end
        return u.outdated
    end

    local function select_cell(row)
        local on = v.selected[row_key(row)]
        return {
            (on and ICON.on or ICON.off) .. " ",
            on and "DotnetPkgOk" or "DotnetPkgDim",
            function()
                v.selected[row_key(row)] = not on or nil
                render(v)
            end,
        }
    end

    local function third_cell(pkg, actionable)
        if v.tab == "transitive" then
            local names = vim.tbl_keys(pkg.via or {})
            table.sort(names, function(a, b)
                return a:lower() < b:lower()
            end)
            return { fit(table.concat(names, ", "), verw + 20) .. "  ", "DotnetPkgLink" }
        end
        return { fit(actionable and ("→ " .. target(pkg)) or "", verw), "DotnetPkgOk" }
    end

    local function add_pkg(pkg, indent)
        local prow = { kind = "pkg", pkg = pkg, key = v.tab .. ":pkg:" .. pkg.id }
        table.insert(rows, prow)
        local actionable = false
        for _, u in ipairs(pkg.usages) do
            actionable = actionable or needs_update(pkg, u)
        end
        local open = is_open(v, prow.key, v.tab ~= "installed" and actionable)
        local cur = current_text(pkg)
        prow.line = line({
            {
                indent .. (open and ICON.open or ICON.closed) .. " ",
                "DotnetPkgDim",
                function()
                    v.expanded[prow.key] = not open
                    render(v)
                end,
            },
            select_cell(prow),
            { fit(pkg.id, namew), pkg.transitive and "DotnetPkgDim" or "DotnetPkgName" },
            { fit(cur, verw), cur == "mixed" and "DotnetPkgWarn" or "DotnetPkgDim" },
            third_cell(pkg, actionable),
            { string.format("%d project%s", #pkg.usages, #pkg.usages == 1 and "" or "s"), "DotnetPkgDim" },
        })
        if not open then
            return
        end
        for i, u in ipairs(pkg.usages) do
            local urow = { kind = "proj", pkg = pkg, usage = u }
            table.insert(rows, urow)
            urow.line = line({
                { indent .. "  " .. (i == #pkg.usages and "└" or "├") .. " ", "DotnetPkgRule" },
                select_cell(urow),
                { fit(vim.fn.fnamemodify(u.project, ":t:r"), namew - 2), "DotnetPkgLink" },
                { fit(u.requested, verw), "DotnetPkgDim" },
                { fit(needs_update(pkg, u) and ("→ " .. target(pkg)) or "", verw), "DotnetPkgOk" },
                { u.transitive and "transitive" or "", "DotnetPkgDim" },
            })
        end
        local dep_ids = vim.tbl_keys(pkg.deps or {})
        if #dep_ids > 0 then
            table.sort(dep_ids, function(a, b)
                return a:lower() < b:lower()
            end)
            local drow = { kind = "group", key = v.tab .. ":deps:" .. pkg.id }
            table.insert(rows, drow)
            local dopen = is_open(v, drow.key, false)
            drow.line = line({
                {
                    indent .. "  " .. (dopen and ICON.open or ICON.closed) .. " Dependencies (" .. #dep_ids .. ")",
                    "DotnetPkgDim",
                    function()
                        v.expanded[drow.key] = not dopen
                        render(v)
                    end,
                },
            })
            if dopen then
                for i, id in ipairs(dep_ids) do
                    line({
                        { indent .. "    " .. (i == #dep_ids and "└" or "├") .. " ", "DotnetPkgRule" },
                        { "  ", "DotnetPkgDim" },
                        { fit(id, namew - 2), "DotnetPkgDim" },
                        { fit(pkg.deps[id], verw), "DotnetPkgDim" },
                    })
                end
            end
        end
    end

    if v.tab == "browse" then
        local installed = {}
        for _, pkg in ipairs(v.pkgs) do
            installed[pkg.id:lower()] = current_text(pkg)
        end
        for _, res in ipairs(v.results) do
            local row = { kind = "result", res = res }
            table.insert(rows, row)
            local have = installed[res.id:lower()]
            row.line = line({
                { "  ", "DotnetPkgDim" },
                select_cell(row),
                { fit(res.id, namew), have and "DotnetPkgDim" or "DotnetPkgName" },
                { fit(v.browse_versions[res.id] or res.version, verw), "DotnetPkgOk" },
                { fit(res.downloads, verw), "DotnetPkgDim" },
                { have and ("installed " .. have) or "", "DotnetPkgWarn" },
            })
        end
        if v.loading then
            line({ { "  searching...", "DotnetPkgDim" } })
        elseif #v.results == 0 then
            line({ { v.query ~= "" and "  no results" or "  press / to search", "DotnetPkgDim" } })
        end
    end

    for _, pkg in ipairs(v.pkgs) do
        local include = not pkg.transitive
        if v.tab == "browse" then
            include = false
        elseif v.tab == "transitive" then
            include = pkg.transitive
        elseif v.tab == "upgrades" then
            include = pkg.outdated
        elseif v.tab == "consolidate" then
            include = #direct_versions(pkg) > 1
        end
        if include then
            add_pkg(pkg, "")
        end
    end
    if v.tab ~= "browse" and #rows == 0 and v.status == "" then
        line({ { "  nothing to show", "DotnetPkgDim" } })
    end

    if #v.problems > 0 then
        rule()
        line({ { "  Skipped projects", "DotnetPkgWarn" } })
        for _, p in ipairs(v.problems) do
            line({ { "    " .. p, "DotnetPkgDim" } })
        end
    end

    v.rows = rows
    v.vlines = vl
    paint(v)
end

---@param v dotnet.PackagesView
local function refresh(v)
    v.status = "loading..."
    render(v)
    M.discover(v.scope, v.prerelease, function(pkgs, problems, projects)
        if not vim.api.nvim_buf_is_valid(v.buf) then
            return
        end
        v.pkgs = pkgs or {}
        v.projects = projects or {}
        v.problems = problems
        v.selected = {}
        v.status = pkgs and "" or "error"
        render(v)
        if not v.positioned and v.rows[1] and vim.api.nvim_win_is_valid(v.win) then
            v.positioned = true
            vim.api.nvim_win_set_cursor(v.win, { v.rows[1].line, 0 })
        end
    end)
end

---@param v dotnet.PackagesView
---@param rows table[]
---@param version_for fun(pkg: dotnet.Package, u: dotnet.Usage): string|nil
local function update_rows(v, rows, version_for)
    local jobs, seen = {}, {}
    for _, row in ipairs(rows) do
        local usages = row.kind == "pkg" and row.pkg.usages or row.kind == "proj" and { row.usage } or {}
        for _, u in ipairs(usages) do
            local key = u.project .. "\0" .. row.pkg.id
            local version = not u.transitive and version_for(row.pkg, u)
            if version and not seen[key] then
                seen[key] = true
                table.insert(jobs, { project = u.project, id = row.pkg.id, version = version })
            end
        end
    end
    if #jobs == 0 then
        vim.notify("[dotnet] Nothing to update (already latest or transitive)", vim.log.levels.INFO)
        return
    end
    local ok, errors = M.apply(jobs)
    vim.cmd("silent! checktime")
    local level = #errors > 0 and vim.log.levels.WARN or vim.log.levels.INFO
    local msg = string.format("[dotnet] Updated %d declaration(s)", ok)
    if #errors > 0 then
        msg = msg .. "\n" .. table.concat(errors, "\n")
    end
    vim.notify(msg, level)
    refresh(v)
end

---@param v dotnet.PackagesView
---@return fun(pkg: dotnet.Package, u: dotnet.Usage): string|nil
local function tab_version_for(v)
    if v.tab == "consolidate" then
        return function(pkg, u)
            local _, highest = direct_versions(pkg)
            return u.requested ~= highest and highest or nil
        end
    end
    return function(_, u)
        return u.outdated and u.latest or nil
    end
end

---@param args string[]
---@param cb fun(packages: table[]|nil)
local function package_search(args, cb)
    local cmd = { "dotnet", "package", "search" }
    vim.list_extend(cmd, args)
    vim.list_extend(cmd, { "--format", "json" })
    vim.system(
        cmd,
        { text = true },
        vim.schedule_wrap(function(res)
            local ok, json = pcall(vim.json.decode, res.stdout or "")
            if res.code ~= 0 or not ok or type(json) ~= "table" or not json.searchResult then
                cb(nil)
                return
            end
            local out = {}
            for _, source in ipairs(json.searchResult) do
                vim.list_extend(out, source.packages or {})
            end
            cb(out)
        end)
    )
end

---@param id string
---@param prerelease boolean
---@param cb fun(versions: string[]|nil)
local function fetch_versions(id, prerelease, cb)
    package_search({ id, "--exact-match", "--prerelease" }, function(packages)
        if not packages then
            cb(nil)
            return
        end
        local seen, versions = {}, {}
        for _, p in ipairs(packages) do
            if p.version and not seen[p.version] and (prerelease or not p.version:find("-", 1, true)) then
                seen[p.version] = true
                table.insert(versions, p.version)
            end
        end
        table.sort(versions, function(a, b)
            local a_pre, b_pre = a:find("-", 1, true) ~= nil, b:find("-", 1, true) ~= nil
            if a_pre ~= b_pre then
                return not a_pre
            end
            return compare_versions(a, b) > 0
        end)
        cb(#versions > 0 and versions or nil)
    end)
end

---@param query string
---@param prerelease boolean
---@param cb fun(results: table[]|nil)
local function search_nuget(query, prerelease, cb)
    local args = { query, "--take", "40" }
    if prerelease then
        table.insert(args, "--prerelease")
    end
    package_search(args, function(packages)
        if not packages then
            cb(nil)
            return
        end
        local out, seen = {}, {}
        for _, d in ipairs(packages) do
            if d.id and not seen[d.id:lower()] then
                seen[d.id:lower()] = true
                local n = d.totalDownloads or 0
                local dl = n >= 1e6 and string.format("%.1fM", n / 1e6)
                    or n >= 1e3 and string.format("%.1fK", n / 1e3)
                    or tostring(n)
                table.insert(out, { id = d.id, version = d.latestVersion or d.version or "", downloads = dl })
            end
        end
        cb(out)
    end)
end

---@param cmds { cmd: string[], label: string }[]
---@param cb fun(ok: integer, errors: string[])
local function run_cmds(cmds, cb)
    local ok, errors, i = 0, {}, 0
    local function next_cmd()
        i = i + 1
        if i > #cmds then
            cb(ok, errors)
            return
        end
        local job = cmds[i]
        vim.system(job.cmd, { text = true }, vim.schedule_wrap(function(res)
            if res.code == 0 then
                ok = ok + 1
            else
                local out = vim.trim(res.stderr ~= "" and res.stderr or res.stdout or "")
                table.insert(errors, job.label .. ": " .. (out:match("[^\n]*") or ""))
            end
            next_cmd()
        end))
    end
    next_cmd()
end

---@param v dotnet.PackagesView
local function current_row(v)
    local lnum = vim.api.nvim_win_get_cursor(0)[1]
    for _, row in ipairs(v.rows) do
        if row.line == lnum then
            return row
        end
    end
end

---@param scope string sln, slnx, slnf or project file
function M.open(scope)
    if not pcall(require, "volt") then
        vim.notify("[dotnet] The packages view needs NvChad/volt (NvUI). Install it and try again.", vim.log.levels.ERROR)
        return
    end
    if vim.fn.executable("dotnet") ~= 1 then
        vim.notify("[dotnet] dotnet CLI not found", vim.log.levels.ERROR)
        return
    end
    local buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buf].buftype = "nofile"
    vim.bo[buf].bufhidden = "wipe"
    vim.bo[buf].swapfile = false
    vim.bo[buf].filetype = "dotnet-packages"
    vim.api.nvim_buf_set_name(buf, "dotnet-packages://" .. scope)

    local v = {
        buf = buf,
        scope = scope,
        pkgs = {},
        problems = {},
        rows = {},
        selected = {},
        status = "",
        expanded = {},
        tab = "installed",
        projects = {},
        query = "",
        results = {},
        loading = false,
        browse_versions = {},
        vlines = {},
        prerelease = require("dotnet.config").values.prerelease == true,
        width = 80,
    }
    views[buf] = v

    require("volt").mappings({ bufs = { buf } })
    require("volt.events").add(buf)

    local function map(lhs, fn)
        vim.keymap.set("n", lhs, fn, { buffer = buf, nowait = true, silent = true })
    end

    local function switch_tab(delta)
        local idx = 1
        for i, t in ipairs(TABS) do
            if t == v.tab then
                idx = i
            end
        end
        v.tab = TABS[(idx - 1 + delta) % #TABS + 1]
        v.selected = {}
        render(v)
        local first = v.rows[1]
        vim.api.nvim_win_set_cursor(0, { first and first.line or 1, 0 })
    end
    map("]", function()
        switch_tab(1)
    end)
    map("[", function()
        switch_tab(-1)
    end)

    map("<CR>", function()
        local row = current_row(v)
        if not row then
            return
        end
        if row.kind == "proj" then
            for _, r in ipairs(v.rows) do
                if r.kind == "pkg" and r.pkg == row.pkg then
                    row = r
                end
            end
        end
        if row.key then
            v.expanded[row.key] = not is_open(v, row.key, false)
            render(v)
            vim.api.nvim_win_set_cursor(0, { math.min(row.line, vim.api.nvim_buf_line_count(buf)), 0 })
        end
    end)
    map("<Tab>", function()
        local row = current_row(v)
        if row and row.kind ~= "group" then
            local key = row_key(row)
            v.selected[key] = not v.selected[key] or nil
            local lnum = row.line
            render(v)
            vim.api.nvim_win_set_cursor(0, { math.min(lnum + 1, vim.api.nvim_buf_line_count(buf)), 0 })
        end
    end)
    map("u", function()
        local rows = {}
        for _, row in ipairs(v.rows) do
            if row.kind ~= "group" and v.selected[row_key(row)] then
                table.insert(rows, row)
            end
        end
        if #rows == 0 then
            local row = current_row(v)
            rows = row and { row } or {}
        end
        update_rows(v, rows, tab_version_for(v))
    end)
    map("U", function()
        local rows = {}
        for _, row in ipairs(v.rows) do
            if row.kind == "pkg" then
                table.insert(rows, row)
            end
        end
        update_rows(v, rows, tab_version_for(v))
    end)
    map("v", function()
        local row = current_row(v)
        if not row or row.kind == "group" then
            return
        end
        local id = row.kind == "result" and row.res.id or row.pkg.id
        fetch_versions(id, v.prerelease, function(versions)
            if not versions then
                vim.notify("[dotnet] Could not fetch versions for " .. id .. " from the package sources", vim.log.levels.WARN)
                return
            end
            local shown = vim.list_slice(versions, 1, 60)
            vim.ui.select(shown, { prompt = id .. " version" }, function(choice)
                if choice and row.kind == "result" then
                    v.browse_versions[id] = choice
                    render(v)
                elseif choice then
                    update_rows(v, { row }, function(_, u)
                        return u.requested ~= choice and choice or nil
                    end)
                end
            end)
        end)
    end)
    local function search()
        vim.ui.input({ prompt = "NuGet search: ", default = v.query }, function(q)
            if not q or vim.trim(q) == "" then
                return
            end
            v.query = vim.trim(q)
            v.tab = "browse"
            v.selected = {}
            v.loading = true
            render(v)
            search_nuget(v.query, v.prerelease, function(results)
                v.loading = false
                if not results then
                    vim.notify("[dotnet] NuGet search failed (needs network and SDK 8.0.400+)", vim.log.levels.WARN)
                end
                v.results = results or {}
                if vim.api.nvim_buf_is_valid(buf) then
                    render(v)
                end
            end)
        end)
    end
    map("/", search)

    map("a", function()
        if v.tab ~= "browse" then
            search()
            return
        end
        local rows = {}
        for _, row in ipairs(v.rows) do
            if row.kind == "result" and v.selected[row_key(row)] then
                table.insert(rows, row)
            end
        end
        if #rows == 0 then
            local row = current_row(v)
            if row and row.kind == "result" then
                rows = { row }
            end
        end
        if #rows == 0 then
            return
        end
        if #v.projects == 0 then
            vim.notify("[dotnet] No projects available to add to", vim.log.levels.WARN)
            return
        end
        local choices = { "All projects" }
        for _, proj in ipairs(v.projects) do
            table.insert(choices, vim.fn.fnamemodify(proj, ":t:r"))
        end
        vim.ui.select(choices, { prompt = "Add to" }, function(_, idx)
            if not idx then
                return
            end
            local targets = idx == 1 and v.projects or { v.projects[idx - 1] }
            local cmds = {}
            for _, row in ipairs(rows) do
                local version = v.browse_versions[row.res.id] or row.res.version
                for _, proj in ipairs(targets) do
                    table.insert(cmds, {
                        cmd = { "dotnet", "add", proj, "package", row.res.id, "--version", version },
                        label = vim.fn.fnamemodify(proj, ":t:r") .. " " .. row.res.id,
                    })
                end
            end
            vim.notify(string.format("[dotnet] Adding %d package reference(s)...", #cmds), vim.log.levels.INFO)
            run_cmds(cmds, function(ok, errors)
                vim.cmd("silent! checktime")
                local msg = string.format("[dotnet] Added %d package reference(s)", ok)
                if #errors > 0 then
                    msg = msg .. "\n" .. table.concat(errors, "\n")
                end
                vim.notify(msg, #errors > 0 and vim.log.levels.WARN or vim.log.levels.INFO)
                v.selected = {}
                refresh(v)
            end)
        end)
    end)

    map("d", function()
        local rows = {}
        for _, row in ipairs(v.rows) do
            if (row.kind == "pkg" or row.kind == "proj") and v.selected[row_key(row)] then
                table.insert(rows, row)
            end
        end
        if #rows == 0 then
            local row = current_row(v)
            if row and (row.kind == "pkg" or row.kind == "proj") then
                rows = { row }
            end
        end
        local cmds, seen = {}, {}
        for _, row in ipairs(rows) do
            local usages = row.kind == "pkg" and row.pkg.usages or { row.usage }
            for _, u in ipairs(usages) do
                local key = u.project .. "\0" .. row.pkg.id
                if not u.transitive and not seen[key] then
                    seen[key] = true
                    table.insert(cmds, {
                        cmd = { "dotnet", "remove", u.project, "package", row.pkg.id },
                        label = vim.fn.fnamemodify(u.project, ":t:r") .. " " .. row.pkg.id,
                    })
                end
            end
        end
        if #cmds == 0 then
            vim.notify("[dotnet] Nothing to remove (transitive packages have no declaration)", vim.log.levels.INFO)
            return
        end
        local names = {}
        for _, c in ipairs(cmds) do
            table.insert(names, c.label)
        end
        local shown = #names > 12 and vim.list_extend(vim.list_slice(names, 1, 12), { "..." }) or names
        local prompt = string.format("Remove %d package reference(s)?\n%s", #cmds, table.concat(shown, "\n"))
        if vim.fn.confirm(prompt, "&Yes\n&No", 2) ~= 1 then
            return
        end
        run_cmds(cmds, function(ok, errors)
            vim.cmd("silent! checktime")
            local msg = string.format("[dotnet] Removed %d package reference(s)", ok)
            if #errors > 0 then
                msg = msg .. "\n" .. table.concat(errors, "\n")
            end
            vim.notify(msg, #errors > 0 and vim.log.levels.WARN or vim.log.levels.INFO)
            v.selected = {}
            refresh(v)
        end)
    end)

    map("P", function()
        v.prerelease = not v.prerelease
        refresh(v)
    end)
    map("r", function()
        refresh(v)
    end)
    map("q", function()
        if vim.api.nvim_win_is_valid(v.win) then
            vim.api.nvim_win_close(v.win, true)
        end
    end)

    vim.api.nvim_create_autocmd("BufWipeout", {
        buffer = buf,
        once = true,
        callback = function()
            views[buf] = nil
            require("volt.state")[buf] = nil
            local bufs = require("volt.events").bufs
            for i = #bufs, 1, -1 do
                if bufs[i] == buf then
                    table.remove(bufs, i)
                end
            end
        end,
    })

    local function fullscreen()
        return {
            relative = "editor",
            width = vim.o.columns,
            height = vim.o.lines - vim.o.cmdheight - (vim.o.laststatus > 0 and 1 or 0),
            col = 0,
            row = 0,
        }
    end
    v.width = vim.o.columns
    v.win = vim.api.nvim_open_win(
        buf,
        true,
        vim.tbl_extend("force", fullscreen(), { style = "minimal", border = "none", zindex = 50 })
    )
    vim.api.nvim_create_autocmd({ "VimResized", "WinResized" }, {
        group = vim.api.nvim_create_augroup("DotnetPackages" .. buf, { clear = true }),
        callback = function()
            if not vim.api.nvim_win_is_valid(v.win) then
                return true
            end
            vim.api.nvim_win_set_config(v.win, fullscreen())
            v.width = vim.o.columns
            render(v)
        end,
    })
    vim.wo[v.win].cursorline = true
    vim.wo[v.win].wrap = false
    refresh(v)
end

return M
