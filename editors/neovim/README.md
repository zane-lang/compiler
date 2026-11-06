# Zane for Neovim

This directory is a Neovim plugin. It gives `.zn` and `.zane` files the `zane`
filetype, starts Tree-sitter highlighting, and defines the `zane-bound?` query
predicate that colours a parameter wherever it is used. It also registers the
Zane parser with [nvim-treesitter](https://github.com/nvim-treesitter/nvim-treesitter),
which builds the parser and installs it.

It needs Neovim **0.11 or newer**, nvim-treesitter's `main` branch, the
[Tree-sitter CLI](https://github.com/tree-sitter/tree-sitter/tree/master/crates/cli)
and a C compiler. Node is not needed: nvim-treesitter generates the parser with
the CLI's built-in JavaScript runtime.

## Install

Install [`TheLazyCat00/zane-nvim`](https://github.com/TheLazyCat00/zane-nvim).
With [lazy.nvim](https://github.com/folke/lazy.nvim), next to nvim-treesitter:

```lua
{
  "TheLazyCat00/zane-nvim",
  lazy = false,
  -- Loads before nvim-treesitter's `config`, so the parser is registered
  -- before nvim-treesitter installs anything.
  priority = 1000,
  -- Rebuilds the parser when an update changed the grammar.
  build = ":TSUpdate zane",
},
```

With Neovim 0.12's built-in `vim.pack`, before nvim-treesitter is set up:

```lua
vim.pack.add({ "https://github.com/TheLazyCat00/zane-nvim" })
```

Then install the parser like any other, with `:TSInstall zane` or by adding
`"zane"` to the list given to `require("nvim-treesitter").install()`.
`plugin/zane.lua` calls `require("zane").setup()` when the plugin loads.

`zane-nvim` is published from
[`editors/neovim`](https://github.com/zane-lang/compiler/tree/main/editors/neovim)
in `zane-lang/compiler`, together with the generated grammar under
`tree-sitter-zane/`, by the `Neovim plugin` workflow there; change it there.
To use a compiler checkout instead, add its `editors/neovim` to
`'runtimepath'` and call `require("zane").setup()`; the plugin then builds the
parser from `editors/tree-sitter-zane` beside it.

## How the parser is built

The plugin registers `zane` with nvim-treesitter from its own checkout
(`tree-sitter-zane`), not from a download. The parser is generated
from the same `grammar.js` as the queries the plugin ships, and nvim-treesitter
links those queries rather than copying them. The registered revision is a
hash of `grammar.js`, so `:TSUpdate zane` rebuilds the parser only when the
grammar changed. Generating writes `src/` and `parser.so` into the checkout,
which Git ignores.

When a Zane buffer opens, the plugin reports a missing parser (run
`:TSInstall zane`) or one built from an older grammar (run `:TSUpdate zane`,
then restart Neovim: a loaded parser cannot be replaced).
`:checkhealth zane` checks the whole setup.

## Files

| File | |
|---|---|
| `plugin/zane.lua` | Calls `setup()` at startup |
| `lua/zane/init.lua` | `setup()`: filetype, highlighting, `zane-bound?`, nvim-treesitter registration |
| `lua/zane/health.lua` | `:checkhealth zane` |
| `lua/zane/grammar.lua` | Generated: the file extensions and the binder nodes `zane-bound?` scans |
| `queries/zane/highlights.scm` | Generated: Neovim-only captures, appended to the shared query with `; extends` |
| `tree-sitter-zane/` | In `zane-nvim` only: the generated grammar and the shared query, from `editors/tree-sitter-zane` |

The generated files come from `python3 -m tools.grammar`; see
[`grammar/README.md`](https://github.com/zane-lang/compiler/blob/main/grammar/README.md). Without nvim-treesitter, build
the parser by hand as that guide describes.
