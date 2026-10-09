local root = assert(vim.env.ZANE_TEST_ROOT)
vim.opt.runtimepath:prepend(assert(vim.env.ZANE_TEST_RUNTIME))
vim.opt.runtimepath:append(vim.env.ZANE_TEST_RUNTIME .. '/after')
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

-- Parameter uses resolve through the zane-bound? predicate zane.lua defines.
-- Each `// params:` comment in the fixture lists, in order, the identifiers on
-- its line that must be highlighted as parameters; no other one may be.
vim.cmd.edit(root .. '/tests/highlighting/parameters.zn')
local buf = vim.api.nvim_get_current_buf()
local ptree = assert(vim.treesitter.get_parser(buf, 'zane'):parse()[1])
assert(not ptree:root():has_error(), 'parameters fixture contains a parser error')
local identifiers = {}
local function collect(node)
  if node:type() == 'identifier' then
    table.insert(identifiers, node)
  end
  for child in node:iter_children() do
    collect(child)
  end
end
collect(ptree:root())
local checked = 0
for row, line in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
  local code, expected = line:match('^(.-)%s*// params:(.*)$')
  if code then
    local want = vim.split(vim.trim(expected), '%s+', { trimempty = true })
    local got = {}
    for _, node in ipairs(identifiers) do
      local srow, scol = node:start()
      if srow == row - 1 and scol < #code then
        for _, capture in ipairs(vim.treesitter.get_captures_at_pos(buf, srow, scol)) do
          if capture.capture == 'variable.parameter' then
            table.insert(got, vim.treesitter.get_node_text(node, buf))
            break
          end
        end
      end
    end
    assert(vim.deep_equal(got, want), ('line %d: expected parameters %s, got %s'):format(row, vim.inspect(want), vim.inspect(got)))
    checked = checked + 1
  end
end
assert(checked >= 6, 'too few annotated lines checked')

-- Check the captures Neovim actually loads, including its parameter extension.
-- A qualified name must not become a parameter just because its namespace or
-- member has the same spelling as one, nor may an explicit init key do so.
local role_cases = {
  {
    source = 'Unit main() { return Unit(); } Unit stop() { abort "stopped"; }',
    roles = { { 'return', 'keyword.return' }, { 'abort', 'keyword.return' } },
  },
  {
    source = 'Int f(operators Int) => @operators$add(operators, 1)',
    roles = { { '@operators', 'module', 1 }, { 'add', 'function.call' } },
  },
  {
    source = 'Int f(x Int) => pkg$x(x)',
    roles = { { 'pkg', 'module' }, { '$x', 'function.call', 1 } },
  },
  {
    source = 'Unit main() { @controlflow$repeat() {} obj:pkg$method() {} }',
    roles = { { 'controlflow', 'module' }, { 'repeat', 'function.call' }, { 'pkg', 'module' }, { 'method', 'function.method.call' } },
  },
  {
    source = 'type Vec = struct { x Int; } Vec(x Int) => init{x = x;}',
    roles = { { 'x Int;', 'variable.member' }, { 'x =', 'variable.member' } },
  },
}
for _, case in ipairs(role_cases) do
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { case.source })
  local tree = assert(vim.treesitter.get_parser(buf, 'zane'):parse()[1])
  assert(not tree:root():has_error(), case.source)
  for _, role in ipairs(case.roles) do
    local col = assert(case.source:find(role[1], 1, true)) - 1 + (role[3] or 0)
    local found = false
    for _, capture in ipairs(vim.treesitter.get_captures_at_pos(buf, 0, col)) do
      if capture.capture == role[2] then
        found = true
      elseif capture.capture ~= 'variable' then
        error(('unexpected %s for %s in %s'):format(capture.capture, role[1], case.source))
      end
    end
    assert(found, ('missing %s for %s'):format(role[2], role[1]))
  end
end
