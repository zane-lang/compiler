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

The plugin is the `editors/neovim` directory of the `zane-lang/compiler`
repository, so it is added to `'runtimepath'` by hand after the repository is
cloned.

With [lazy.nvim](https://github.com/folke/lazy.nvim), next to nvim-treesitter:

```lua
{
  "zane-lang/compiler",
  name = "zane.nvim",
  lazy = false,
  -- `init` runs before nvim-treesitter's `config`, so the parser is
  -- registered before nvim-treesitter installs anything.
  init = function(plugin)
    vim.opt.rtp:append(plugin.dir .. "/editors/neovim")
    require("zane").setup()
  end,
  -- Rebuilds the parser when an update changed the grammar.
  build = ":TSUpdate zane",
},
```

With Neovim 0.12's built-in `vim.pack`:

```lua
vim.pack.add({ { src = "https://github.com/zane-lang/compiler", name = "zane" } })
vim.opt.rtp:append(vim.pack.get({ "zane" })[1].path .. "/editors/neovim")
require("zane").setup()
```

Then install the parser like any other, with `:TSInstall zane` or by adding
`"zane"` to the list given to `require("nvim-treesitter").install()`.

A plugin manager that puts `editors/neovim` on `'runtimepath'` at startup, such
as vim-plug with `{ 'rtp': 'editors/neovim' }`, needs no `setup()` call:
`plugin/zane.lua` makes it.

## How the parser is built

The plugin registers `zane` with nvim-treesitter from its own checkout
(`editors/tree-sitter-zane`), not from a download. The parser is generated
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

The generated files come from `python3 -m tools.grammar`; see
[`grammar/README.md`](../../grammar/README.md). Without nvim-treesitter, build
the parser by hand as that guide describes.
