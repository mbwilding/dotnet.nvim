# dotnet.nvim

A Neovim plugin for viewing and editing .NET solution files. Opens `.sln`, `.slnx`, and `.slnf` files as an editable tree buffer. See [Dependencies](#dependencies).

## Features

- Automatically intercepts opening `.sln`, `.slnx`, and `.slnf` files
- Renders the solution as a native foldable tree, respecting solution folder structure
- Solution items (files pinned to solution folders) shown as moveable lines
- Icons per project type and file type via MiniIcons, nonicons, or nvim-web-devicons
- Paths are not shown in the buffer — set/change them with `gf`
- Missing files highlighted with a red underline
- Move projects and folders by cutting and pasting lines at the desired indent level
- Rename by editing the name inline
- Fold-aware `dd` — deleting a folder line deletes its entire subtree
- Solution root line is not editable
- Configurable keybinds toggle the view, or enable/disable interception entirely, from anywhere

## File Format Support

| Format | Description |
|--------|-------------|
| `.sln` | Classic Visual Studio solution. Folders from `GlobalSection(NestedProjects)`, solution items from `ProjectSection(SolutionItems)`. |
| `.slnx` | XML-based format (VS 2022 17.x+). Folders are native `<Folder>` elements. |
| `.slnf` | JSON solution filter. Flat list, no folder concept. |

## Keymaps

### Global

Configurable via `keymaps` in [Configuration](#configuration). Defaults:

| Key | Action | Config key |
|-----|--------|------------|
| `<leader>ds` | Toggle solution view (auto-detects solution in cwd) | `keymaps.toggle` |
| _(unset)_ | Enable interception of `.sln` / `.slnx` / `.slnf` files | `keymaps.enable` |
| _(unset)_ | Disable interception — these files open as plain text | `keymaps.disable` |

### Inside the solution buffer

| Key | Action |
|-----|--------|
| `<CR>` | Open project/item under cursor, or toggle fold if on a folder or solution line |
| `dd` | Delete line. On a folder, deletes the entire subtree. |
| `za` | Toggle fold under cursor |
| `zo` / `zc` | Open / close fold |
| `zR` / `zM` | Expand all / collapse all |
| `o` / `O` | Open file picker to add a new project below / above cursor |
| `gf` | Pick a new file path for the project/item under cursor |
| `gp` | Open the raw solution file |
| `<C-r>` | Reload from disk, discarding unsaved changes |
| `:w` | Save all changes back to the solution file |

## Tree View

The solution renders as an indented tree matching Visual Studio Solution Explorer order (alphabetical within each level). The solution name is the root node. Solution folders are foldable. Only the name is shown on each line — paths live in plugin state and are set/changed with `gf`.

```
capability-kit
  1. Getting Started
    Documentation
    LocalDev
    README.md
  4. Support Libraries
    CapabilityKit.Api
```

## Moving Projects

Indentation is the tree structure. To move an entry:

1. `dd` to cut the line (or fold + `dd` to cut a whole folder with its subtree)
2. Move the cursor to the target location
3. `p` to paste
4. Adjust indent with `<<` / `>>` until the depth matches the desired parent
5. `:w` to save

To move a project into an empty folder, paste the line after the folder line and indent it one level deeper with `>>`.

The new tree structure is derived entirely from indentation when saving — no special syntax required. The buffer's own `shiftwidth`/`tabstop` are pinned to match the tree's indent width, so one `<<`/`>>` always moves exactly one level regardless of your global settings.

## Editing

### Renaming

Edit the name on its line. The path is unaffected. Save with `:w`.

### Adding a project

Add a new line at the desired indent level, then use `gf` to pick its path. Save with `:w`.

### Removing

Delete the line with `dd`. For folders, `dd` removes the folder and all its children.

## Data Safety

`:w` refuses to save, with a clear error, in two situations rather than silently corrupting or wiping the solution file:

- **A solution item ends up outside any folder.** Classic `.sln`/`.slnx` have no way to represent a solution item at the root or under a project — only inside a folder's item list. Move it back under a folder or delete it.
- **The buffer looks emptied out** (e.g. an undo went further than intended, or everything was accidentally deleted) while the solution previously had real content. Reload with `<C-r>` if the emptying wasn't intentional.

## Commands

| Command | Description |
|---------|-------------|
| `:Dotnet` | Open the solution view (auto-detects from cwd) |
| `:Dotnet {path}` | Open a specific solution file |
| `:Dotnet toggle` | Toggle the solution view from anywhere |
| `:Dotnet enable` | Enable interception of `.sln` / `.slnx` / `.slnf` files |
| `:Dotnet disable` | Disable interception — these files open as plain text |

`enable`/`disable` immediately convert any matching buffers already open in the current session (a plain buffer switches to the tree view, or vice versa), not just future opens. A buffer with unsaved changes is left alone with a warning — save or reload it first.

## Highlight Groups

| Group | Links to | Purpose |
|-------|----------|---------|
| `DotnetSolutionIcon` | `Function` | Project type icon |
| `DotnetSolutionProject` | `Normal` | Project name |
| `DotnetSolutionFolder` | `Directory` | Solution folder name and icon |
| `DotnetSolutionItem` | `Comment` | Solution item file |
| `DotnetSolutionHeader` | VS purple | Solution name |
| `DotnetSolutionMissing` | `DiagnosticError` fg + undercurl | File does not exist on disk |

## Configuration

```lua
require("dotnet").setup({
    -- Whether .sln/.slnx/.slnf files are intercepted by the solution view. Default: true.
    enabled = true,
    -- Global keybinds. Set an entry to false to disable it.
    keymaps = {
        toggle = "<leader>ds",  -- Default: "<leader>ds"
        enable = false,         -- Default: false (unset)
        disable = false,        -- Default: false (unset)
    },
})
```

## Dependencies

| Dependency | Required | Purpose |
|------------|----------|---------|
| A [Nerd Font](https://www.nerdfonts.com/) | Yes | Icon glyphs render as private-use codepoints |
| [snacks.nvim](https://github.com/folke/snacks.nvim) | Yes | File picker used by `gf` |
| One of: [mini.icons](https://github.com/echasnovski/mini.icons), [nonicons](https://github.com/yamatsum/nonicons), [nvim-web-devicons](https://github.com/nvim-tree/nvim-web-devicons) | Optional | File-type icons for non-project files and solution items. Falls back to a generic file icon if none are installed. |

### Fold plugins (nvim-ufo, etc.)

The solution buffer manages its own manual folds, matching the tree structure. A generic fold plugin that attaches to every buffer by default (e.g. [nvim-ufo](https://github.com/kevinhwang91/nvim-ufo)) computes and applies its own fold *ranges* over the same buffer, fighting with ours and producing wrong fold ranges. Exclude this plugin's buffer from its provider, e.g. for nvim-ufo:

```lua
require("ufo").setup({
    provider_selector = function(_, filetype, buftype)
        if buftype == "acwrite" or filetype == "dotnet-sln" then
            return ""
        end
        return { "lsp", "indent" } -- or your existing default
    end,
})
```

Separately, some fold plugins also override the `'foldtext'` window option (how a *closed* fold's summary line renders) for every window regardless of the above exclusion — nvim-ufo's own byte-based truncation isn't safe for this plugin's multi-byte Nerd Font icons, and can garble the closed-fold line or its highlighting. dotnet.nvim defends against this itself (it re-pins `'foldtext'` to Vim's built-in renderer on every `BufWinEnter`, after such plugins have had their turn), so no extra config is needed for that part.

## Installation

```lua
{
    "mbwilding/dotnet.nvim",
    dependencies = {
        "folke/snacks.nvim",
        "nvim-tree/nvim-web-devicons", -- or echasnovski/mini.icons / yamatsum/nonicons
    },
}
```

## How It Works

When a `.sln`, `.slnx`, or `.slnf` file is opened, a `BufReadCmd` autocmd intercepts the normal file read and populates the buffer with the parsed solution tree. The buffer type is `acwrite` so `:w` routes through `BufWriteCmd`, which reads the indentation of every line to reconstruct the full tree structure, then serialises it back to disk in the original format.
