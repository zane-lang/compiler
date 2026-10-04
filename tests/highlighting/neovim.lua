local root = assert(vim.env.ZANE_TEST_ROOT)
vim.opt.runtimepath:prepend(assert(vim.env.ZANE_TEST_RUNTIME))
dofile(root .. '/editors/neovim/zane.lua')
vim.cmd('filetype on')
vim.cmd.edit(root .. '/tests/parser/fixtures/utf8.zn')
assert(vim.bo.filetype == 'zane', 'filetype detection failed')
local parser = vim.treesitter.get_parser(0, 'zane')
local tree = assert(parser:parse()[1])
assert(not tree:root():has_error(), 'fixture contains a parser error')
local query = assert(vim.treesitter.query.get('zane', 'highlights'))
local found = {}
for id in query:iter_captures(tree:root(), 0) do
  found[query.captures[id]] = true
end
assert(found.type and found.keyword, 'highlight queries did not match')
assert(vim.treesitter.highlighter.active[vim.api.nvim_get_current_buf()], 'highlighting did not start')
