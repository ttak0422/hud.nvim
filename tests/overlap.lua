return function(h)
  local api, hud = vim.api, require("hud")
  local test, equal, settle, floats = h.test, h.equal, h.settle, h.floats
  local function move(row, col, event)
    api.nvim_win_set_cursor(0, { row, col })
    api.nvim_exec_autocmds(event or "CursorMoved", {})
    settle()
  end
  local function text(lines)
    api.nvim_buf_set_lines(0, 0, #lines, false, lines)
    vim.fn.winrestview({ topline = 1, leftcol = 0, skipcol = 0 })
  end

  test("cursor rectangle boundaries, padding, cached restoration and explicit opt-out", function()
    local source = api.nvim_get_current_win()
    text({ string.rep("x", 100), string.rep("x", 100), string.rep("x", 100) })
    local calls = 0
    hud.setup({
      position = { col = 2 },
      lines = {
        {
          update = {},
          provider = function()
            calls = calls + 1
            return "123456"
          end,
        },
        "x",
      },
    })
    move(1, 91)
    local initial = floats()[source]
    assert(initial, "adjacent cell to left remains visible")
    local tick = api.nvim_buf_get_changedtick(initial.buf)
    move(1, 92)
    equal(floats()[source], nil, "left boundary overlaps")
    for _ = 1, 3 do
      api.nvim_exec_autocmds("CursorMoved", {})
      settle()
      equal(floats()[source], nil, "hidden HUD must not reopen itself")
    end
    move(1, 97)
    equal(floats()[source], nil, "right boundary overlaps")
    move(1, 98)
    equal(floats()[source].buf, initial.buf, "right inset restores the same buffer")
    move(2, 92)
    equal(floats()[source], nil, "opaque left padding also covers text")
    move(3, 92)
    assert(floats()[source], "row below rectangle restores HUD")
    equal(api.nvim_buf_get_changedtick(initial.buf), tick, "restoration does not rewrite identical text")
    equal(calls, 1, "visibility checks retain provider cache")
    local restored = floats()[source]
    move(3, 93)
    equal(floats()[source], restored, "non-overlapping moves do not recreate the float")
    hud.setup({ avoid = { cursor = false }, lines = { "123456" } })
    move(1, 99)
    assert(floats()[source], "explicit cursor=false still opts out")
  end)

  test("partial wide glyph overlap, combining text, tabs and virtual space", function()
    local source = api.nvim_get_current_win()
    hud.setup({ position = { col = 2 }, lines = { "123456" } })
    text({ string.rep("x", 91) .. "日" .. "tail" })
    move(1, 91)
    equal(floats()[source], nil, "only the second cell of Japanese overlaps")
    move(1, 90)
    assert(floats()[source])
    text({ string.rep("x", 91) .. "é" .. "tail" })
    move(1, 91)
    assert(floats()[source], "combining sequence is only one cell")
    move(1, 94)
    equal(floats()[source], nil)
    text({ string.rep("x", 88) .. "\tx" })
    move(1, 88)
    equal(floats()[source], nil, "tab cursor uses its displayed cell")
    vim.wo.virtualedit = "all"
    text({ "short" })
    vim.fn.setpos(".", { 0, 1, 6, 87 })
    api.nvim_exec_autocmds("CursorMoved", {})
    settle()
    equal(vim.fn.wincol(), 93)
    equal(floats()[source], nil, "virtual cursor beyond EOL overlaps")
    vim.fn.setpos(".", { 0, 1, 6, 86 })
    api.nvim_exec_autocmds("CursorMoved", {})
    settle()
    assert(floats()[source], "virtual cursor beside HUD is visible")
    vim.wo.virtualedit = ""
  end)

  test("screen coordinates include split origin, winbar, gutters and resize", function()
    local other = api.nvim_get_current_win()
    vim.cmd("vsplit")
    vim.cmd("wincmd l")
    local source = api.nvim_get_current_win()
    if source == other then
      other = vim.fn.win_getid(vim.fn.winnr("h"))
    end
    vim.wo.wrap = false
    vim.wo.winbar, vim.wo.number = "bar", true
    text({ string.rep("x", 100), string.rep("x", 100) })
    hud.setup({ position = { row = 1, col = 1 }, lines = { "123456" } })
    move(2, 0)
    local geometry = api.nvim_win_get_config(floats()[source].win)
    local info = vim.fn.getwininfo(source)[1]
    local column = geometry.col - (info.wincol - 1) - info.textoff
    move(2, column)
    equal(floats()[source], nil)
    assert(floats()[other], "inactive split stays visible")
    move(1, column)
    assert(floats()[source], "winbar and row inset must not shift hitbox upward")
    move(2, column - 1)
    assert(floats()[source])
    api.nvim_win_set_width(source, info.width - 2)
    api.nvim_exec_autocmds("WinResized", {})
    settle()
    equal(floats()[source], nil, "resizing moves the HUD onto the cursor")
    api.nvim_win_set_width(source, info.width)
    api.nvim_exec_autocmds("WinResized", {})
    settle()
    assert(floats()[source], "growing window restores HUD")
  end)

  test("horizontal scroll and wrapped screen columns decide overlap", function()
    local source = api.nvim_get_current_win()
    text({ string.rep("x", 300) })
    hud.setup({ lines = { "123456", "detail" } })
    move(1, 193)
    assert(floats()[source], "wrapped second row just left of HUD")
    move(1, 194)
    equal(floats()[source], nil, "wrapped second row overlaps")
    move(1, 200)
    assert(floats()[source], "third wrapped row is below HUD")
    vim.wo.wrap = false
    api.nvim_win_set_cursor(0, { 1, 114 })
    vim.fn.winrestview({ topline = 1, leftcol = 20 })
    api.nvim_exec_autocmds("WinScrolled", { pattern = tostring(source) })
    settle()
    equal(floats()[source], nil, "horizontal viewport maps buffer column onto HUD")
    vim.fn.winrestview({ topline = 1, leftcol = 21 })
    api.nvim_exec_autocmds("WinScrolled", { pattern = tostring(source) })
    settle()
    assert(floats()[source], "scrolling one cell away restores HUD")
  end)

  test("right-to-left windows mirror cursor cells including wide glyph boundaries", function()
    local source = api.nvim_get_current_win()
    vim.wo.rightleft, vim.wo.number = true, true
    text({ "12345日tail" })
    hud.setup({ lines = { "123456" } })
    move(1, 0)
    equal(floats()[source], nil, "RTL first character is at the right edge")
    move(1, 5)
    equal(floats()[source], nil, "one mirrored cell of a wide glyph overlaps")
    move(1, 8)
    assert(floats()[source], "RTL cursor beyond the rectangle restores HUD")
  end)

  test("cursor overlap still hides in Visual/Select and insert movement events", function()
    local source = api.nvim_get_current_win()
    text({ string.rep("x", 100) })
    hud.setup({ lines = { "123456" } })
    for _, mode in ipairs({ "v", "V", "\22", "gh" }) do
      move(1, 93)
      vim.cmd("normal! " .. mode)
      api.nvim_exec_autocmds("ModeChanged", {})
      settle()
      assert(floats()[source], "selection alone must not hide")
      move(1, 94)
      equal(floats()[source], nil, "selection cursor overlaps")
      move(1, 93)
      assert(floats()[source], "moving away during selection restores HUD")
      vim.cmd("normal! \27")
    end
    move(1, 94, "CursorMovedI")
    equal(floats()[source], nil)
    move(1, 93, "CursorMovedI")
    assert(floats()[source])
  end)
end
