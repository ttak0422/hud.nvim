# hud.nvim

Composable multiline HUDs for Neovim 0.10+.

## Setup

```lua
local providers = require("hud.providers")

require("hud").setup({
  lines = {
    providers.diagnostics(),
    providers.cursor(),
  },
})
```

`lines` accepts an array or a function returning an array (`nil` hides the HUD).
Each entry is a row: a string, provider function, or component with
`provider`, `condition`, `hl`, and nested children. Callbacks receive source-window
context, including `ctx.win`, `ctx.buf`, and `ctx.focused`.

`update` caches a component's callbacks until its listed events occur;
`lines_update` does the same for the row factory. Omit them for uncached callbacks.
Built-in diagnostics and cursor providers already declare their dependencies.

Rows with no output, including false conditions, are removed. Use `" "` for an
intentional blank row. Content and highlights can vary independently of row count.

Add `priority` to keep important components when a row is too wide: for example,
`{ { provider = "name", priority = 10 }, { " detail", priority = 0 } }`.
Lower priorities disappear first; rows without priorities keep prefix clipping.

`position` sets the top and right insets in cells. Rows are right-aligned in a
rectangular float over buffer text. By default, cursor overlap and Visual/Select
mode hide the active window's HUD.

## API

```lua
local hud = require("hud")
hud.setup(opts) -- Replace configuration and enable HUDs.
hud.hide()      -- Temporarily hide all HUDs.
hud.show()      -- Clear temporary hiding, respecting overlap rules.
hud.disable()   -- Stop updates and release HUD resources.
hud.enable()    -- Resume using the saved configuration.
hud.refresh()   -- Invalidate caches and schedule reevaluation.
```

`show()` does not enable a disabled instance. `enable()` preserves temporary
hiding; use `show()` to clear it.

See `:help hud.nvim` for full configuration and component details.

[MIT](LICENSE).
