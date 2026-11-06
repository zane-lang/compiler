-- :checkhealth zane
local M = {}

function M.check()
  local health = vim.health
  local zane = require("zane")
  health.start("zane")

  if vim.fn.has("nvim-0.11") == 1 then
    health.ok("Neovim 0.11 or newer")
  else
    health.error("Neovim 0.11 or newer is required")
  end

  if pcall(require, "nvim-treesitter.config") then
    health.ok("nvim-treesitter (main branch) builds the parser")
  else
    health.warn("nvim-treesitter (main branch) not found", {
      "Install it to build the parser with :TSInstall zane, or build zane.so by hand (grammar/README.md).",
    })
  end

  local cli = vim.fn.exepath("tree-sitter")
  if cli ~= "" then
    health.ok("tree-sitter CLI: " .. cli)
  else
    health.warn("tree-sitter CLI not on PATH", { "nvim-treesitter needs it to generate the Zane parser." })
  end

  if vim.uv.fs_stat(vim.fs.joinpath(zane.grammar_dir, "grammar.js")) then
    health.ok("grammar: " .. zane.grammar_dir)
  else
    health.error("grammar.js not found in " .. zane.grammar_dir)
  end

  local ok, loaded = pcall(vim.treesitter.language.add, "zane")
  if not ok or not loaded then
    health.error("no Zane parser on 'runtimepath'", { "Run :TSInstall zane." })
    return
  end
  health.ok("Zane parser loads")

  local installed = zane.installed_revision()
  if installed and installed ~= zane.revision() then
    health.warn("the parser was built from an older grammar", { "Run :TSUpdate zane, then restart Neovim." })
  elseif installed then
    health.ok("the parser matches the grammar")
  end

  local found, query = pcall(vim.treesitter.query.get, "zane", "highlights")
  if found and query then
    health.ok("highlight queries load")
  else
    health.error("highlight queries do not load: " .. tostring(query))
  end
end

return M
