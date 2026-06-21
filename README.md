# showtime.nvim

Treesitter-powered reference highlighter for Neovim 0.11+. Put your cursor on an identifier and every other reference to it within the containing scope lights up. No external dependencies, no per-language configuration.

## Features

- **Scope-aware**: References are found within the containing function, method, class, or module, not the whole file.
- **Treesitter-native**: Works with any language that has a treesitter parser. No per-language setup.
- **Fast**: Viewport pruning, per-window caching, and an iterative DFS keep highlighting imperceptible on large files.
- **Zero config**: Sensible defaults out of the box. `setup()` is optional.

## Requirements

- Neovim >= 0.11
- A treesitter parser for the language you're editing (`:TSInstall <lang>`)

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
    --- Minimum references required before highlighting activates.
    --- The cursor's own occurrence counts, so the default of 2 means
    --- "highlight only when there is at least one other occurrence."
    --- An identifier with no siblings stays unhighlighted.
    min_matches = 2,
    --- Treesitter languages to skip (e.g., { 'markdown', 'help' }).
    exclude_languages = {},
    --- Buffer types to skip.
    exclude_buftypes = { 'nofile', 'terminal', 'prompt' },
    --- Per-language scope node overrides (deep-merged with builtins).
    --- See "Adding a Language" below.
    scope_nodes = nil,
})
```

### Adding a Language

The plugin ships with scope tables for Lua, Python, JavaScript/TypeScript/TSX, Go, Rust, C, C++, and Ruby. For any other language with a treesitter parser, a generic fallback matches node types containing `_definition`, `_declaration`, `module`, and similar, which is usually good enough.

When the fallback misses or you want different scope boundaries, set `scope_nodes`. The table is deep-merged with the builtins, so you only specify what you're adding or overriding.

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

Disable showtime for a specific buffer:

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

`:ShowtimeNextReference` and `:ShowtimePrevReference` move the cursor between the references showtime highlights, staying within the containing scope. Both honor a `[count]`, respect `'wrapscan'`, push the jumplist (so `<C-o>` returns), and open folds at the destination.

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

## How It Works

1. On `CursorMoved`, the engine checks whether the cursor is on a treesitter identifier (a leaf node whose type contains "identifier" or "name").
2. It walks up the tree to the nearest scope boundary using per-language node type tables, with a generic fallback for unknown languages, and falls back to the tree root.
3. An iterative DFS traverses the scope and collects all nodes with the same type and text, but only within the visible viewport.
4. Matching nodes are highlighted via extmarks. The node under the cursor is excluded.
5. A per-window cache keyed on buffer, changedtick, node identity, cursor position, scope range, and viewport bounds skips redundant work.

## Health Check

Run `:checkhealth showtime` to verify your setup.

## License

MIT, see [LICENSE](LICENSE).
