# dotnet.nvim

A Neovim plugin for .NET. Opens `.sln`, `.slnx`, and `.slnf` files as an editable tree buffer, and provides a full-screen, Rider-style NuGet package manager for solutions and projects. See [Dependencies](#dependencies).

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
- Full-screen NuGet package manager (`:Dotnet packages`) built on [volt](https://github.com/NvChad/volt):
  - Installed, Transitive, Upgrades, Consolidate and Browse tabs
  - Update packages to latest, pick any version, or consolidate mismatched versions across projects
  - Search, add and remove packages across the whole solution or per project
  - Transitive packages in their own tab, plus per-package dependency lists
  - Optional prerelease support, mouse and keyboard driven
  - Works with inline versions and Central Package Management (`Directory.Packages.props`)

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
| `<leader>dp` | Open the NuGet packages view for the current solution or project | `keymaps.packages` |

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
| `:Dotnet packages [path]` | Open the NuGet packages view for a solution or project file. Without a path it uses the current solution or project buffer, else the solution in the cwd. |

`enable`/`disable` immediately convert any matching buffers already open in the current session (a plain buffer switches to the tree view, or vice versa), not just future opens. A buffer with unsaved changes is left alone with a warning — save or reload it first.

## NuGet Packages

`:Dotnet packages` (default `<leader>dp`) opens a full-screen, Rider-style package manager built on [NvChad/volt](https://github.com/NvChad/volt) (NvUI). The layout is a centred card on a darker backdrop with a title bar, stat summary with an up-to-date meter, icon tabs, key hint pills, a column table and a highlighted cursor row. The layout is responsive: it uses the full width on narrow terminals and a centred card on very wide ones. On narrow or short windows it drops the stats meter, compacts the tabs, wraps or hides the key hints, hides the `Used by` column and shrinks the name and version columns, and it re-flows on resize. Text colours are adjusted to keep a readable contrast against the panel backgrounds. Rows are clickable with the mouse as well as the keyboard.

**Scope:** the solution in the current solution buffer, the current `.csproj` / `.fsproj` / `.vbproj` buffer, or the solution found in the cwd. Pass a path to `:Dotnet packages` to choose one explicitly.

**Data:** package and latest versions come from `dotnet list package --include-transitive` (with `--outdated`). Dependency lists are read from each project's `obj/project.assets.json`, so restore first. Projects with no restored assets are listed under `Skipped projects` and left out.

### Tabs

Switch with `[` and `]`, or click a tab.

| Tab | Shows |
|-----|-------|
| **Installed** | Direct packages with the declared version and the latest if outdated. Expand a package to see its projects and a collapsed `Dependencies` list of every transitive package it brings in. |
| **Transitive** | Packages only pulled in indirectly, with the resolved version and the direct packages that require them. |
| **Upgrades** | Only packages with a newer version available. |
| **Consolidate** | Packages declared at different versions across projects. `u` sets them to the highest version in use. |
| **Browse** | Search results from your package sources (`/`), with installed packages marked. |

### Keys

| Key | Action |
|-----|--------|
| `<CR>` | Fold or unfold the package or node under the cursor |
| `<Tab>` | Toggle selection on a package (all its projects) or a project row (that project only) |
| `u` | Apply the tab's update to the selection, or the row under the cursor |
| `U` | Apply it to every package in the tab |
| `v` | Pick a specific version from your package sources. On a Browse row, sets the version to add |
| `/` | Search your package sources (switches to Browse) |
| `a` | Add the selected Browse results to all projects or one project (`dotnet add package`). Outside Browse, starts a search. |
| `d` | Remove the selected packages, or the row under the cursor, after confirming (`dotnet remove package`) |
| `P` | Toggle prerelease versions |
| `[` / `]` | Previous / next tab |
| `r` | Refresh |
| `q` | Close |

### How updates are written

Updates edit only the version text and write straight to disk, in the `PackageReference` (`Version` attribute, `<Version>` element or `VersionOverride`) or in `Directory.Packages.props` when Central Package Management is used. Versions set through MSBuild properties (for example `$(SerilogVersion)`) are skipped and reported. Add and remove go through `dotnet add package` and `dotnet remove package`, so they follow your NuGet.Config sources. Open buffers pick up the changes through `checktime`.

### Prerelease

Off by default. Set `prerelease = true` in [Configuration](#configuration) or press `P` in the view. When on, the outdated check, search and version picker include prerelease versions. When off, only stable versions are listed.

## Highlight Groups

| Group | Links to | Purpose |
|-------|----------|---------|
| `DotnetSolutionIcon` | `Function` | Project type icon |
| `DotnetSolutionProject` | `Normal` | Project name |
| `DotnetSolutionFolder` | `Directory` | Solution folder name and icon |
| `DotnetSolutionItem` | `Comment` | Solution item file |
| `DotnetSolutionHeader` | VS purple | Solution name |
| `DotnetSolutionMissing` | `DiagnosticError` fg + undercurl | File does not exist on disk |

The packages view defines its own groups, using volt's palette when base46 is loaded and your colourscheme otherwise. Tones (each with a `Cur` variant for the cursor row): `DotnetPkgCard`, `DotnetPkgName`, `DotnetPkgDim`, `DotnetPkgOk`, `DotnetPkgWarn`, `DotnetPkgLink`, `DotnetPkgErr`, `DotnetPkgRule`. Chrome: `DotnetPkgBackdrop`, `DotnetPkgBar`, `DotnetPkgBarTitle`, `DotnetPkgBarDim`, `DotnetPkgBarWarn`, `DotnetPkgTabOn`, `DotnetPkgTabOff`, `DotnetPkgKbd`, `DotnetPkgKbdDesc`, `DotnetPkgHead`, `DotnetPkgMeter`, `DotnetPkgMeterOff`.

## Configuration

```lua
require("dotnet").setup({
    -- Whether .sln/.slnx/.slnf files are intercepted by the solution view. Default: true.
    enabled = true,
    -- Include prerelease versions in the packages view (updates, search, version picker). Default: false.
    -- Toggle at runtime with P in the packages view.
    prerelease = false,
    -- Projects checked for updates in parallel in the packages view. 1 checks the whole solution in one call. Default: 10.
    outdated_concurrency = 10,
    -- Global keybinds. Set an entry to false to disable it.
    keymaps = {
        toggle = "<leader>ds",   -- Default: "<leader>ds"
        enable = false,          -- Default: false (unset)
        disable = false,         -- Default: false (unset)
        packages = "<leader>dp", -- Default: "<leader>dp"
    },
})
```

## Dependencies

| Dependency | Required | Purpose |
|------------|----------|---------|
| A [Nerd Font](https://www.nerdfonts.com/) | Yes | Icon glyphs render as private-use codepoints |
| [snacks.nvim](https://github.com/folke/snacks.nvim) | Yes | File picker used by `gf` |
| [NvChad/volt](https://github.com/NvChad/volt) | For `:Dotnet packages` | UI library behind the NuGet packages view |
| [.NET SDK](https://dotnet.microsoft.com/download) 8.0.400+ (`dotnet` on `PATH`) | For `:Dotnet packages` | Lists, searches, adds and removes packages. Uses your NuGet.Config sources. |
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
        "NvChad/volt", -- only needed for :Dotnet packages
        "nvim-tree/nvim-web-devicons", -- or echasnovski/mini.icons / yamatsum/nonicons
    },
}
```

## How It Works

When a `.sln`, `.slnx`, or `.slnf` file is opened, a `BufReadCmd` autocmd intercepts the normal file read and populates the buffer with the parsed solution tree. The buffer type is `acwrite` so `:w` routes through `BufWriteCmd`, which reads the indentation of every line to reconstruct the full tree structure, then serialises it back to disk in the original format.

The packages view is a separate scratch buffer rendered with volt's extmark layout. It reads package data from the `dotnet` CLI and each project's `obj/project.assets.json`, edits version text in place for updates, and delegates add and remove to `dotnet add package` / `dotnet remove package`.
