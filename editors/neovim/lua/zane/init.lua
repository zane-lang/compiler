-- Zane support for Neovim: filetype detection, Tree-sitter highlighting, the
-- `zane-bound?` query predicate, and the parser's registration with
-- nvim-treesitter, which builds it. See editors/neovim/README.md.
local grammar = require("zane.grammar")

local M = {}

-- editors/neovim, from this file's path (editors/neovim/lua/zane/init.lua).
local plugin_dir = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h:h")
-- The generated Tree-sitter grammar: inside the plugin in the standalone
-- repository (.github/scripts/assemble-neovim-plugin), beside it in the compiler's.
M.grammar_dir = vim.fs.joinpath(plugin_dir, "tree-sitter-zane")
if not vim.uv.fs_stat(M.grammar_dir) then
  M.grammar_dir = vim.fs.joinpath(vim.fs.dirname(plugin_dir), "tree-sitter-zane")
end

local configured = false
local notified = {}

local function notify_once(key, message)
  if not notified[key] then
    notified[key] = true
    vim.notify(message, vim.log.levels.WARN, { title = "zane" })
  end
end

-- The parser's revision: a hash of the grammar it is generated from. nvim-treesitter
-- rebuilds on `:TSUpdate` when the revision it installed differs.
function M.revision()
  local file = io.open(vim.fs.joinpath(M.grammar_dir, "grammar.js"), "rb")
  if not file then
    return nil
  end
  local text = file:read("*a")
  file:close()
  return vim.fn.sha256(text):sub(1, 16)
end

-- The revision nvim-treesitter last installed, or nil if it never built one.
function M.installed_revision()
  local ok, config = pcall(require, "nvim-treesitter.config")
  if not ok or not config.get_install_dir then
    return nil
  end
  local file = io.open(vim.fs.joinpath(config.get_install_dir("parser-info"), "zane.revision"), "r")
  if not file then
    return nil
  end
  local revision = file:read("*l")
  file:close()
  return revision
end

-- Registers the parser with nvim-treesitter (`main` branch). It is built from
-- this checkout, so the parser always matches the plugin's queries, and the
-- queries are linked rather than copied.
local function register()
  local ok, parsers = pcall(require, "nvim-treesitter.parsers")
  if not ok then
    return
  end
  parsers.zane = {
    install_info = {
      path = M.grammar_dir,
      generate = true,
      generate_from_json = false,
      queries = "queries",
      revision = M.revision(),
    },
  }
end

-- (#zane-bound? @name) holds when a binder of the captured name is a child of
-- one of the name's ancestors. Zane forbids a local from shadowing a parameter
-- (docs/design/semantics.md D14), so that binder is the one the name refers to.
--
-- The walk goes down from the root rather than up from the name: finding a
-- node's parent searches from the root each time, and a binder's siblings are
-- only scanned in a container, never in a long statement list.
local function bound(match, _, source, predicate)
  local binders, containers = grammar.binders, grammar.containers
  for _, node in ipairs(match[predicate[2]] or {}) do
    local name = vim.treesitter.get_node_text(node, source)
    local found = false
    local scope = node:tree():root()
    while scope and not scope:equal(node) and not found do
      if containers[scope:type()] then
        for child in scope:iter_children() do
          local binder = binders[child:type()] and child:named_child(0)
          if binder and vim.treesitter.get_node_text(binder, source) == name then
            found = true
            break
          end
        end
      end
      scope = scope:child_with_descendant(node)
    end
    if not found then
      return false
    end
  end
  return true
end

-- Starts highlighting unless something else already did, and says what to
-- run when the parser is missing or older than the grammar.
local function attach(buf)
  if not vim.treesitter.highlighter.active[buf] and not pcall(vim.treesitter.start, buf, "zane") then
    notify_once("missing", "No Zane parser is installed. Run :TSInstall zane (nvim-treesitter).")
    return
  end
  local installed = M.installed_revision()
  if installed and installed ~= M.revision() then
    notify_once("stale", "The Zane parser was built from an older grammar. Run :TSUpdate zane, then restart Neovim.")
  end
end

function M.setup()
  if configured then
    return
  end
  configured = true

  local extensions = {}
  for _, extension in ipairs(grammar.extensions) do
    extensions[extension] = "zane"
  end
  vim.filetype.add({ extension = extensions })

  vim.treesitter.query.add_predicate("zane-bound?", bound, { force = true })

  local group = vim.api.nvim_create_augroup("zane", { clear = true })
  -- nvim-treesitter fires this before it reads its parser table.
  vim.api.nvim_create_autocmd("User", { group = group, pattern = "TSUpdate", callback = register })
  vim.api.nvim_create_autocmd("FileType", {
    group = group,
    pattern = "zane",
    callback = function(args)
      attach(args.buf)
    end,
  })
end

return M
