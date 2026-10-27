return function(t)
  local api, hud, providers = vim.api, require("hud"), require("hud.providers")
  local test, equal, settle, content, floats = t.test, t.equal, t.settle, t.content, t.floats
  local function event(name, source)
    api.nvim_win_call(source or api.nvim_get_current_win(), function()
      api.nvim_exec_autocmds(name, {})
    end)
    settle()
  end
  local function three_windows()
    local first, buf = api.nvim_get_current_win(), api.nvim_get_current_buf()
    vim.cmd("vsplit")
    local second = api.nvim_get_current_win()
    vim.cmd("vnew")
    local third = api.nvim_get_current_win()
    local rows = {}
    for i = 1, 100 do
      rows[i] = "other " .. i
    end
    api.nvim_buf_set_lines(0, 0, -1, false, rows)
    api.nvim_win_set_cursor(third, { 10, 0 })
    return { first, second, third }, { buf, buf, api.nvim_get_current_buf() }
  end

  test("90 cursor events evaluate only target callbacks and never reread diagnostics", function()
    local wins, bufs = three_windows()
    local calls, gets = {}, {}
    for _, win in ipairs(wins) do
      calls[win] = { 0, 0, 0 }
    end
    local data = { [bufs[1]] = { { severity = 1 } }, [bufs[3]] = { { severity = 2 } } }
    local original = vim.diagnostic.get
    vim.diagnostic.get = function(buf)
      gets[buf] = (gets[buf] or 0) + 1
      return data[buf]
    end
    hud.setup({
      avoid = { cursor = false },
      lines = {
        providers.diagnostics(),
        providers.cursor(),
        {
          update = { "CursorMoved", "CursorMovedI" },
          condition = function(ctx)
            calls[ctx.win][1] = calls[ctx.win][1] + 1
            return true
          end,
          hl = function(ctx)
            calls[ctx.win][2] = calls[ctx.win][2] + 1
            return ctx.lnum % 2 == 0 and "Title" or "Comment"
          end,
          provider = function(ctx)
            calls[ctx.win][3] = calls[ctx.win][3] + 1
            equal(api.nvim_get_current_win(), ctx.win)
            equal(api.nvim_get_current_buf(), ctx.buf)
            return tostring(ctx.lnum)
          end,
        },
      },
    })
    settle()
    equal(gets, { [bufs[1]] = 1, [bufs[3]] = 1 }, "one diagnostic read per buffer at startup")
    local initial = vim.deepcopy(calls)
    for _, source in ipairs(wins) do
      local before = vim.deepcopy(calls)
      for step = 1, 30 do
        api.nvim_win_call(source, function()
          api.nvim_win_set_cursor(source, { step + 10, 0 })
          api.nvim_exec_autocmds(step % 2 == 0 and "CursorMoved" or "CursorMovedI", {})
        end)
        settle()
      end
      for _, win in ipairs(wins) do
        for role = 1, 3 do
          equal(calls[win][role] - before[win][role], win == source and 30 or 0)
        end
      end
      equal(content(source)[2]:match("%S.*"), "Ln 40 Col 1", "builtin cursor follows the event window")
    end
    equal(gets, { [bufs[1]] = 1, [bufs[3]] = 1 }, "90 movements must add zero diagnostic reads")
    for _, win in ipairs(wins) do
      equal(calls[win][3] - initial[win][3], 30)
    end
    local before = vim.deepcopy(calls)
    data[bufs[1]] = { { severity = 1 }, { severity = 1 } }
    api.nvim_exec_autocmds("DiagnosticChanged", { buffer = bufs[1] })
    settle()
    equal(gets, { [bufs[1]] = 2, [bufs[3]] = 1 }, "only changed buffer is read, once for two windows")
    equal(content(wins[1])[1]:match("%S.*"), "E:2")
    equal(content(wins[2])[1]:match("%S.*"), "E:2")
    equal(content(wins[3])[1]:match("%S.*"), "W:1")
    equal(calls, before, "diagnostics must not rerun cursor-only components")
    vim.diagnostic.get = original
    io.stdout:write(
      "counts: 3 windows, 2 buffers, 90 cursor events => "
        .. "90 provider + 90 condition + 90 highlight calls; 0 extra diagnostic reads\n"
    )
  end)

  test("focus invalidates old/new line factories and components without mixing contexts", function()
    local wins, bufs = three_windows()
    api.nvim_win_set_buf(wins[3], bufs[1])
    local factories, statuses = {}, {}
    local visible = true
    local status = {
      update = { "WinEnter", "WinLeave" },
      provider = function(ctx)
        statuses[ctx.win] = (statuses[ctx.win] or 0) + 1
        return ctx.focused and "Active" or "Idle"
      end,
      hl = function(ctx)
        return ctx.focused and "Title" or "Comment"
      end,
    }
    hud.setup({
      avoid = { cursor = false },
      lines_update = { "WinEnter", "WinLeave", "User", "WinResized" },
      lines = function(ctx)
        equal(api.nvim_get_current_win(), ctx.win)
        equal(ctx.buf, bufs[1])
        factories[ctx.win] = (factories[ctx.win] or 0) + 1
        if not visible then
          return nil
        end
        return ctx.focused and ctx.width > 15 and { status, "detail" } or { status }
      end,
    })
    settle()
    local before_f, before_s = vim.deepcopy(factories), vim.deepcopy(statuses)
    api.nvim_set_current_win(wins[1])
    settle()
    for i, win in ipairs(wins) do
      equal(factories[win] - before_f[win], i == 2 and 0 or 1)
      equal(statuses[win] - before_s[win], i == 2 and 0 or 1)
      equal(content(win)[1]:match("%S.*"), i == 1 and "Active" or "Idle")
      equal(#content(win), i == 1 and 2 or 1)
    end
    before_f, before_s = vim.deepcopy(factories), vim.deepcopy(statuses)
    event("CursorMoved", wins[1])
    equal(factories, before_f)
    equal(statuses, before_s)
    visible = false
    event("User")
    equal(floats(), {})
    local hidden_calls = vim.deepcopy(factories)
    event("CursorMoved", wins[1])
    equal(factories, hidden_calls, "nil line results are cached too")
    visible = true
    event("User")
    equal(content(wins[1]), { " Active", " detail" })
    api.nvim_win_set_width(wins[1], 12)
    event("WinResized")
    equal(content(wins[1]), { " Active" })
  end)

  test("fresh tables use explicit identity; reordered or replaced definitions stay correct", function()
    local stable_calls, fresh_calls, closure_calls = 0, 0, 0
    local value, reverse, include = "one", false, true
    local stable = function()
      stable_calls = stable_calls + 1
      return "stable"
    end
    local fresh = function()
      fresh_calls = fresh_calls + 1
      return "fresh"
    end
    local provider = stable
    hud.setup({
      avoid = { cursor = false },
      lines = function()
        local captured = value
        local a = { id = "stable", update = { "User" }, provider = provider }
        local b = { update = { "User" }, provider = fresh }
        local c = {
          id = "closure",
          update = {},
          provider = function()
            closure_calls = closure_calls + 1
            return captured
          end,
        }
        if not include then
          return { b, c }
        end
        return reverse and { c, b, a } or { a, b, c }
      end,
    })
    settle()
    equal({ stable_calls, fresh_calls, closure_calls }, { 1, 1, 1 })
    value, reverse = "two", true
    event("CursorMoved")
    equal({ stable_calls, fresh_calls, closure_calls }, { 1, 2, 2 })
    equal(content(), { "    two", "  fresh", " stable" })
    include = false
    event("CursorMoved")
    include = true
    event("CursorMoved")
    equal(stable_calls, 2, "removed identities expire")
    provider = function()
      stable_calls = stable_calls + 1
      return "replacement"
    end
    event("CursorMoved")
    equal(stable_calls, 3, "changed function identity invalidates a stable id")
    equal(content()[3], " replacement")
    hud.refresh()
    settle()
    equal(stable_calls, 4, "manual refresh forces callbacks despite their update lists")
  end)

  test("cached parents do not suppress child dependencies or inherited highlight changes", function()
    local parent_calls, child_calls, conditions, highlights = 0, 0, 0, 0
    local allowed, color = true, "Title"
    local child = {
      update = { "CursorMoved" },
      provider = function(ctx)
        child_calls = child_calls + 1
        return "line " .. ctx.lnum
      end,
    }
    hud.setup({
      avoid = { cursor = false },
      lines = {
        {
          update = { "User" },
          condition = function()
            conditions = conditions + 1
            return allowed
          end,
          hl = function()
            highlights = highlights + 1
            return color
          end,
          provider = function()
            parent_calls = parent_calls + 1
            return child
          end,
        },
      },
    })
    settle()
    api.nvim_win_set_cursor(0, { 20, 0 })
    event("CursorMoved")
    equal({ parent_calls, conditions, highlights, child_calls }, { 1, 1, 1, 2 })
    equal(content(), { " line 20" })
    color = "Comment"
    event("User")
    equal({ parent_calls, conditions, highlights, child_calls }, { 2, 2, 2, 2 })
    local float = floats()[api.nvim_get_current_win()]
    local marks = api.nvim_buf_get_extmarks(float.buf, api.nvim_create_namespace("hud.nvim"), 0, -1, { details = true })
    equal(marks[1][4].hl_group, "Comment")
    allowed = false
    event("User")
    equal(floats(), {})
    event("CursorMoved")
    equal({ parent_calls, conditions, highlights, child_calls }, { 2, 3, 2, 2 })
    allowed = true
    event("User")
    equal(child_calls, 3, "child removed by a false condition is cold on return")
  end)

  test("TextChanged is buffer-local, ColorScheme and manual refresh force all caches", function()
    local wins, bufs = three_windows()
    local calls, color = {}, "Title"
    hud.setup({
      avoid = { cursor = false },
      lines = {
        {
          update = { "TextChanged", "TextChangedI", "TextChangedP" },
          provider = function(ctx)
            calls[ctx.win] = (calls[ctx.win] or 0) + 1
            return ctx.win .. ":" .. api.nvim_buf_get_lines(ctx.buf, 0, 1, false)[1]
          end,
          hl = function()
            return color
          end,
        },
      },
    })
    settle()
    local before = vim.deepcopy(calls)
    api.nvim_buf_set_lines(bufs[1], 0, 1, false, { "edited" })
    api.nvim_exec_autocmds("TextChanged", { buffer = bufs[1] })
    settle()
    for i, win in ipairs(wins) do
      equal(calls[win] - before[win], i == 3 and 0 or 1)
      if i ~= 3 then
        equal(content(win), { " " .. win .. ":edited" })
      end
    end
    before = vim.deepcopy(calls)
    color = "Comment"
    event("ColorScheme")
    for _, win in ipairs(wins) do
      equal(calls[win] - before[win], 1)
      local marks =
        api.nvim_buf_get_extmarks(floats()[win].buf, api.nvim_create_namespace("hud.nvim"), 0, -1, { details = true })
      equal(marks[1][4].hl_group, "Comment")
    end
    before = vim.deepcopy(calls)
    hud.refresh()
    settle()
    for _, win in ipairs(wins) do
      equal(calls[win] - before[win], 1)
    end
  end)

  test("safe default and explicit global dependencies reevaluate all contexts", function()
    local wins = three_windows()
    local safe, global, local_calls = {}, {}, {}
    hud.setup({
      avoid = { cursor = false },
      lines = {
        function(ctx)
          safe[ctx.win] = (safe[ctx.win] or 0) + 1
          return "safe"
        end,
        {
          update = { "CursorMoved" },
          scope = "global",
          provider = function(ctx)
            global[ctx.win] = (global[ctx.win] or 0) + 1
            return "global"
          end,
        },
        {
          update = { "CursorMoved" },
          provider = function(ctx)
            local_calls[ctx.win] = (local_calls[ctx.win] or 0) + 1
            return "local"
          end,
        },
      },
    })
    settle()
    local before_s, before_g, before_l = vim.deepcopy(safe), vim.deepcopy(global), vim.deepcopy(local_calls)
    event("CursorMoved", wins[1])
    for i, win in ipairs(wins) do
      equal(safe[win] - before_s[win], 1)
      equal(global[win] - before_g[win], 1)
      equal(local_calls[win] - before_l[win], i == 1 and 1 or 0)
    end
  end)

  test("coalesced and hidden events retain every affected source", function()
    local wins, bufs = three_windows()
    local calls, factories, reads = {}, {}, {}
    local cursor = function(ctx)
      calls[ctx.win] = (calls[ctx.win] or 0) + 1
      return tostring(ctx.lnum)
    end
    local diagnostic = function(ctx)
      reads[ctx.win] = (reads[ctx.win] or 0) + 1
      return "D" .. reads[ctx.win]
    end
    hud.setup({
      avoid = { cursor = false },
      lines_update = { "CursorMoved" },
      lines_scope = "global",
      lines = function(ctx)
        factories[ctx.win] = (factories[ctx.win] or 0) + 1
        return {
          { id = "cursor", update = { "CursorMoved" }, provider = cursor },
          {
            id = "buffer",
            update = { "DiagnosticChanged" },
            provider = diagnostic,
          },
        }
      end,
    })
    settle()
    local before = vim.deepcopy(calls)
    local before_f = vim.deepcopy(factories)
    for index = 1, 2 do
      api.nvim_win_call(wins[index], function()
        api.nvim_win_set_cursor(0, { 30 + index, 0 })
        api.nvim_exec_autocmds("CursorMoved", {})
      end)
    end
    settle()
    for index, win in ipairs(wins) do
      equal(calls[win] - before[win], index == 3 and 0 or 1)
      equal(factories[win] - before_f[win], 1, "global factory invalidates once per coalesced pass")
    end
    equal(content(wins[1]), { " 31", " D1" })
    equal(content(wins[2]), { " 32", " D1" })
    api.nvim_exec_autocmds("DiagnosticChanged", { buffer = bufs[1] })
    api.nvim_exec_autocmds("DiagnosticChanged", { buffer = bufs[3] })
    settle()
    for _, win in ipairs(wins) do
      equal(reads[win], 2, "both coalesced buffer events survive")
    end
    before = vim.deepcopy(calls)
    hud.hide()
    settle()
    api.nvim_win_call(wins[3], function()
      api.nvim_win_set_cursor(0, { 40, 0 })
      api.nvim_exec_autocmds("CursorMoved", {})
    end)
    api.nvim_exec_autocmds("DiagnosticChanged", { buffer = bufs[1] })
    settle()
    equal(calls, before, "hidden HUDs do not evaluate callbacks")
    hud.show()
    settle()
    for index, win in ipairs(wins) do
      equal(calls[win] - before[win], index == 3 and 1 or 0)
      equal(reads[win], index == 3 and 2 or 3)
    end
    equal(content(wins[3]), { " 40", " D2" })
  end)

  test("binding changes, setup and disable/enable invalidate cached callbacks", function()
    local source, calls, factories = api.nvim_get_current_win(), 0, 0
    local component = {
      update = {},
      provider = function(ctx)
        calls = calls + 1
        return ctx.win .. ":" .. ctx.buf
      end,
    }
    local opts = {
      avoid = { cursor = false },
      lines_update = {},
      lines = function()
        factories = factories + 1
        return { component }
      end,
    }
    hud.setup(opts)
    settle()
    equal({ calls, factories }, { 1, 1 })
    event("CursorMoved")
    equal({ calls, factories }, { 1, 1 })
    local old_buf = api.nvim_get_current_buf()
    local new_buf = api.nvim_create_buf(true, false)
    api.nvim_win_set_buf(source, new_buf)
    settle()
    equal(content(), { " " .. source .. ":" .. new_buf })
    equal({ calls, factories }, { 2, 2 })
    api.nvim_buf_delete(old_buf, { force = true })
    settle()
    equal({ calls, factories }, { 2, 2 }, "closing unrelated old buffer does not invalidate this binding")
    hud.disable()
    hud.enable()
    settle()
    equal({ calls, factories }, { 3, 3 })
    hud.setup(opts)
    settle()
    equal({ calls, factories }, { 4, 4 })
    vim.cmd("vsplit")
    settle()
    local second = api.nvim_get_current_win()
    equal(content(second), { " " .. second .. ":" .. new_buf })
    equal({ calls, factories }, { 5, 5 })
    vim.cmd("close")
    settle()
    event("CursorMoved")
    equal({ calls, factories }, { 5, 5 })
    vim.cmd("vsplit")
    settle()
    equal({ calls, factories }, { 6, 6 }, "new windows get cold, isolated caches")
  end)

  test("cache failures retry and dependency configuration is validated atomically", function()
    local calls, failing = 0, true
    hud.setup({
      avoid = { cursor = false },
      lines = {
        "safe",
        {
          update = {},
          provider = function()
            calls = calls + 1
            if failing then
              error("expected cached callback failure")
            end
            return "recovered"
          end,
        },
      },
    })
    settle()
    equal(calls, 1)
    failing = false
    event("CursorMoved")
    equal(calls, 2)
    equal(content(), { "      safe", " recovered" })
    for _, bad in ipairs({
      { lines = { { update = "CursorMoved", provider = "x" } } },
      { lines = { { update = { "NotAnEvent" }, provider = "x" } } },
      { lines = { { update = { [2] = "CursorMoved" }, provider = "x" } } },
      { lines = { { scope = "buffer", provider = "x" } } },
      { lines = { { scope = "global", provider = "x" } } },
      { lines = { { id = "", provider = "x" } } },
      { lines = { "x" }, lines_update = {} },
    }) do
      equal(pcall(hud.setup, bad), false)
      equal(content(), { "      safe", " recovered" })
    end
  end)

  test("fresh component identities are released after leaving the rendered structure", function()
    local weak = setmetatable({}, { __mode = "k" })
    hud.setup({
      avoid = { cursor = false },
      lines = function()
        local node = {
          update = {},
          provider = function()
            return "fresh"
          end,
        }
        weak[node] = true
        return { node }
      end,
    })
    settle()
    for _ = 1, 20 do
      event("CursorMoved")
    end
    collectgarbage("collect")
    local count = 0
    for _ in pairs(weak) do
      count = count + 1
    end
    equal(count, 1, "only the latest anonymous component is retained")
    hud.disable()
    collectgarbage("collect")
    count = 0
    for _ in pairs(weak) do
      count = count + 1
    end
    equal(count, 0, "disable releases cached node identities")
  end)
end
