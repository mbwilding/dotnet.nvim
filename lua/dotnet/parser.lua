--- Parsers for .sln, .slnx, .slnf solution formats.
---
--- Project entry shape:
---   { name: string, path: string, type_guid: string|nil, id: string|nil, is_folder: boolean }
---
--- Tree node shape:
---   { entry: project_entry, children: tree_node[] }
---   Root is a synthetic node: { entry: nil, children: [...] }

local M = {}

-- Known project type GUIDs
local TYPE_GUID_NAMES = {
    ["FAE04EC0-301F-11D3-BF4B-00C04F79EFBC"] = "csproj",
    ["9A19103F-16F7-4668-BE54-9A1E7A4F7556"] = "csproj", -- SDK-style
    ["F2A71F9B-5D33-465A-A702-920D77279786"] = "fsproj",
    ["13B669BE-BB05-4DDF-9536-439F39A36129"] = "fsproj",
    ["778DAE3C-4631-46EA-AA77-85C1314464D9"] = "vbproj",
    ["8BB2217D-0F2D-49D1-97BC-3654ED321F3B"] = "esproj",
    ["54A90642-561A-4BB1-A94E-469ADEE60C69"] = "esproj", -- VS esproj
    ["54435603-DBB4-11D2-8724-00A0C9A8B90C"] = "vdproj",
    ["2150E333-8FDC-42A3-9474-1A3956D46DE8"] = "_folder",
}

local FOLDER_GUID = "2150E333-8FDC-42A3-9474-1A3956D46DE8"

--- Detect format from file extension.
---@param path string
---@return "sln"|"slnx"|"slnf"
function M.detect(path)
    local ext = path:match("%.(%a+)$"):lower()
    if ext == "slnx" then return "slnx" end
    if ext == "slnf" then return "slnf" end
    return "sln"
end

--- Return a short human-readable project type label.
---@param type_guid string|nil
---@param path string|nil
---@return string
function M.project_type(type_guid, path)
    if type_guid then
        local known = TYPE_GUID_NAMES[type_guid:upper()]
        if known then return known end
    end
    local ext = path and path:match("%.([^%.]+)$")
    return ext and ext:lower() or "project"
end

--- Whether a project entry is a solution folder.
---@param entry table
---@return boolean
function M.is_folder(entry)
    return entry.is_folder == true
end

--- Normalise path separators to forward slash.
---@param p string
---@return string
local function fwd(p) return p:gsub("\\", "/") end

--- Normalise path separators to backslash (for .sln writing).
---@param p string
---@return string
local function back(p) return p:gsub("/", "\\") end

-- --------------------------------------------------------------------------
-- Tree building
-- --------------------------------------------------------------------------

--- Build a tree from a flat entry list and a child→parent id map.
--- Preserves the original sln ordering within each parent.
--- Returns a root node whose children are the top-level entries.
---@param entries table[]  All entries (folders + projects), each with an .id field
---@param nesting table<string,string>  child_id -> parent_id (both uppercase)
---@return table root_node
function M.build_tree(entries, nesting)
    -- Build one node per entry, keyed by id. Use a stable array index as
    -- fallback key for the rare id-less entry so duplicates never collide.
    local nodes = {}
    for i, e in ipairs(entries) do
        local key = e.id and e.id:upper() or ("__idx_" .. i)
        nodes[key] = { entry = e, children = {} }
    end

    local root = { entry = nil, children = {} }

    -- Insert each node under its parent, preserving sln file order.
    for i, e in ipairs(entries) do
        local key = e.id and e.id:upper() or ("__idx_" .. i)
        local node = nodes[key]
        local parent_id = e.id and nesting[e.id:upper()]
        if parent_id then
            local parent_node = nodes[parent_id:upper()]
            if parent_node then
                table.insert(parent_node.children, node)
            else
                table.insert(root.children, node)
            end
        else
            table.insert(root.children, node)
        end
    end

    -- Sort children at every level alphabetically (case-insensitive),
    -- matching Visual Studio Solution Explorer's display order.
    local function sort_children(node)
        table.sort(node.children, function(a, b)
            return a.entry.name:lower() < b.entry.name:lower()
        end)
        for _, child in ipairs(node.children) do
            sort_children(child)
        end
    end
    sort_children(root)

    return root
end

-- --------------------------------------------------------------------------
-- .sln parser
-- --------------------------------------------------------------------------

---@param text string Raw .sln content
---@return table[] entries, table<string,string> nesting
function M.parse_sln(text)
    local entries = {}
    for type_guid, name, path, id in text:gmatch(
        'Project%("{([^}]+)}"%)'
        .. '%s*=%s*"([^"]+)",%s*"([^"]+)",%s*"{([^}]+)}"'
    ) do
        local tg = type_guid:upper()
        table.insert(entries, {
            name = name,
            path = fwd(path),
            type_guid = tg,
            id = id:upper(),
            is_folder = (tg == FOLDER_GUID),
        })
    end

    -- Parse GlobalSection(NestedProjects)
    local nesting = {}
    local nested_block = text:match("GlobalSection%(NestedProjects%)[^\n]*\n(.-)EndGlobalSection")
    if nested_block then
        for child, parent in nested_block:gmatch("{([A-Fa-f0-9%-]+)}%s*=%s*{([A-Fa-f0-9%-]+)}") do
            nesting[child:upper()] = parent:upper()
        end
    end

    return entries, nesting
end

---@param text string Original .sln text
---@param entries table[] All entries (folders + projects), possibly modified
---@param nesting table<string,string> child_id -> parent_id
---@return string
function M.serialize_sln(text, entries, nesting)
    local by_id = {}
    for _, e in ipairs(entries) do
        if e.id then by_id[e.id:upper()] = e end
    end

    local new_entries = {}
    for _, e in ipairs(entries) do
        if not e.id then table.insert(new_entries, e) end
    end

    -- Rebuild Project blocks line by line.
    -- ProjectSection(...) / EndProjectSection blocks inside a kept Project
    -- are preserved verbatim; inside a removed Project they are dropped.
    local result_lines = {}
    local in_block = false
    local in_project_section = false
    local skip_block = false

    for line in (text .. "\n"):gmatch("([^\n]*)\n") do
        if not in_block then
            local id = line:match('^Project%("{[^}]+}"%)[^{]*{([A-Fa-f0-9%-]+)}%s*$')
            if id then
                local p = by_id[id:upper()]
                if p then
                    table.insert(result_lines, string.format(
                        'Project("{%s}") = "%s", "%s", "{%s}"',
                        p.type_guid or FOLDER_GUID,
                        p.name,
                        back(p.path),
                        p.id
                    ))
                    skip_block = false
                else
                    skip_block = true
                end
                in_block = true
            else
                table.insert(result_lines, line)
            end
        else
            if line:match("^%s*ProjectSection") then
                in_project_section = true
                if not skip_block then table.insert(result_lines, line) end
            elseif line:match("^%s*EndProjectSection") then
                in_project_section = false
                if not skip_block then table.insert(result_lines, line) end
            elseif in_project_section then
                if not skip_block then table.insert(result_lines, line) end
            elseif line:match("^EndProject%s*$") then
                in_block = false
                in_project_section = false
                if not skip_block then
                    table.insert(result_lines, "EndProject")
                end
                skip_block = false
            elseif not skip_block then
                table.insert(result_lines, line)
            end
        end
    end

    -- Append new entries before the Global section
    if #new_entries > 0 then
        local insert_at = nil
        for i, line in ipairs(result_lines) do
            if line:match("^Global%s*$") then
                insert_at = i
                break
            end
        end
        local new_blocks = {}
        for _, e in ipairs(new_entries) do
            local guid = string.format(
                "%08X-%04X-%04X-%04X-%012X",
                math.random(0xFFFFFFFF), math.random(0xFFFF),
                math.random(0xFFFF), math.random(0xFFFF),
                math.random(0xFFFFFFFFFFFF)
            )
            table.insert(new_blocks, string.format(
                'Project("{%s}") = "%s", "%s", "{%s}"\nEndProject',
                e.type_guid or "FAE04EC0-301F-11D3-BF4B-00C04F79EFBC",
                e.name, back(e.path), guid
            ))
        end
        local new_lines = vim.split(table.concat(new_blocks, "\n"), "\n", { plain = true })
        if insert_at then
            for i, l in ipairs(new_lines) do
                table.insert(result_lines, insert_at + i - 1, l)
            end
        else
            vim.list_extend(result_lines, new_lines)
        end
    end

    -- Rebuild NestedProjects section
    if next(nesting) then
        local nested_lines = {}
        for child, parent in pairs(nesting) do
            -- Only include pairs where both still exist
            if by_id[child] and by_id[parent] then
                table.insert(nested_lines, string.format(
                    "\t\t{%s} = {%s}", child, parent
                ))
            end
        end
        table.sort(nested_lines)

        local result = table.concat(result_lines, "\n")
        local new_section = "\tGlobalSection(NestedProjects) = preSolution\n"
            .. table.concat(nested_lines, "\n") .. "\n"
            .. "\tEndGlobalSection"
        -- Replace existing section or insert before EndGlobal
        if result:find("GlobalSection%(NestedProjects%)") then
            result = result:gsub(
                "\tGlobalSection%(NestedProjects%)[^\n]*\n.-\tEndGlobalSection",
                new_section
            )
        else
            result = result:gsub("(EndGlobal)", new_section .. "\n%1", 1)
        end
        return result
    end

    return table.concat(result_lines, "\n")
end

-- --------------------------------------------------------------------------
-- .slnx parser (XML-based, VS 2022 17.x+)
-- Folders are <Folder Name="..."> elements wrapping <Project> children.
-- --------------------------------------------------------------------------

local function xml_attr(tag, attr)
    return tag:match(attr .. '%s*=%s*"([^"]*)"')
        or tag:match(attr .. "%s*=%s*'([^']*)'")
end

--- Recursively parse XML tokens into a tree of nodes.
--- Returns a root node with children matching the solution structure.
---@param text string Raw .slnx content
---@return table root_node
function M.parse_slnx(text)
    local root = { entry = nil, children = {} }
    local stack = { root }

    -- Tokenise: find self-closing tags and open/close tags
    for token in text:gmatch("<([^>]+)>") do
        local trimmed = vim.trim(token)
        if trimmed:sub(1, 1) == "/" then
            -- Closing tag: </Folder> or </Solution>
            local tag = trimmed:sub(2):match("^(%S+)")
            if tag == "Folder" then
                table.remove(stack)
            end
        elseif trimmed:sub(-1) == "/" then
            -- Self-closing: <Project Path="..." />
            local inner = trimmed:sub(1, -2)
            local tag = inner:match("^(%S+)")
            if tag == "Project" then
                local path = xml_attr(inner, "Path")
                if path then
                    local fp = fwd(path)
                    local node = {
                        entry = {
                            name = xml_attr(inner, "DisplayName") or fp:match("([^/\\]+)%.[^%.]+$") or fp,
                            path = fp,
                            type_guid = nil,
                            id = nil,
                            is_folder = false,
                        },
                        children = {},
                    }
                    table.insert(stack[#stack].children, node)
                end
            end
        else
            -- Opening tag: <Folder Name="..."> or <Solution ...>
            local tag = trimmed:match("^(%S+)")
            if tag == "Folder" then
                local name = xml_attr(trimmed, "Name") or "Folder"
                local node = {
                    entry = {
                        name = name,
                        path = name,
                        type_guid = FOLDER_GUID,
                        id = nil,
                        is_folder = true,
                    },
                    children = {},
                }
                table.insert(stack[#stack].children, node)
                table.insert(stack, node)
            end
        end
    end

    return root
end

--- Serialise a tree back to .slnx.
---@param text string Original .slnx content
---@param root table Root node
---@return string
function M.serialize_slnx(text, root)
    local lines = {}
    local function walk(node, depth)
        local indent = string.rep("  ", depth)
        if node.entry then
            if node.entry.is_folder then
                table.insert(lines, indent .. string.format('<Folder Name="%s">', node.entry.name))
                for _, child in ipairs(node.children) do
                    walk(child, depth + 1)
                end
                table.insert(lines, indent .. "</Folder>")
            else
                local e = node.entry
                local display = (e.name ~= e.path:match("([^/\\]+)%.[^%.]+$"))
                    and string.format(' DisplayName="%s"', e.name) or ""
                table.insert(lines, indent .. string.format('<Project Path="%s"%s />', e.path, display))
            end
        else
            for _, child in ipairs(node.children) do
                walk(child, depth)
            end
        end
    end
    walk(root, 1)

    return text:gsub(
        "(<Solution[^>]*>)(.-)(</%s*Solution>)",
        function(open, _, close)
            return open .. "\n" .. table.concat(lines, "\n") .. "\n" .. close
        end,
        1
    )
end

-- --------------------------------------------------------------------------
-- .slnf parser (JSON-based solution filter — flat, no folder concept)
-- --------------------------------------------------------------------------

---@param text string
---@return string solution_path, table root_node
function M.parse_slnf(text)
    local solution_path = text:match('"path"%s*:%s*"([^"]+)"')
    local projects_raw = text:match('"projects"%s*:%s*%[(.-)%]')
    local root = { entry = nil, children = {} }
    if projects_raw then
        for p in projects_raw:gmatch('"([^"]+)"') do
            local fp = fwd(p)
            table.insert(root.children, {
                entry = {
                    name = fp:match("([^/\\]+)%.[^%.]+$") or fp,
                    path = fp,
                    type_guid = nil,
                    id = nil,
                    is_folder = false,
                },
                children = {},
            })
        end
    end
    return solution_path and fwd(solution_path) or "", root
end

---@param text string Original .slnf content
---@param root table Root node
---@return string
function M.serialize_slnf(text, root)
    local paths = {}
    local function walk(node)
        if node.entry and not node.entry.is_folder then
            table.insert(paths, string.format('    "%s"', back(node.entry.path)))
        end
        for _, child in ipairs(node.children) do walk(child) end
    end
    walk(root)
    local projects_json = "[\n" .. table.concat(paths, ",\n") .. "\n  ]"
    return text:gsub('"projects"%s*:%s*%[.-%]', '"projects": ' .. projects_json)
end

--- Flatten a tree into an ordered list of { node, depth } pairs for rendering.
---@param root table Root node
---@return table[] { node: table, depth: integer }[]
function M.flatten_tree(root)
    local result = {}
    local function walk(node, depth)
        if node.entry then
            table.insert(result, { node = node, depth = depth })
        end
        for _, child in ipairs(node.children) do
            walk(child, node.entry and depth + 1 or depth)
        end
    end
    walk(root, 0)
    return result
end

return M
