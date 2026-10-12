local cache = require("hud.cache")
local M = {}

local diagnostics = cache.builtin(function(ctx)
  local counts = { 0, 0, 0, 0 }
  for _, diagnostic in ipairs(vim.diagnostic.get(ctx.buf)) do
    local severity = diagnostic.severity or vim.diagnostic.severity.ERROR
    counts[severity] = (counts[severity] or 0) + 1
  end
  local chunks = {}
  local names = { "Error", "Warn", "Info", "Hint" }
  local labels = { "E", "W", "I", "H" }
  for severity = 1, 4 do
    if counts[severity] > 0 then
      if #chunks > 0 then
        chunks[#chunks + 1] = " "
      end
      chunks[#chunks + 1] = {
        provider = labels[severity] .. ":" .. counts[severity],
        hl = "Diagnostic" .. names[severity],
      }
    end
  end
  return #chunks > 0 and chunks or "No diagnostics"
end, { "DiagnosticChanged" }, true)

local cursor = cache.builtin(function(ctx)
  return ("Ln %d Col %d"):format(ctx.lnum, ctx.col)
end, {
  "CursorMoved",
  "CursorMovedI",
  "TextChanged",
  "TextChangedI",
  "TextChangedP",
  "WinEnter",
  "WinLeave",
  "ModeChanged",
  "OptionSet",
})

-- Stable function identities also work when a lines factory calls these constructors.
function M.diagnostics()
  return diagnostics
end

function M.cursor()
  return cursor
end

return M
