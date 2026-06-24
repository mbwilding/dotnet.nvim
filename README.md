# dotnet.nvim

A Neovim plugin for viewing and editing .NET solution files. Opens `.sln`, `.slnx`, and `.slnf` files as an editable tree buffer. Requires a Nerd Font.

## Features

- Automatically intercepts opening `.sln`, `.slnx`, and `.slnf` files
- Renders the solution as a native foldable tree, respecting the solution folder structure
- Nerd Font icons per project type
- Project paths shown as dimmed virtual text, keeping the buffer clean
- Rename projects by editing their name inline, then `:w` to save
- `<leader>ds` toggles the view from anywhere, auto-detecting the solution in cwd

## File Format Support

| Format | Description |
|--------|-------------|
| `.sln` | Classic Visual Studio solution. Folders and nesting come from `GlobalSection(NestedProjects)`. |
| `.slnx` | XML-based solution format (VS 2022 17.x+). Folders are native `<Folder>` elements. |
| `.slnf` | JSON solution filter. Flat list, no folder concept. |

## Icons

| Icon | Type |
|------|------|
| `󰌛` | C# (`.csproj`) |
| `󰬟` | F# (`.fsproj`) |
| `󰈝` | Visual Basic (`.vbproj`) |
| `󰌚` | JavaScript/ES (`.esproj`) |
| `` | Solution folder |
| `` | Generic / unknown |
| `󰘐` | Solution header |

## Keymaps

### Global

| Key | Action |
|-----|--------|
| `<leader>ds` | Toggle solution view (auto-detects solution in cwd) |

### Inside the solution buffer

| Key | Action |
|-----|--------|
| `<CR>` | Open the project file under the cursor, or toggle fold if on a folder |
| `za` | Toggle fold under cursor |
| `zo` / `zc` | Open / close fold |
| `zR` / `zM` | Expand all / collapse all |
| `q` | Close the solution buffer |
| `gp` | Open the raw solution file |
| `<C-r>` | Reload from disk, discarding unsaved changes |
| `:w` | Save all changes back to the solution file |

## Tree View

The solution is rendered as an indented tree that mirrors the structure defined in the solution file. Solution folders are collapsible using standard Neovim fold commands. The buffer opens fully expanded.

Example:

```
󰘐 MySolution.sln
   Backend/
    󰌛 Api
    󰌛 Api.Tests
   Frontend/
    󰌚 WebApp
   󰌛 Shared
```

Folds are driven by `foldmethod=indent`, so all native fold commands work as expected.

## Editing

### Renaming a project or folder

Edit the name on its line. The path (shown as virtual text) is unaffected. Save with `:w`.

### Adding or removing projects

Not yet supported via the buffer. Use `:DotnetSolution` to reload after making changes with `dotnet sln` on the command line.

## Commands

| Command | Description |
|---------|-------------|
| `:DotnetSolution` | Open the solution view (auto-detects from cwd) |
| `:DotnetSolution {path}` | Open a specific solution file |

## Highlight Groups

All groups link to standard groups by default and respect the active colourscheme.

| Group | Links to | Purpose |
|-------|----------|---------|
| `DotnetSolutionIcon` | `Function` | Project type icon |
| `DotnetSolutionProject` | `Normal` | Project name |
| `DotnetSolutionPath` | `Comment` | Virtual text path |
| `DotnetSolutionFolder` | `Directory` | Solution folder name and icon |
| `DotnetSolutionHeader` | `Title` | Solution name header |
| `DotnetSolutionModified` | `DiagnosticWarn` | Modified indicator |

## Installation

Install with your plugin manager of choice, for example with lazy.nvim:

```lua
{
    "mbwilding/dotnet.nvim",
}
```

## How It Works

When a `.sln`, `.slnx`, or `.slnf` file is opened, a `BufReadCmd` autocmd intercepts the normal file read and populates the buffer with the parsed solution tree instead. The buffer type is set to `acwrite` so that `:w` routes through a `BufWriteCmd` autocmd, which serialises the view back to disk in the original format. Tree structure is never modified by editing the buffer, only names.
