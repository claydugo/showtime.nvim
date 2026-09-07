# showtime.nvim

Treesitter-powered reference highlighting for Neovim 0.11+.
Showtime highlights matching identifiers within the visible, unfolded part of the current syntax scope.
It uses Neovim's Tree-sitter APIs and needs no additional plugins.

## Features

- **Scope-aware**: Matches stay within the nearest syntax scope, such as a function, class, or module.
- **Treesitter-native**: Uses installed parsers and shared identifier heuristics. Matching depends on the grammar's identifier node types.
- **Fast**: Queries limit matching to unfolded viewport ranges. Cached matches support movement between occurrences. Highlighting parses asynchronously.
- **Zero config**: Sensible defaults out of the box. `setup()` is optional.

## Requirements

- Neovim >= 0.11
- A Tree-sitter parser for the language you edit

Neovim includes parsers for some languages. Use the [parser installation instructions](https://neovim.io/doc/user/treesitter/#treesitter-parsers) for other languages.
If you use [nvim-treesitter](https://github.com/nvim-treesitter/nvim-treesitter), its `:TSInstall <lang>` command installs parsers.
Check the plugin's Neovim version requirements.

## Installation

Using [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
    'claydugo/showtime.nvim',
    event = 'VeryLazy',
    opts = {},
}
```

Or with explicit config:

```lua
{
    'claydugo/showtime.nvim',
    event = 'VeryLazy',
    config = function()
        require('showtime').setup({
            delay = 0,
            max_matches = 500,
        })
    end,
}
```

> [!NOTE]
> Calling `setup()` is optional. The plugin works with defaults as soon as it loads.

## Configuration

All options and their defaults:

```lua
require('showtime').setup({
    --- Milliseconds before highlighting (0 = immediate).
    delay = 0,
    --- Highlight group for references.
    hl_group = 'ShowtimeReference',
    --- Safety cap on extmarks per update cycle.
    max_matches = 500,
    --- Minimum visible references required before highlighting activates.
    --- The cursor's own occurrence counts, so the default of 2 means
    --- "highlight only when there is at least one other occurrence."
    --- An identifier with no siblings stays unhighlighted.
    min_matches = 2,
    --- Treesitter languages to skip (e.g., { 'markdown', 'vimdoc' }).
    exclude_languages = {},
    --- Buffer types to skip.
    exclude_buftypes = { 'nofile', 'terminal', 'prompt' },
    --- Per-language scope node overrides (deep-merged with builtins).
    --- See "Adding a Language" below.
    scope_nodes = nil,
})
```

`max_matches` limits displayed references and excludes the cursor occurrence. Closed folds do not consume this budget.
`min_matches` counts occurrences within unfolded viewport ranges, including the cursor occurrence.

`delay` debounces cursor updates. Scroll updates use a minimum delay of 30 ms.
Parser completion can outlast the configured delay.

Highlighting appears only in the focused window. Repeated `setup()` calls replace the configuration and refresh highlights.
Setup copies supplied tables before validation. Later changes to those tables do not change the resolved configuration.

### Adding a Language

The plugin ships with scope tables for Lua, Python, JavaScript/TypeScript/TSX, Go, Rust, C, C++, and Ruby. For any other language with a treesitter parser, a generic fallback matches node types containing `_definition`, `_declaration`, `module`, and similar, which is usually good enough.

When the fallback misses or you want different scope boundaries, set `scope_nodes`. The table is deep-merged with the builtins, so you only specify what you're adding or overriding.

For a language without built-in scopes, providing `scope_nodes` replaces the generic fallback.
Set an existing node entry to `false` to remove that scope boundary.

**Adding an unsupported language**: list every node type that should act as a scope boundary. Use `:InspectTree` on a sample file to find them.

```lua
require('showtime').setup({
    scope_nodes = {
        bash = {
            program = true,
            function_definition = true,
            subshell = true,
        },
    },
})
```

**Extending a builtin language**: keys you add merge with the existing set. Here, Lua keeps its `chunk` / `function_definition` / `do_block` defaults and also treats `for_statement` as a scope boundary:

```lua
require('showtime').setup({
    scope_nodes = {
        lua = {
            for_statement = true,
        },
    },
})
```

### Highlight Groups

| Group | Default | Description |
|---|---|---|
| `ShowtimeReference` | links to `LspReferenceText` | Applied to all matching references except the one under the cursor |

Override in your colorscheme or config:

```lua
vim.api.nvim_set_hl(0, 'ShowtimeReference', { bg = '#2a2a3a' })
```

### Per-Buffer Disable

Disable highlighting for a specific buffer:

```lua
vim.b.showtime_disabled = true
```

## Commands

| Command | Description |
|---|---|
| `:ShowtimeEnable` | Enable reference highlighting |
| `:ShowtimeDisable` | Disable reference highlighting |
| `:ShowtimeToggle` | Toggle reference highlighting |
| `:ShowtimeNextReference` | Jump to the next reference in scope |
| `:ShowtimePrevReference` | Jump to the previous reference in scope |

## Navigation

`:ShowtimeNextReference` and `:ShowtimePrevReference` move between occurrences within the containing scope, including positions outside the viewport.
Both accept a count, respect `'wrapscan'`, and open destination folds. Successful jumps enter the jumplist, so `<C-o>` returns.
For example, `:2ShowtimeNextReference` moves forward two occurrences.

No keymaps are bound by default. Two `<Plug>` mappings are provided so you can bind your own:

```lua
vim.keymap.set('n', ']r', '<Plug>(showtime-next-reference)')
vim.keymap.set('n', '[r', '<Plug>(showtime-prev-reference)')
```

A Lua API is available too:

```lua
require('showtime').next_reference()
require('showtime').prev_reference()
```

Both functions accept an optional count. Navigation remains available after you disable highlighting.
Highlight limits and exclusions do not restrict navigation.

Matching uses identical text and node types within the nearest syntax scope. It does not resolve variable bindings.
Nested declarations can therefore match an outer variable with the same spelling.
A function declaration belongs to its own syntax scope. Selecting its name can omit calls outside that declaration.
Selecting an external call uses that call's containing scope.

## How It Works

1. The engine requests an asynchronous parse and selects the leaf node under the cursor.
2. It accepts node types containing `identifier` or `name` and finds the nearest scope boundary.
3. A query collects leaves with the same type and text within unfolded viewport ranges.
4. A decoration provider draws ephemeral extmarks in the focused window. It excludes the cursor occurrence.
5. A window cache tracks buffer edits, filetype, configuration, the selected identifier, its scope, and visible ranges.

Languages without scope tables use generic rules. Without a matching boundary, the engine uses the tree root.

Cursor movement, window entry, Insert exit, text edits, and filetype changes request updates.
Scrolling and fold changes refresh visible matches. Leave events and Insert entry cancel pending work.

Parser callbacks discard results when the buffer, cursor, filetype, window, or configuration changes.
Callbacks also recheck buffer exclusions.
Navigation caches complete scope results separately from visible matches.

## Health Check

Run `:checkhealth showtime` to verify your setup.
The report checks parsers for loaded source buffers and resolves highlight links.

## License

MIT, see [LICENSE](LICENSE).
