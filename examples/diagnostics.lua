-- From the repository root:
-- nvim -n -u NONE -i NONE -c 'luafile examples/diagnostics.lua'
vim.opt.runtimepath:append(vim.fn.getcwd())
local providers = require("hud.providers")
require("hud").setup({
  lines = { providers.diagnostics(), providers.cursor() },
  -- Col is the 1-based virtual column reported by virtcol(".").
  position = { row = 0, col = 0 },
})
