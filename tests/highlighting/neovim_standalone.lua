-- The standalone plugin (.github/scripts/assemble-neovim-plugin) carries its
-- grammar inside itself and registers the parser from there.
local plugin = assert(vim.env.ZANE_TEST_PLUGIN)
vim.opt.runtimepath:append(plugin)
vim.cmd.runtime('plugin/zane.lua')
local zane = require('zane')
assert(vim.fs.normalize(zane.grammar_dir) == vim.fs.normalize(plugin .. '/tree-sitter-zane'), zane.grammar_dir)
package.loaded['nvim-treesitter.parsers'] = {}
vim.api.nvim_exec_autocmds('User', { pattern = 'TSUpdate' })
local info = assert(package.loaded['nvim-treesitter.parsers'].zane, 'parser not registered').install_info
assert(vim.uv.fs_stat(info.path .. '/grammar.js'), 'grammar.js missing')
assert(vim.uv.fs_stat(info.path .. '/' .. info.queries .. '/highlights.scm'), 'shared query missing')
assert(info.revision and info.revision == zane.revision())
assert(vim.filetype.match({ filename = 'x.zn' }) == 'zane')
assert(vim.treesitter.query.get_files('zane', 'highlights')[1], 'extension query not on runtimepath')
