# dotnet.nvim

A Neovim plugin for viewing and editing .NET solution files. Opens `.sln`, `.slnx`, and `.slnf` files as an editable tree buffer. Requires a Nerd Font.

## Features

- Automatically intercepts opening `.sln`, `.slnx`, and `.slnf` files
- Renders the solution as a native foldable tree, respecting solution folder structure
- Solution items (files pinned to solution folders) shown as moveable lines with editable paths
- Icons per project type and file type via MiniIcons, nonicons, or nvim-web-devicons
- Project and item paths shown inline after the name, editable in insert mode
- Missing files highlighted with a red underline
- Move projects and folders by cutting and pasting lines at the desired indent level
- Rename by editing the name inline
- Fold-aware `dd` — deleting a folder line deletes its entire subtree
- Solution root line is not editable
- `<leader>ds` toggles the view from anywhere, auto-detecting the solution in cwd

## File Format Support

| Format | Description |
|--------|-------------|
| `.sln` | Classic Visual Studio solution. Folders from `GlobalSection(NestedProjects)`, solution items from `ProjectSection(SolutionItems)`. |
| `.slnx` | XML-based format (VS 2022 17.x+). Folders are native `<Folder>` elements. |
| `.slnf` | JSON solution filter. Flat list, no folder concept. |

## Keymaps

### Global

| Key | Action |
|-----|--------|
| `<leader>ds` | Toggle solution view (auto-detects solution in cwd) |

### Inside the solution buffer

| Key | Action |
|-----|--------|
| `<CR>` | Open project/item under cursor, or toggle fold if on a folder or solution line |
| `dd` | Delete line. On a folder, deletes the entire subtree. |
| `za` | Toggle fold under cursor |
| `zo` / `zc` | Open / close fold |
| `zR` / `zM` | Expand all / collapse all |
| `q` | Close the solution buffer |
| `o` / `O` | Open file picker to add a new project below / above cursor |
| `gf` | Pick a new file path for the project/item under cursor |
| `gp` | Open the raw solution file |
| `<C-r>` | Reload from disk, discarding unsaved changes |
| `:w` | Save all changes back to the solution file |

## Tree View

The solution renders as an indented tree matching Visual Studio Solution Explorer order (alphabetical within each level). The solution name is the root node. Solution folders are foldable. Projects and solution items show their relative path inline after the name, separated by two spaces.

```
capability-kit
  1. Getting Started
    Documentation  docs/Documentation.csproj
    LocalDev  localdev/LocalDev.csproj
    README.md  README.md
  4. Support Libraries
    CapabilityKit.Api  supportlibs/CapabilityKit.Api/CapabilityKit.Api.csproj
```

## Moving Projects

Indentation is the tree structure. To move an entry:

1. `dd` to cut the line (or fold + `dd` to cut a whole folder with its subtree)
2. Move the cursor to the target location
3. `p` to paste
4. Adjust indent with `<<` / `>>` until the depth matches the desired parent
5. `:w` to save

To move a project into an empty folder, paste the line after the folder line and indent it one level deeper with `>>`.

The new tree structure is derived entirely from indentation when saving — no special syntax required.

## Editing

### Renaming

Edit the name on its line. The path (shown as virtual text) is unaffected. Save with `:w`.

### Adding a project

Add a new line at the desired indent level. The icon is inferred from the file extension. Save with `:w`.

### Removing

Delete the line with `dd`. For folders, `dd` removes the folder and all its children.

## Commands

| Command | Description |
|---------|-------------|
| `:DotnetSolution` | Open the solution view (auto-detects from cwd) |
| `:DotnetSolution {path}` | Open a specific solution file |

## Highlight Groups

| Group | Links to | Purpose |
|-------|----------|---------|
| `DotnetSolutionIcon` | `Function` | Project type icon |
| `DotnetSolutionProject` | `Normal` | Project name |
| `DotnetSolutionPath` | `Comment` | Virtual text path |
| `DotnetSolutionFolder` | `Directory` | Solution folder name and icon |
| `DotnetSolutionItem` | `Comment` | Solution item file |
| `DotnetSolutionHeader` | VS purple | Solution name |
| `DotnetSolutionModified` | `DiagnosticWarn` | Modified indicator |
| `DotnetSolutionMissing` | `DiagnosticError` fg + undercurl | File does not exist on disk |

## Configuration

```lua
require("dotnet").setup({
    -- Global keymap to toggle the solution view. Set to false to disable. Default: "<leader>ds".
    keymap = "<leader>ds",
})
```

## Installation

```lua
{
    "mbwilding/dotnet.nvim",
}
```

## How It Works

When a `.sln`, `.slnx`, or `.slnf` file is opened, a `BufReadCmd` autocmd intercepts the normal file read and populates the buffer with the parsed solution tree. The buffer type is `acwrite` so `:w` routes through `BufWriteCmd`, which reads the indentation of every line to reconstruct the full tree structure, then serialises it back to disk in the original format.
