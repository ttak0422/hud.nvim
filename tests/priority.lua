return function(t)
  local api, hud = vim.api, require("hud")
  local components, providers = require("hud.components"), require("hud.providers")
  local test, equal, settle, content, floats = t.test, t.equal, t.settle, t.content, t.floats
  local function render(node)
    return components.render(node, {}, function(_, message)
      error(message)
    end)
  end
  local function fit(node, width)
    return components.fit(render(node), width)
  end
  local function event(name)
    api.nvim_exec_autocmds(name, {})
    settle()
  end
  local function resize(source, width)
    api.nvim_win_set_width(source, width)
    event("WinResized")
  end
  local function row()
    return {
      { provider = "AAA", priority = 10, hl = "Title" },
      { provider = "BB", priority = 0, hl = "String" },
      { provider = "C", priority = 5, hl = "Comment" },
    }
  end

  test("priority removes whole units in stable order and restores original content", function()
    local node = row()
    local original = vim.deepcopy(node)
    local chunks = render(node)
    local rendered = vim.deepcopy(chunks)
    for _, case in ipairs({ { 6, "AAABBC" }, { 4, "AAAC" }, { 3, "AAA" }, { 2, "AA" }, { 6, "AAABBC" } }) do
      equal(components.fit(chunks, case[1]).text, case[2])
    end
    equal(node, original, "selection preserves component input")
    equal(chunks, rendered, "selection preserves full rendered output for expansion")
    local tied = { { provider = "AAA", priority = 0 }, "BB", "C" }
    equal(fit(tied, 5).text, "AAABB")
    equal(fit(tied, 4).text, "AAA", "do not pack a later unit into freed space")
    equal(fit(tied, 2).text, "AA")
    equal(fit({ { provider = "A", priority = -10 }, { provider = "B", priority = -20 }, "C" }, 2).text, "AC")
    equal(fit({ { provider = "A", priority = 1 }, { provider = "B", priority = 10 } }, 2).text, "AB")
  end)

  test("nested priorities split independent units and preserve inherited conditions and highlights", function()
    local node = {
      priority = 1,
      hl = "Title",
      provider = "L",
      { provider = "H", priority = 9, hl = "String" },
      "R",
    }
    equal(fit(node, 3).text, "LHR")
    equal(fit(node, 2), { text = "H", width = 1, marks = { { 0, 1, "String" } } })
    equal(fit(node, 1).text, "H")
    node.priority, node[1].priority = 10, 1
    equal(fit(node, 2), { text = "LR", width = 2, marks = { { 0, 1, "Title" }, { 1, 2, "Title" } } })
    node.condition = false
    equal(fit(node, 1).text, "", "parent condition still skips independent child")
    equal(fit({ { provider = "AA", "B" }, { provider = "H", priority = 1 } }, 3).text, "H")
    equal(fit({ provider = "AA", "B", { provider = "H", priority = 1 } }, 3).text, "AAH")
    equal(fit({ provider = "AA", "B", { provider = "H", priority = 1 } }, 4).text, "AABH")
    equal(fit({ priority = 0, { provider = "H", priority = 0 }, "R" }, 1).text, "H")
    equal(fit({ priority = 0, "L", { provider = "H", priority = 0 }, "R" }, 2).text, "LR")
  end)

  test("returned components and reused occurrences retain their own unit boundaries", function()
    local returned = { "A", { provider = "B", hl = "Title" }, { provider = "H", priority = 9 } }
    local node = {
      {
        provider = function()
          return returned
        end,
        priority = 1,
      },
      { provider = "Z", priority = 5 },
    }
    equal(fit(node, 4).text, "ABHZ")
    equal(fit(node, 3).text, "HZ", "returned unannotated chunks stay grouped")
    equal(fit(node, 1).text, "H", "returned explicit priority is independent")
    equal(
      fit(function()
        return { "AA", "B", { provider = "H", priority = 1 } }
      end, 3).text,
      "H"
    )
    local reused = { provider = "AA", priority = 0 }
    equal(fit({ reused, reused, { provider = "Z", priority = 1 } }, 4).text, "AAZ")
    equal(fit({ reused, reused, { provider = "Z", priority = 1 } }, 2).text, "Z")
    equal(returned, { "A", { provider = "B", hl = "Title" }, { provider = "H", priority = 9 } })
  end)

  test("only nonempty rendered priority output opts a row into removal", function()
    local plain = { "AAA", "BB", "C" }
    equal(fit(plain, 4).text, "AAAB")
    for _, empty in ipairs({
      { priority = 0, provider = "" },
      {
        priority = 0,
        provider = function()
          return nil
        end,
      },
      { priority = 0, condition = false, "hidden", { priority = 10, provider = "also hidden" } },
    }) do
      equal(fit({ "AAA", "BB", empty }, 4).text, "AAAB")
    end
    equal(fit({ "AAA", { priority = 0, provider = " " }, "BB" }, 4).text, "AAA ")
    equal(fit({ { priority = 0 }, "AAA", "BB" }, 4).text, "AAAB")
    equal(fit({ { priority = 0, "AAA" }, "BB" }, 4).text, "AAA")
  end)

  test("priority validation is atomic and invalid runtime components stay isolated", function()
    hud.setup({ avoid = { cursor = false }, lines = { "working" } })
    settle()
    local invalid = { false, true, "1", {}, function() end, 1.5, math.huge, -math.huge, 0 / 0 }
    for _, priority in ipairs(invalid) do
      local ok, message = pcall(hud.setup, { lines = { { provider = "invalid", priority = priority } } })
      equal(ok, false)
      assert(message:find("priority: expected a finite integer", 1, true), message)
      equal(content(), { "working" })
      local warnings = {}
      local chunks = components.render({
        "safe",
        function()
          return { priority = priority, provider = "bad", "child" }
        end,
        { priority = 1, provider = "!" },
      }, {}, function(_, warning)
        warnings[#warnings + 1] = warning
      end)
      equal(components.fit(chunks, 20).text, "safe!")
      equal(#warnings, 1)
      assert(warnings[1]:find("priority: expected a finite integer", 1, true))
    end
    for _, priority in ipairs({ -1, 0, 1, -1e100, 1e100 }) do
      equal(pcall(components.validate, { priority = priority }, "component"), true)
    end
  end)

  test("priority uses normalized display cells and keeps composing text and highlight bytes", function()
    local node = {
      {
        priority = 10,
        hl = "Title",
        provider = function()
          return { "e", { "́日X", hl = "String" } }
        end,
      },
      { priority = 0, provider = "z" },
    }
    equal(fit(node, 4).text, "é日X")
    equal(fit(node, 3), { text = "é日", width = 3, marks = { { 0, 1, "Title" }, { 1, 6, "String" } } })
    equal(fit(node, 1), { text = "é", width = 1, marks = { { 0, 1, "Title" }, { 1, 3, "String" } } })
    equal(fit({ { priority = 1, provider = "日" }, "x" }, 1).text, "")
    equal(fit({ { priority = 1, provider = "\239\128\128a" }, "x" }, 1).text, "\239\128\128")
    equal(fit({ { priority = 1, provider = "\n\255" }, "x" }, 2).text, " ?")
    equal(fit({ { priority = 0, provider = "e" }, { priority = 1, provider = "́" } }, 1).text, "é")
  end)

  test("source widths and per-row selection preserve right alignment and highlight positions", function()
    local wide = api.nvim_get_current_win()
    vim.cmd("vsplit")
    local narrow = api.nvim_get_current_win()
    api.nvim_win_set_width(narrow, 4)
    hud.setup({
      avoid = { cursor = false },
      lines = function(ctx)
        equal(api.nvim_get_current_win(), ctx.win)
        return { row(), { { provider = "ZZ", hl = "Title" }, { provider = "D", priority = 1, hl = "String" } } }
      end,
    })
    settle()
    equal(api.nvim_win_get_buf(wide), api.nvim_win_get_buf(narrow))
    equal(content(wide), { "AAABBC", "   ZZD" })
    equal(content(narrow), { "AAAC", " ZZD" })
    local marks =
      api.nvim_buf_get_extmarks(floats()[narrow].buf, api.nvim_create_namespace("hud.nvim"), 0, -1, { details = true })
    local actual = {}
    for _, mark in ipairs(marks) do
      actual[#actual + 1] = { mark[2], mark[3], mark[4].end_col, mark[4].hl_group }
    end
    equal(actual, { { 0, 0, 3, "Title" }, { 0, 3, 4, "Comment" }, { 1, 1, 3, "Title" }, { 1, 3, 4, "String" } })
    resize(narrow, 2)
    equal(content(narrow), { "AA", " D" })
    equal(content(wide), { "AAABBC", "   ZZD" })
    resize(narrow, 6)
    equal(content(narrow), { "AAABBC", "   ZZD" })
  end)

  test("gutters, right inset, global resize and tiny priority rows respect usable geometry", function()
    local source = api.nvim_get_current_win()
    vim.wo.number, vim.wo.numberwidth = true, 3
    vim.wo.signcolumn, vim.wo.foldcolumn = "yes:1", "1"
    local inset = 2
    hud.setup({ avoid = { cursor = false }, position = { col = inset }, lines = { row() } })
    settle()
    local gutter = vim.fn.getwininfo(source)[1].textoff
    vim.o.columns = gutter + inset + 4
    event("VimResized")
    local info = vim.fn.getwininfo(source)[1]
    local budget = info.width - info.textoff - inset
    equal(budget, 4)
    equal(content(source), { "AAAC" })
    equal(api.nvim_win_get_config(floats()[source].win).col, info.wincol - 1 + info.width - inset - 4)
    vim.o.columns = 100
    event("VimResized")
    equal(content(source), { "AAABBC" })
    vim.wo.number, vim.wo.signcolumn, vim.wo.foldcolumn = false, "no", "0"
    vim.cmd("vsplit")
    source = api.nvim_get_current_win()
    api.nvim_win_set_width(source, 1)
    hud.setup({
      avoid = { cursor = false },
      filter = function(ctx)
        return ctx.win == source
      end,
      lines = { { { priority = 1, provider = "日" }, "x" }, { priority = 0, provider = "a" } },
    })
    settle()
    equal(content(source), { " ", "a" }, "a zero-cell clipped row keeps its visible slot")
    hud.setup({
      avoid = { cursor = false },
      filter = function(ctx)
        return ctx.win == source
      end,
      lines = { { { priority = 1, provider = "日" }, "x" } },
    })
    settle()
    equal(floats(), {}, "an entirely zero-cell HUD stays hidden")
    resize(source, 2)
    equal(content(source), { "日" })
  end)

  test("dynamic prioritized rows compact normally and invalid factories recover per window", function()
    local other = api.nvim_get_current_win()
    vim.cmd("vsplit")
    local source = api.nvim_get_current_win()
    api.nvim_win_set_width(source, 4)
    local visible, bad = true, false
    hud.setup({
      avoid = { cursor = false },
      lines = function(ctx)
        if ctx.win == other then
          return { "safe" }
        end
        if bad then
          return { { priority = false, provider = "bad" } }
        end
        return {
          { priority = 100, condition = false, "absent" },
          row(),
          {
            condition = visible,
            { priority = 1, provider = "H" },
            "tail",
          },
        }
      end,
    })
    settle()
    equal(content(source), { "AAAC", "   H" })
    visible = false
    event("User")
    equal(content(source), { "AAAC" })
    bad = true
    event("User")
    equal(floats()[source], nil)
    equal(content(other), { "safe" })
    bad, visible = false, true
    event("User")
    equal(content(source), { "AAAC", "   H" })
    vim.cmd("split")
    source = api.nvim_get_current_win()
    api.nvim_win_set_height(source, 1)
    event("WinResized")
    equal(floats()[source], nil, "priority never drops rows to satisfy height")
  end)

  test("layout changes retain cached units and diagnostics while dropped units still update", function()
    local wide, buf = api.nvim_get_current_win(), api.nvim_get_current_buf()
    vim.cmd("vsplit")
    local source = api.nvim_get_current_win()
    local gets, calls, uncached = 0, {}, 0
    local data = { { severity = 1 }, { severity = 2 } }
    local original_get = vim.diagnostic.get
    vim.diagnostic.get = function(target)
      equal(target, buf)
      gets = gets + 1
      return data
    end
    local returned = { "K", { provider = "EEP", hl = "Title" } }
    hud.setup({
      avoid = { cursor = false },
      lines = {
        {
          {
            priority = 10,
            update = { "User" },
            provider = function(ctx)
              calls[ctx.win] = (calls[ctx.win] or 0) + 1
              return returned
            end,
          },
          { priority = 0, provider = providers.diagnostics() },
          {
            priority = -1,
            provider = function()
              uncached = uncached + 1
              return "!"
            end,
          },
        },
      },
    })
    settle()
    equal(gets, 1, "built-in diagnostics share retrieval for two source windows")
    equal(calls, { [wide] = 1, [source] = 1 })
    equal(content(source), { "KEEPE:1 W:1!" })
    local initial_uncached = uncached
    for _ = 1, 3 do
      resize(source, 4)
      equal(content(source), { "KEEP" })
      resize(source, 20)
      equal(content(source), { "KEEPE:1 W:1!" })
    end
    equal(gets, 1, "six resize events add no diagnostic retrieval")
    equal(calls, { [wide] = 1, [source] = 1 }, "layout does not invalidate declared callback dependencies")
    assert(uncached > initial_uncached, "uncached callbacks retain safe reevaluation")
    resize(source, 4)
    data = { { severity = 2 }, { severity = 2 }, { severity = 3 } }
    api.nvim_exec_autocmds("DiagnosticChanged", { buffer = buf })
    settle()
    equal(gets, 2, "a dropped diagnostic unit still updates once per buffer")
    equal(content(source), { "KEEP" })
    equal(content(wide), { "KEEPW:2 I:1!" })
    resize(source, 20)
    equal(content(source), { "KEEPW:2 I:1!" })
    equal(gets, 2, "expansion restores the new diagnostic result without retrieval")
    equal(calls, { [wide] = 1, [source] = 1 })
    equal(returned, { "K", { provider = "EEP", hl = "Title" } }, "cached return tables remain untouched")
    vim.diagnostic.get = original_get
  end)

  test("priority-only definition changes preserve callbacks and resize dependencies remain explicit", function()
    vim.cmd("vsplit")
    local source = api.nvim_get_current_win()
    api.nvim_win_set_width(source, 3)
    local priority, calls, dimensions, factories = 10, 0, 0, 0
    local provider = function()
      calls = calls + 1
      return "AAA"
    end
    local dimension_provider = function(ctx)
      dimensions = dimensions + 1
      return tostring(ctx.width)
    end
    hud.setup({
      avoid = { cursor = false },
      filter = function(ctx)
        return ctx.win == source
      end,
      lines = function()
        factories = factories + 1
        return {
          {
            { id = "stable", priority = priority, update = {}, provider = provider },
            { provider = "BB", priority = 5 },
          },
          {
            priority = 1,
            id = "dimensions",
            update = { "WinResized", "VimResized" },
            provider = dimension_provider,
          },
        }
      end,
    })
    settle()
    equal(content(source), { "AAA", "  3" })
    equal(calls, 1)
    local initial_dimensions = dimensions
    priority = 0
    event("User")
    equal(content(source), { "BB", " 3" })
    equal(calls, 1, "priority changes do not invalidate a stable callback definition")
    priority = 10
    event("User")
    equal(content(source), { "AAA", "  3" })
    equal(calls, 1)
    equal(dimensions, initial_dimensions, "User does not invalidate resize-only dependencies")
    local before_dimensions, before_factories = dimensions, factories
    resize(source, 6)
    equal(content(source), { "AAABB", "    6" })
    equal(calls, 1)
    assert(dimensions > before_dimensions and factories > before_factories)
  end)
end
