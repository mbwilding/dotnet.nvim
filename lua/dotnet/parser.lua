--- Parsers for .sln, .slnx, .slnf solution formats.
---
--- Entry shapes:
---   Project/folder: { name, path, type_guid, id, is_folder, solution_items? }
---   solution_items: string[] of relative file paths (backslash) belonging to a folder
---
--- Tree node: { entry, children }
---   Root is synthetic: { entry=nil, children={...} }
---
--- Flat row: { node, depth, kind }
---   kind = "solution" | "folder" | "project" | "item"
---   "item" rows are solution items (files pinned to a solution folder)

local M = {}

local TYPE_GUID_NAMES = {
    ["FAE04EC0-301F-11D3-BF4B-00C04F79EFBC"] = "csproj",
    ["9A19103F-16F7-4668-BE54-9A1E7A4F7556"] = "csproj",
    ["F2A71F9B-5D33-465A-A702-920D77279786"] = "fsproj",
    ["13B669BE-BB05-4DDF-9536-439F39A36129"] = "fsproj",
    ["778DAE3C-4631-46EA-AA77-85C1314464D9"] = "vbproj",
    ["8BB2217D-0F2D-49D1-97BC-3654ED321F3B"] = "esproj",
    ["54A90642-561A-4BB1-A94E-469ADEE60C69"] = "esproj",
    ["54435603-DBB4-11D2-8724-00A0C9A8B90C"] = "vdproj",
    ["2150E333-8FDC-42A3-9474-1A3956D46DE8"] = "_folder",
}

local FOLDER_GUID = "2150E333-8FDC-42A3-9474-1A3956D46DE8"

---@param path string
---@return "sln"|"slnx"|"slnf"
function M.detect(path)
    local ext = path:match("%.(%a+)$"):lower()
    if ext == "slnx" then return "slnx" end
    if ext == "slnf" then return "slnf" end
    return "sln"
end

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

---@param entry table
---@return boolean
function M.is_folder(entry)
    return entry.is_folder == true
end

local function fwd(p) return (p:gsub("\\", "/")) end
local function back(p) return (p:gsub("/", "\\")) end

-- ---------------------------------------------------------------------------
-- Tree building
-- ---------------------------------------------------------------------------

---@param entries table[]
---@param nesting table<string,string>
---@return table root_node
function M.build_tree(entries, nesting)
    local nodes = {}
    for i, e in ipairs(entries) do
        local key = e.id and e.id:upper() or ("__idx_" .. i)
        nodes[key] = { entry = e, children = {} }
    end

    local root = { entry = nil, children = {} }

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

--- Derive nesting map + ordered list from tree structure.
---@param root table
---@return table<string,string>, table[]
function M.nesting_from_tree(root)
    local nesting = {}
    local ordered = {}
    local function walk(node, parent_entry)
        if node.entry and node.entry.id and parent_entry and parent_entry.id then
            local child_id  = node.entry.id:upper()
            local parent_id = parent_entry.id:upper()
            nesting[child_id] = parent_id
            table.insert(ordered, { child = child_id, parent = parent_id })
        end
        for _, child in ipairs(node.children) do
            walk(child, node.entry)
        end
    end
    walk(root, nil)
    return nesting, ordered
end

-- ---------------------------------------------------------------------------
-- Flat list for rendering
-- ---------------------------------------------------------------------------

--- Flatten a tree into an ordered list of render rows.
--- Row 1 is always a synthetic "solution" row.
--- Solution items appear as "item" rows after their parent folder's project children.
--- Each row: { node, depth, kind }
---@param root table
---@param sln_path string
---@return table[]
function M.flatten_tree(root, sln_path)
    local result = {}

    local sln_name = sln_path
        and (sln_path:match("([^/\\]+)$"):gsub("%.[^%.]+$", ""))
        or "solution"
    table.insert(result, {
        node  = {
            entry    = { name = sln_name, path = sln_path or "", is_folder = false, is_solution = true },
            children = root.children,
        },
        depth = 0,
        kind  = "solution",
    })

    local function walk(node, depth)
        if not node.entry then
            for _, child in ipairs(node.children) do walk(child, depth) end
            return
        end
        if node.entry.is_solution_item then
            table.insert(result, { node = node, depth = depth, kind = "item" })
            return
        end
        local kind = node.entry.is_folder and "folder" or "project"
        table.insert(result, { node = node, depth = depth, kind = kind })
        -- Project children first (sorted alphabetically already)
        for _, child in ipairs(node.children) do
            walk(child, depth + 1)
        end
        -- Solution items after project children
        if node.entry.is_folder and node.entry.solution_items then
            for _, item_path in ipairs(node.entry.solution_items) do
                local p = fwd(item_path)
                table.insert(result, {
                    node = {
                        entry    = {
                            name             = p:match("([^/\\]+)$") or p,
                            path             = p,
                            is_solution_item = true,
                            is_folder        = false,
                        },
                        children = {},
                    },
                    depth = depth + 1,
                    kind  = "item",
                })
            end
        end
    end

    for _, child in ipairs(root.children) do
        walk(child, 1)
    end

    return result
end

-- ---------------------------------------------------------------------------
-- .sln parser
-- ---------------------------------------------------------------------------

---@param text string
---@return table[] entries, table<string,string> nesting
function M.parse_sln(text)
    local entries = {}
    local in_block = false
    local in_solution_items = false
    local current = nil

    local parse_text = text:sub(1, 3) == "\xEF\xBB\xBF" and text:sub(4) or text

    for line in (parse_text .. "\n"):gmatch("([^\n]*)\n") do
        if not in_block then
            local tg, name, path, id = line:match(
                '^Project%("{([^}]+)}"%)'
                .. '%s*=%s*"([^"]+)",%s*"([^"]+)",%s*"{([^}]+)}"'
            )
            if tg then
                local tgu = tg:upper()
                current = {
                    name           = name,
                    path           = fwd(path),
                    type_guid      = tgu,
                    id             = id:upper(),
                    is_folder      = (tgu == FOLDER_GUID),
                    solution_items = nil,
                }
                in_block = true
            end
        else
            if line:match("^%s*ProjectSection%(SolutionItems%)") then
                in_solution_items = true
                if current.is_folder then
                    current.solution_items = current.solution_items or {}
                end
            elseif line:match("^%s*EndProjectSection") then
                in_solution_items = false
            elseif in_solution_items then
                local item = line:match("^%s*(.-)%s*=")
                item = item and vim.trim(item)
                if item and item ~= "" and current.solution_items then
                    local path = (item:gsub("\\", "/"))
                    current.solution_items[#current.solution_items + 1] = path
                end
            elseif line:match("^EndProject%s*$") then
                in_block = false
                in_solution_items = false
                table.insert(entries, current)
                current = nil
            end
        end
    end

    local nesting = {}
    local nested_block = parse_text:match("GlobalSection%(NestedProjects%)[^\n]*\n(.-)EndGlobalSection")
    if nested_block then
        for child, parent in nested_block:gmatch("{([A-Fa-f0-9%-]+)}%s*=%s*{([A-Fa-f0-9%-]+)}") do
            nesting[child:upper()] = parent:upper()
        end
    end

    return entries, nesting
end

---@param text string
---@param entries table[]
---@param nesting table<string,string>
---@param nesting_ordered table[]
---@return string
function M.serialize_sln(text, entries, nesting, nesting_ordered)
    local by_id = {}
    for _, e in ipairs(entries) do
        if e.id then by_id[e.id:upper()] = e end
    end

    local new_entries = {}
    for _, e in ipairs(entries) do
        if not e.id then table.insert(new_entries, e) end
    end

    -- Rebuild Project blocks line by line.
    -- ProjectSection content (SolutionItems, ProjectDependencies) is preserved
    -- verbatim for existing entries. For entries with updated solution_items,
    -- the SolutionItems section is replaced.
    local result_lines = {}
    local in_block = false
    local in_project_section = false
    local skip_block = false
    local current_id = nil
    local current_is_solution_items = false

    local parse_text = text:sub(1, 3) == "\xEF\xBB\xBF" and text:sub(4) or text

    for line in (parse_text .. "\n"):gmatch("([^\n]*)\n") do
        if not in_block then
            local id = line:match('^Project%("{[^}]+}"%)[^{]*{([A-Fa-f0-9%-]+)}"?%s*$')
            if id then
                local p = by_id[id:upper()]
                if p then
                    table.insert(result_lines, string.format(
                        'Project("{%s}") = "%s", "%s", "{%s}"',
                        p.type_guid or FOLDER_GUID, p.name, back(p.path), p.id
                    ))
                    skip_block  = false
                    current_id  = id:upper()
                else
                    skip_block  = true
                    current_id  = nil
                end
                in_block = true
            else
                table.insert(result_lines, line)
            end
        else
            if line:match("^%s*ProjectSection%(SolutionItems%)") then
                in_project_section        = true
                current_is_solution_items = true
                if not skip_block then
                    local p = current_id and by_id[current_id]
                    if p and p.solution_items ~= nil then
                        -- solution_items was explicitly set (updated or cleared)
                        if #p.solution_items > 0 then
                            -- Inject updated items, skip original lines
                            table.insert(result_lines, line)
                            for _, item_path in ipairs(p.solution_items) do
                                local bp = back(item_path)
                                table.insert(result_lines, string.format("\t\t%s = %s", bp, bp))
                            end
                        end
                        -- if empty ({}): skip the whole section (don't emit header)
                    else
                        -- nil: preserve verbatim
                        table.insert(result_lines, line)
                    end
                end
            elseif line:match("^%s*ProjectSection") then
                in_project_section        = true
                current_is_solution_items = false
                if not skip_block then table.insert(result_lines, line) end
            elseif line:match("^%s*EndProjectSection") then
                local p = current_id and by_id[current_id]
                -- Suppress EndProjectSection if we're clearing the section (empty array)
                local suppress = current_is_solution_items
                    and p and p.solution_items ~= nil and #p.solution_items == 0
                in_project_section        = false
                current_is_solution_items = false
                if not skip_block and not suppress then
                    table.insert(result_lines, line)
                end
            elseif in_project_section then
                if not skip_block then
                    -- Skip original SolutionItems lines if we've injected updated ones
                    -- or cleared the section
                    local p = current_id and by_id[current_id]
                    if current_is_solution_items and p and p.solution_items ~= nil then
                        -- already handled above — skip original line
                    else
                        table.insert(result_lines, line)
                    end
                end
            elseif line:match("^EndProject%s*$") then
                in_block                  = false
                in_project_section        = false
                current_is_solution_items = false
                if not skip_block then
                    table.insert(result_lines, "EndProject")
                end
                current_id = nil
                skip_block = false
            elseif not skip_block then
                table.insert(result_lines, line)
            end
        end
    end

    -- Append new entries before Global
    if #new_entries > 0 then
        local insert_at = nil
        for i, line in ipairs(result_lines) do
            if line:match("^Global%s*$") then insert_at = i; break end
        end
        local new_blocks = {}
        for _, e in ipairs(new_entries) do
            local guid = string.format(
                "%08X-%04X-%04X-%04X-%012X",
                math.random(0xFFFFFFFF), math.random(0xFFFF),
                math.random(0xFFFF), math.random(0xFFFF),
                math.random(0xFFFFFFFFFFFF)
            )
            local block = string.format(
                'Project("{%s}") = "%s", "%s", "{%s}"\nEndProject',
                e.type_guid or "FAE04EC0-301F-11D3-BF4B-00C04F79EFBC",
                e.name, back(e.path), guid
            )
            -- If it's a folder with solution items, add ProjectSection
            if e.is_folder and e.solution_items and #e.solution_items > 0 then
                local item_lines = {}
                for _, ip in ipairs(e.solution_items) do
                    local bp = back(ip)
                    table.insert(item_lines, string.format("\t\t%s = %s", bp, bp))
                end
                block = string.format(
                    'Project("{%s}") = "%s", "%s", "{%s}"\n\tProjectSection(SolutionItems) = preProject\n%s\n\tEndProjectSection\nEndProject',
                    e.type_guid or FOLDER_GUID, e.name, back(e.path), guid,
                    table.concat(item_lines, "\n")
                )
            end
            table.insert(new_blocks, block)
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

    -- Rebuild NestedProjects in tree-walk order
    local nested_lines = {}
    for _, pair in ipairs(nesting_ordered or {}) do
        if by_id[pair.child] and by_id[pair.parent] then
            table.insert(nested_lines, string.format("\t\t{%s} = {%s}", pair.child, pair.parent))
        end
    end

    local result = table.concat(result_lines, "\n")
    -- Prepend BOM if original had it
    if text:sub(1, 3) == "\xEF\xBB\xBF" then
        result = "\xEF\xBB\xBF" .. result
    end

    if #nested_lines > 0 then
        local new_section = "\tGlobalSection(NestedProjects) = preSolution\n"
            .. table.concat(nested_lines, "\n") .. "\n"
            .. "\tEndGlobalSection"
        if result:find("GlobalSection%(NestedProjects%)") then
            result = result:gsub(
                "\tGlobalSection%(NestedProjects%)[^\n]*\n.-\tEndGlobalSection",
                new_section
            )
        else
            result = result:gsub("(EndGlobal)", new_section .. "\n%1", 1)
        end
    elseif result:find("GlobalSection%(NestedProjects%)") then
        result = result:gsub(
            "\n\tGlobalSection%(NestedProjects%)[^\n]*\n.-\tEndGlobalSection",
            ""
        )
    end

    return result
end

-- ---------------------------------------------------------------------------
-- .slnx parser
-- ---------------------------------------------------------------------------

local function xml_attr(tag, attr)
    return tag:match(attr .. '%s*=%s*"([^"]*)"')
        or tag:match(attr .. "%s*=%s*'([^']*)'")
end

---@param text string
---@return table root_node
function M.parse_slnx(text)
    local root  = { entry = nil, children = {} }
    local stack = { root }
    for token in text:gmatch("<([^>]+)>") do
        local trimmed = vim.trim(token)
        if trimmed:sub(1, 1) == "/" then
            local tag = trimmed:sub(2):match("^(%S+)")
            if tag == "Folder" then table.remove(stack) end
        elseif trimmed:sub(-1) == "/" then
            local inner = trimmed:sub(1, -2)
            local tag   = inner:match("^(%S+)")
            if tag == "Project" then
                local path = xml_attr(inner, "Path")
                if path then
                    local fp = fwd(path)
                    table.insert(stack[#stack].children, {
                        entry    = {
                            name      = xml_attr(inner, "DisplayName") or fp:match("([^/\\]+)%.[^%.]+$") or fp,
                            path      = fp,
                            type_guid = nil,
                            id        = nil,
                            is_folder = false,
                        },
                        children = {},
                    })
                end
            end
        else
            local tag = trimmed:match("^(%S+)")
            if tag == "Folder" then
                local name = xml_attr(trimmed, "Name") or "Folder"
                local node = {
                    entry    = { name = name, path = name, type_guid = FOLDER_GUID, id = nil, is_folder = true },
                    children = {},
                }
                table.insert(stack[#stack].children, node)
                table.insert(stack, node)
            end
        end
    end
    return root
end

---@param text string
---@param root table
---@return string
function M.serialize_slnx(text, root)
    local lines = {}
    local function walk(node, depth)
        local indent = string.rep("  ", depth)
        if node.entry then
            if node.entry.is_folder then
                table.insert(lines, indent .. string.format('<Folder Name="%s">', node.entry.name))
                for _, child in ipairs(node.children) do walk(child, depth + 1) end
                table.insert(lines, indent .. "</Folder>")
            elseif not node.entry.is_solution_item then
                local e       = node.entry
                local display = (e.name ~= e.path:match("([^/\\]+)%.[^%.]+$"))
                    and string.format(' DisplayName="%s"', e.name) or ""
                table.insert(lines, indent .. string.format('<Project Path="%s"%s />', e.path, display))
            end
        else
            for _, child in ipairs(node.children) do walk(child, depth) end
        end
    end
    walk(root, 1)
    return text:gsub(
        "(<Solution[^>]*>)(.-)(</%s*Solution>)",
        function(open, _, close)
            return open .. "\n" .. table.concat(lines, "\n") .. "\n" .. close
        end, 1
    )
end

-- ---------------------------------------------------------------------------
-- .slnf parser
-- ---------------------------------------------------------------------------

---@param text string
---@return string, table
function M.parse_slnf(text)
    local solution_path = text:match('"path"%s*:%s*"([^"]+)"')
    local projects_raw  = text:match('"projects"%s*:%s*%[(.-)%]')
    local root          = { entry = nil, children = {} }
    if projects_raw then
        for p in projects_raw:gmatch('"([^"]+)"') do
            local fp = fwd(p)
            table.insert(root.children, {
                entry    = { name = fp:match("([^/\\]+)%.[^%.]+$") or fp, path = fp, type_guid = nil, id = nil, is_folder = false },
                children = {},
            })
        end
    end
    return solution_path and fwd(solution_path) or "", root
end

---@param text string
---@param root table
---@return string
function M.serialize_slnf(text, root)
    local paths = {}
    local function walk(node)
        if node.entry and not node.entry.is_folder and not node.entry.is_solution_item then
            table.insert(paths, string.format('    "%s"', back(node.entry.path)))
        end
        for _, child in ipairs(node.children) do walk(child) end
    end
    walk(root)
    local projects_json = "[\n" .. table.concat(paths, ",\n") .. "\n  ]"
    return text:gsub('"projects"%s*:%s*%[.-%]', '"projects": ' .. projects_json)
end

return M
