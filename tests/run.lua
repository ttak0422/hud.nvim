vim.opt.runtimepath:prepend(vim.fn.getcwd())
local api = vim.api
local hud = require("hud")
local passed = 0
local notifications = {}
local original_notify = vim.notify
vim.notify = function(message)
  notifications[#notifications + 1] = message
end

local function equal(actual, expected, label)
  if not vim.deep_equal(actual, expected) then
    error((label or "values differ") .. "\nexpected: " .. vim.inspect(expected) .. "\nactual: " .. vim.inspect(actual))
  end
end

local function settle()
  vim.cmd("redraw")
  vim.wait(25)
end

local function floats()
  local result = {}
  for _, win in ipairs(api.nvim_list_wins()) do
    local buf = api.nvim_win_get_buf(win)
    if vim.b[buf].hud_source_win then
      result[vim.b[buf].hud_source_win] = { win = win, buf = buf }
    end
  end
  return result
end

local function buffers()
  local count = 0
  for _, buf in ipairs(api.nvim_list_bufs()) do
    if api.nvim_buf_is_valid(buf) and vim.b[buf].hud_source_win then
      count = count + 1
    end
  end
  return count
end

local function content(source)
  local float = floats()[source or api.nvim_get_current_win()]
  assert(float, "expected a HUD")
  return api.nvim_buf_get_lines(float.buf, 0, -1, false)
end

local function fixture()
  hud.disable()
  vim.cmd("silent! tabonly!")
  vim.cmd("silent! only!")
  vim.cmd("enew!")
  vim.o.lines, vim.o.columns = 30, 100
  vim.o.winminwidth, vim.o.winminheight = 1, 1
  vim.o.winwidth, vim.o.winheight = 1, 1
  vim.o.laststatus, vim.o.showtabline = 2, 0
  vim.wo.winbar, vim.wo.statusline = "", "SOURCE %f"
  vim.wo.number, vim.wo.relativenumber = false, false
  vim.wo.signcolumn, vim.wo.foldcolumn = "no", "0"
  vim.wo.wrap, vim.wo.foldenable, vim.wo.rightleft = true, false, false
  vim.wo.scrolloff, vim.wo.sidescrolloff = 0, 0
  vim.bo.buftype, vim.bo.tabstop = "", 8
  local lines = {}
  for index = 1, 100 do
    lines[index] = "source line " .. index
  end
  api.nvim_buf_set_lines(0, 0, -1, false, lines)
  api.nvim_win_set_cursor(0, { 10, 0 })
  vim.cmd("normal! zt")
  vim.cmd("normal! 5k")
  api.nvim_win_set_cursor(0, { 10, 0 })
  vim.cmd("normal! zz")
  vim.cmd("redraw")
  notifications = {}
  return api.nvim_get_current_win(), api.nvim_get_current_buf()
end

local function test(name, callback)
  fixture()
  callback()
  passed = passed + 1
  io.stdout:write("ok " .. passed .. " - " .. name .. "\n")
  io.stdout:flush()
end

local function run()
  test("source contexts, inactive windows, diagnostics and virtual cursor", function()
    local first, first_buf = api.nvim_get_current_win(), api.nvim_get_current_buf()
    api.nvim_buf_set_lines(first_buf, 0, 1, false, { "\t日本x" })
    api.nvim_win_set_cursor(first, { 1, 4 })
    vim.cmd("vnew")
    local second, second_buf = api.nvim_get_current_win(), api.nvim_get_current_buf()
    api.nvim_buf_set_lines(second_buf, 0, -1, false, { "one", "two", "three" })
    api.nvim_win_set_cursor(second, { 3, 2 })
    local ns = api.nvim_create_namespace("hud-test-diagnostics")
    vim.diagnostic.set(ns, first_buf, { { lnum = 0, col = 0, message = "bad", severity = 1 } })
    vim.diagnostic.set(ns, second_buf, {
      { lnum = 0, col = 0, message = "warn", severity = 2 },
      { lnum = 1, col = 0, message = "warn", severity = 2 },
    })
    local seen, focused = {}, second
    local function context(ctx)
      equal(api.nvim_get_current_win(), ctx.win, "source window callback context")
      equal(api.nvim_get_current_buf(), ctx.buf, "source buffer callback context")
      equal(ctx.focused, ctx.win == focused)
      seen[ctx.win] = ctx
      return true
    end
    local providers = require("hud.providers")
    hud.setup({
      avoid = { cursor = false },
      filter = context,
      lines = {
        {
          provider = providers.diagnostics(),
          condition = context,
          hl = function(ctx)
            context(ctx)
            return "Title"
          end,
        },
        function(ctx)
          context(ctx)
          return providers.cursor()(ctx)
        end,
      },
    })
    settle()
    equal(api.nvim_get_current_win(), second, "focus unchanged")
    equal(seen[first].byte_col, 4)
    equal(seen[first].col, 12, "virtcol includes tab and full Japanese character")
    equal(content(first)[1]:match("%S.*"), "E:1")
    equal(content(first)[2], "Ln 1 Col 12")
    equal(content(second)[1]:match("%S.*"), "W:2")
    equal(content(second)[2], "Ln 3 Col 3")
    assert(vim.wo[floats()[first].win].winhighlight:find("HudInactive", 1, true))
    assert(vim.wo[floats()[second].win].winhighlight:find("HudNormal", 1, true))
    vim.diagnostic.reset(ns, second_buf)
    settle()
    equal(content(second)[1], "No diagnostics", "DiagnosticChanged refresh")
    focused = first
    api.nvim_set_current_win(first)
    settle()
    assert(vim.wo[floats()[first].win].winhighlight:find("HudNormal", 1, true))
  end)

  test("composition, literal formats, blank rows and highlight byte ranges", function()
    hud.setup({
      avoid = { cursor = false },
      lines = {
        { hl = "Title", "日", { provider = "%l", hl = "String" }, { provider = "no", condition = false } },
        "x",
        function()
          return nil
        end,
      },
    })
    settle()
    equal(content(), { "日%l", "   x" })
    local float = floats()[api.nvim_get_current_win()]
    local marks = api.nvim_buf_get_extmarks(float.buf, api.nvim_create_namespace("hud.nvim"), 0, -1, { details = true })
    equal({ marks[1][2], marks[1][3], marks[1][4].end_col, marks[1][4].hl_group }, { 0, 0, 3, "Title" })
    equal({ marks[2][2], marks[2][3], marks[2][4].end_col, marks[2][4].hl_group }, { 0, 3, 5, "String" })
    hud.setup({ lines = {
      "",
      function()
        return nil
      end,
    } })
    settle()
    equal(floats(), {})
    hud.setup({ lines = {} })
    settle()
    equal(floats(), {})
  end)

  test("dynamic rows update focus, content, color and geometry across shared-buffer windows", function()
    local first, buf = api.nvim_get_current_win(), api.nvim_get_current_buf()
    vim.cmd("vsplit")
    local second = api.nvim_get_current_win()
    vim.cmd("vsplit")
    local third = api.nvim_get_current_win()
    local sources = { first, second, third }
    for index, source in ipairs(sources) do
      api.nvim_win_set_cursor(source, { index * 10, 0 })
    end
    local suffix = "!"
    local shared = {
      provider = function(ctx)
        return (ctx.focused and "Active " or "Idle ") .. ctx.lnum .. suffix
      end,
      hl = function(ctx)
        return ctx.focused and "Title" or "String"
      end,
    }
    local active, inactive = { shared, "details for this window" }, { shared }
    local focused = third
    hud.setup({
      avoid = { cursor = false },
      position = { row = 1, col = 2 },
      lines = function(ctx)
        equal(api.nvim_get_current_win(), ctx.win, "lines source-window context")
        equal(api.nvim_get_current_buf(), buf)
        equal(ctx.focused, ctx.win == focused)
        return ctx.focused and active or inactive
      end,
    })
    local function check()
      for index, source in ipairs(sources) do
        local rows = content(source)
        local is_focused = source == focused
        equal(#rows, is_focused and 2 or 1)
        equal(rows[1]:match("%S.*"), (is_focused and "Active " or "Idle ") .. index * 10 .. suffix)
        local float, info = floats()[source], vim.fn.getwininfo(source)[1]
        local cfg = api.nvim_win_get_config(float.win)
        equal(cfg.height, #rows)
        equal(cfg.row, info.winrow + (info.winbar or 0))
        equal(cfg.col + cfg.width, info.wincol - 1 + info.width - 2)
        local marks =
          api.nvim_buf_get_extmarks(float.buf, api.nvim_create_namespace("hud.nvim"), 0, -1, { details = true })
        equal(marks[1][4].hl_group, is_focused and "Title" or "String")
      end
      equal(api.nvim_get_current_win(), focused, "focus stays in the source")
    end
    settle()
    check()
    local initial = floats()
    focused = first
    api.nvim_set_current_win(first)
    settle() -- WinEnter/WinLeave must refresh both the old and new focused HUDs.
    check()
    equal(floats(), initial, "changing row count reuses all windows and buffers")
    suffix = "?"
    hud.refresh()
    settle()
    check()
    local tick = api.nvim_buf_get_changedtick(initial[first].buf)
    hud.refresh()
    settle()
    equal(api.nvim_buf_get_changedtick(initial[first].buf), tick, "dynamic results still avoid identical writes")
    api.nvim_win_set_width(first, 14)
    hud.refresh()
    settle()
    check()
    equal(api.nvim_win_get_config(initial[first].win).width, 12)
    equal(#active, 2, "returned row arrays stay intact")
    equal(#inactive, 1)
    assert(active[1] == shared and inactive[1] == shared, "component references stay intact")
  end)

  test("conditional and empty rows compact while explicit spaces retain a blank row", function()
    local visible = true
    hud.setup({
      avoid = { cursor = false },
      lines = {
        {
          condition = function()
            return visible
          end,
          provider = "head",
        },
        { { condition = false, provider = "nested" } },
        function()
          return visible and "body" or nil
        end,
        "",
        " ",
        { provider = "tail", hl = "Title" },
      },
    })
    settle()
    equal(content(), { "head", "body", "    ", "tail" })
    visible = false
    hud.refresh()
    settle()
    equal(content(), { "    ", "tail" })
    local float = floats()[api.nvim_get_current_win()]
    equal(api.nvim_win_get_height(float.win), 2)
    local marks = api.nvim_buf_get_extmarks(float.buf, api.nvim_create_namespace("hud.nvim"), 0, -1, { details = true })
    equal(marks[1][2], 1, "tail highlight follows its compacted row")
    visible = true
    hud.refresh()
    settle()
    equal(content(), { "head", "body", "    ", "tail" })
  end)

  test("all conditional rows hide and recover independently in shared-buffer windows", function()
    local first = api.nvim_get_current_win()
    vim.cmd("vsplit")
    local second = api.nvim_get_current_win()
    local visible = false
    hud.setup({
      avoid = { cursor = false },
      lines = {
        {
          condition = function(ctx)
            return visible and ctx.focused
          end,
          provider = "active",
        },
        function(ctx)
          return visible and ctx.focused and "detail" or nil
        end,
      },
    })
    settle()
    equal(floats(), {})
    visible = true
    hud.refresh()
    settle()
    equal(content(second), { "active", "detail" })
    equal(floats()[first], nil)
    api.nvim_set_current_win(first)
    settle()
    equal(content(first), { "active", "detail" })
    equal(floats()[second], nil)
    visible = false
    hud.refresh()
    settle()
    equal(floats(), {})
    visible = true
    hud.refresh()
    settle()
    equal(content(first), { "active", "detail" })
  end)

  test("row factory nil, invalid results and errors stay local and recover", function()
    local first = api.nvim_get_current_win()
    vim.cmd("vsplit")
    local second = api.nvim_get_current_win()
    local result = { "ready" }
    local failing = false
    hud.setup({
      avoid = { cursor = false },
      lines = function(ctx)
        if ctx.win == second then
          return { "safe" }
        end
        if failing then
          error("expected lines error")
        end
        return result
      end,
    })
    settle()
    equal(content(first), { "ready" })
    result = nil
    hud.refresh()
    settle()
    equal(floats()[first], nil)
    equal(#notifications, 0)
    for _, bad in ipairs({ false, "not an array", { [2] = "hole" }, { { condition = 42 } } }) do
      result = bad
      hud.refresh()
      settle()
      equal(floats()[first], nil)
      equal(content(second), { "safe" })
    end
    failing = true
    hud.refresh()
    settle()
    equal(#notifications, 1, "row factory failures deduplicate per callback")
    equal(content(second), { "safe" })
    result, failing = { "restored", "two" }, false
    hud.refresh()
    settle()
    equal(content(first), { "restored", "     two" })
    result = {}
    hud.refresh()
    settle()
    equal(floats()[first], nil)
  end)

  test("overlap and short-pane fitting use the compacted row count", function()
    local first_visible, second_visible = true, false
    local lines = {
      {
        condition = function()
          return first_visible
        end,
        provider = "first",
      },
      {
        condition = function()
          return second_visible
        end,
        provider = "second",
      },
    }
    hud.setup({ lines = lines })
    api.nvim_win_set_cursor(0, { 2, 0 })
    vim.fn.winrestview({ topline = 1 })
    hud.refresh()
    settle()
    equal(vim.fn.winline(), 2)
    equal(content(), { "first" }, "the removed second row must not hide the HUD")
    second_visible = true
    hud.refresh()
    settle()
    equal(floats(), {}, "visible second row overlaps the cursor")
    second_visible = false
    hud.refresh()
    settle()
    equal(content(), { "first" })
    first_visible = false
    hud.refresh()
    settle()
    equal(floats(), {})
    first_visible = true
    vim.cmd("split")
    local source = api.nvim_get_current_win()
    api.nvim_win_set_height(source, 1)
    hud.setup({ lines = lines, avoid = { cursor = false } })
    settle()
    equal(content(source), { "first" }, "one visible row fits a one-row pane")
    second_visible = true
    hud.refresh()
    settle()
    equal(floats()[source], nil)
    second_visible = false
    hud.refresh()
    settle()
    equal(content(source), { "first" })
  end)

  test("control and invalid byte normalization cannot inject rows", function()
    hud.setup({ avoid = { cursor = false }, lines = { "a\n\t\r\0\127\194\128b\255c" } })
    settle()
    equal(content(), { "a      b?c" })
  end)

  test("callback errors are isolated and deduplicated", function()
    local function bad()
      error("expected test error")
    end
    hud.setup({
      avoid = { cursor = false },
      lines = {
        { "good", bad, { provider = "hidden", condition = bad }, { provider = "ok", hl = bad }, "!" },
        "safe",
      },
    })
    settle()
    equal(content(), { "goodok!", "   safe" })
    equal(#notifications, 3)
    for _ = 1, 10 do
      hud.refresh()
    end
    settle()
    equal(#notifications, 3, "no warning flood")
    hud.setup({ filter = bad })
    settle()
    equal(floats(), {})
    hud.refresh()
    settle()
    equal(#notifications, 4)
  end)

  test("display-cell clipping preserves Japanese, composing and Nerd Font bytes", function()
    local component = require("hud.components")
    local cases = {
      { "日本", 1, "" },
      { "日本", 2, "日" },
      { "éz", 1, "é" },
      { "é日本", 3, "é日" },
      { "\239\128\128ab", 1, "\239\128\128" },
    }
    for _, case in ipairs(cases) do
      equal(component.fit({ { text = case[1], hl = "Title" } }, case[2]).text, case[3])
    end
    equal(component.fit({ { text = "e" }, { text = "́z" } }, 1).text, "é")
    vim.cmd("vnew")
    local source = api.nvim_get_current_win()
    api.nvim_win_set_width(source, 1)
    hud.setup({
      avoid = { cursor = false },
      filter = function(ctx)
        return ctx.win == source
      end,
      lines = { "日本" },
    })
    settle()
    equal(floats(), {}, "one-cell pane cannot fit Japanese glyph")
    api.nvim_win_set_width(source, 2)
    hud.refresh()
    settle()
    equal(content(), { "日" })
    hud.setup({
      avoid = { cursor = false },
      filter = function(ctx)
        return ctx.win == source
      end,
      lines = { "ab" },
    })
    api.nvim_win_set_width(source, 1)
    hud.refresh()
    settle()
    equal(content(), { "a" })
    hud.setup({
      avoid = { cursor = false },
      filter = function(ctx)
        return ctx.win == source
      end,
      lines = { "日", "x" },
    })
    settle()
    equal(content(), { " ", "x" }, "clipping does not compact a visible row")
    equal(api.nvim_win_get_height(floats()[source].win), 2)
  end)

  test("geometry respects winbar, gutters, insets and low panes", function()
    local source = api.nvim_get_current_win()
    vim.wo.winbar, vim.wo.number = "SOURCE BAR", true
    hud.setup({ avoid = { cursor = false }, position = { row = 1, col = 2 }, lines = { "long", "x" } })
    settle()
    local info, float = vim.fn.getwininfo(source)[1], floats()[source]
    local cfg = api.nvim_win_get_config(float.win)
    equal(cfg.row, info.winrow + info.winbar)
    equal(cfg.col, info.wincol - 1 + info.width - 2 - 4)
    equal({ cfg.width, cfg.height, cfg.focusable, cfg.zindex }, { 4, 2, false, 30 })
    equal(vim.wo[source].winbar, "SOURCE BAR")
    vim.cmd("split")
    source = api.nvim_get_current_win()
    api.nvim_win_set_height(source, 1)
    hud.refresh()
    settle()
    equal(floats()[source], nil, "insufficient content height hides HUD")
  end)

  test("cursor second-row, wrap, scroll and visual overlap", function()
    local source = api.nvim_get_current_win()
    hud.setup({ lines = { "top", "second" } })
    api.nvim_win_set_cursor(source, { 1, 0 })
    vim.cmd("normal! zt")
    hud.refresh()
    settle()
    equal(floats()[source], nil)
    api.nvim_win_set_cursor(source, { 2, 0 })
    hud.refresh()
    settle()
    equal(floats()[source], nil, "second HUD row hides")
    api.nvim_win_set_cursor(source, { 5, 0 })
    vim.fn.winrestview({ topline = 1, lnum = 5, col = 0, skipcol = 0 })
    equal(vim.fn.winline(), 5, "test cursor fixture row")
    hud.refresh()
    settle()
    assert(
      floats()[source],
      vim.inspect({ info = vim.fn.getwininfo(source), row = vim.fn.winline(), warnings = notifications })
    )
    vim.cmd("normal! v")
    hud.refresh()
    settle()
    equal(floats()[source], nil, "visual hides")
    vim.cmd("normal! \27")
    hud.show()
    settle()
    assert(floats()[source])
    api.nvim_buf_set_lines(0, 0, 1, false, { string.rep("a", api.nvim_win_get_width(source) + 10) })
    api.nvim_win_set_cursor(source, { 1, api.nvim_win_get_width(source) + 2 })
    vim.cmd("normal! zt")
    hud.refresh()
    settle()
    equal(floats()[source], nil, "wrapped second screen row hides")
    hud.setup({ avoid = { cursor = false, visual = false }, lines = { "top", "second" } })
    settle()
    assert(floats()[source])
  end)

  test("folds, scrolling and Select mode follow actual screen rows", function()
    local source = api.nvim_get_current_win()
    vim.wo.foldmethod, vim.wo.foldenable = "manual", true
    vim.cmd("1,4fold")
    api.nvim_win_set_cursor(source, { 5, 0 })
    vim.fn.winrestview({ topline = 1 })
    equal(vim.fn.winline(), 2)
    hud.setup({ lines = { "first", "second" } })
    settle()
    equal(floats()[source], nil, "folded first four lines put line five in second HUD row")
    api.nvim_win_set_cursor(source, { 6, 0 })
    vim.fn.winrestview({ topline = 1 })
    api.nvim_exec_autocmds("WinScrolled", { pattern = tostring(source) })
    settle()
    assert(floats()[source])
    vim.cmd("normal! gh")
    hud.refresh()
    settle()
    equal(floats()[source], nil, "Select mode hides")
    vim.cmd("normal! \27")
    vim.cmd("normal! zt")
    hud.refresh()
    settle()
    equal(floats()[source], nil, "scroll puts cursor in first HUD row")
  end)

  test("event coalescing, insert movement and no process or polling feedback", function()
    local calls, processes = 0, 0
    local saved = { system = vim.system, jobstart = vim.fn.jobstart, systemfn = vim.fn.system, spawn = vim.uv.spawn }
    local function forbidden()
      processes = processes + 1
      error("rendering must not start a process")
    end
    vim.system, vim.fn.jobstart, vim.fn.system, vim.uv.spawn = forbidden, forbidden, forbidden, forbidden
    hud.setup({
      avoid = { cursor = false },
      lines = {
        function(ctx)
          calls = calls + 1
          return "line " .. ctx.lnum
        end,
      },
    })
    settle()
    local previous_calls = calls
    for _ = 1, 20 do
      api.nvim_exec_autocmds("CursorMovedI", {})
      hud.refresh()
    end
    api.nvim_win_set_cursor(0, { 12, 0 })
    settle()
    equal(content(), { "line 12" })
    equal(calls, previous_calls + 1, "multiple events coalesce")
    previous_calls = calls
    vim.wait(100)
    equal(calls, previous_calls, "no feedback or polling")
    equal(processes, 0)
    vim.system, vim.fn.jobstart, vim.fn.system, vim.uv.spawn = saved.system, saved.jobstart, saved.systemfn, saved.spawn
    vim.wo.winbar = "new bar"
    api.nvim_exec_autocmds("OptionSet", { pattern = "winbar" })
    settle()
    equal(api.nvim_win_get_config(floats()[api.nvim_get_current_win()].win).row, 1)
  end)

  test("reuse, hide/show, disable/enable and external resource recovery", function()
    local source = api.nvim_get_current_win()
    hud.setup({ avoid = { cursor = false }, lines = { "stable" } })
    settle()
    local initial = floats()[source]
    local tick = api.nvim_buf_get_changedtick(initial.buf)
    for _ = 1, 10 do
      hud.refresh()
    end
    settle()
    equal(floats()[source], initial)
    equal(api.nvim_buf_get_changedtick(initial.buf), tick)
    hud.hide()
    settle()
    equal(floats(), {})
    equal(buffers(), 1)
    hud.show()
    settle()
    equal(floats()[source].buf, initial.buf)
    api.nvim_win_close(floats()[source].win, true)
    settle()
    assert(floats()[source], "external close recovers")
    api.nvim_buf_delete(floats()[source].buf, { force = true })
    settle()
    assert(floats()[source], "external buffer deletion recovers")
    hud.refresh()
    hud.disable()
    hud.show()
    settle()
    equal(floats(), {})
    equal(buffers(), 0)
    equal(pcall(api.nvim_get_autocmds, { group = "HudNvim" }), false)
    hud.enable()
    settle()
    equal(content(), { "stable" })
  end)

  test("repeat setup, invalid config atomicity and full module reload", function()
    hud.setup({ avoid = { cursor = false }, lines = { "a" } })
    settle()
    local autocmd_count = #api.nvim_get_autocmds({ group = "HudNvim" })
    local invalid = {
      { lines = false },
      { lines = { [2] = "hole" } },
      { zindex = 0 },
      { position = { row = -1 } },
      { avoid = { cursor = "yes" } },
      { lines = { { provider = 42 } } },
      { surprise = true },
    }
    for _, opts in ipairs(invalid) do
      equal(pcall(hud.setup, opts), false)
      equal(content(), { "a" })
    end
    for _ = 1, 3 do
      hud.setup({ avoid = { cursor = false }, lines = { "b" } })
    end
    settle()
    equal(buffers(), 1)
    equal(#api.nvim_get_autocmds({ group = "HudNvim" }), autocmd_count)
    hud.refresh()
    for name in pairs(package.loaded) do
      if name == "hud" or name:match("^hud%.") then
        package.loaded[name] = nil
      end
    end
    hud = require("hud")
    hud.setup({ avoid = { cursor = false }, lines = { "reloaded" } })
    settle()
    equal(content(), { "reloaded" })
    equal(buffers(), 1)
    equal(#api.nvim_get_autocmds({ group = "HudNvim" }), autocmd_count)
  end)

  test("tabs, split/window/buffer close and filter safety", function()
    local source = api.nvim_get_current_win()
    hud.setup({ avoid = { cursor = false }, lines = { "x" } })
    settle()
    vim.cmd("vsplit")
    settle()
    equal(vim.tbl_count(floats()), 2)
    vim.cmd("close")
    settle()
    equal(vim.tbl_count(floats()), 1)
    equal(buffers(), 1)
    vim.cmd("tabnew")
    settle()
    equal(floats()[source], nil)
    equal(buffers(), 1, "only current tab has resources")
    vim.cmd("tabclose")
    settle()
    assert(floats()[source])
    vim.bo.buftype = "nofile"
    hud.refresh()
    settle()
    equal(floats(), {})
    hud.setup({
      avoid = { cursor = false },
      filter = function()
        return true
      end,
      lines = { "x" },
    })
    local foreign = api.nvim_open_win(api.nvim_create_buf(false, true), false, {
      relative = "editor",
      row = 4,
      col = 4,
      width = 10,
      height = 2,
    })
    settle()
    equal(floats()[foreign], nil, "custom filter cannot include floats")
    equal(vim.tbl_count(floats()), 1)
    api.nvim_win_close(foreign, true)
    api.nvim_buf_delete(api.nvim_win_get_buf(source), { force = true })
    settle()
    equal(buffers(), 1, "replaced source buffer reuses one HUD")
  end)

  test("text events and source state preservation", function()
    local source, buf = api.nvim_get_current_win(), api.nvim_get_current_buf()
    local before = {
      lines = api.nvim_buf_get_lines(buf, 0, -1, false),
      cursor = api.nvim_win_get_cursor(source),
      view = vim.fn.winsaveview(),
      statusline = vim.wo.statusline,
      winbar = vim.wo.winbar,
      number = vim.wo.number,
      laststatus = vim.o.laststatus,
      showtabline = vim.o.showtabline,
    }
    hud.setup({
      avoid = { cursor = false },
      lines = {
        function(ctx)
          return api.nvim_buf_get_lines(ctx.buf, 0, 1, false)[1]
        end,
      },
    })
    settle()
    equal(content(), { "source line 1" })
    hud.refresh()
    settle()
    local after = {
      lines = api.nvim_buf_get_lines(buf, 0, -1, false),
      cursor = api.nvim_win_get_cursor(source),
      view = vim.fn.winsaveview(),
      statusline = vim.wo.statusline,
      winbar = vim.wo.winbar,
      number = vim.wo.number,
      laststatus = vim.o.laststatus,
      showtabline = vim.o.showtabline,
    }
    equal(after, before)
    api.nvim_buf_set_lines(buf, 0, 1, false, { "edited" })
    api.nvim_exec_autocmds("TextChanged", { buffer = buf })
    settle()
    equal(content(), { "edited" })
    api.nvim_exec_autocmds("ColorScheme", { pattern = "default" })
    settle()
    equal(content(), { "edited" })
    hud.refresh()
    api.nvim_exec_autocmds("VimLeavePre", {})
    settle()
    equal(buffers(), 0)
    equal(floats(), {})
  end)

  dofile("tests/cache.lua")({ test = test, equal = equal, settle = settle, content = content, floats = floats })
  dofile("tests/priority.lua")({ test = test, equal = equal, settle = settle, content = content, floats = floats })

  test("help tags and isolated example", function()
    vim.cmd("helptags doc")
    assert(vim.fn.filereadable("doc/tags") == 1)
    dofile("examples/diagnostics.lua")
    settle()
    hud.disable()
    equal(buffers(), 0)
  end)
end

local ok, err = xpcall(run, debug.traceback)
hud.disable()
vim.notify = original_notify
if not ok then
  io.stderr:write(tostring(err) .. "\n")
  vim.cmd("cquit 1")
else
  print(("PASS: %d test groups on Neovim %s"):format(passed, tostring(vim.version())))
  vim.cmd("qa!")
end
