return function(t)
  local api, hud = vim.api, require("hud")
  local test, equal, settle, content, floats = t.test, t.equal, t.settle, t.content, t.floats

  test("left padding survives Unicode clipping, priorities, row compaction and focus changes", function()
    local other = api.nvim_get_current_win()
    vim.cmd("vsplit")
    local source = api.nvim_get_current_win()
    vim.wo.signcolumn, vim.wo.foldcolumn = "yes:1", "1"
    local filename = "日本語é" .. string.rep("長", 50) .. ".lua"
    local active = {
      {
        { provider = filename, hl = "Title", priority = 20 },
        { provider = " optional/path", hl = "String", priority = 0 },
      },
      "",
      function()
        return nil
      end,
      { condition = false, provider = "absent" },
      " ",
      "x",
    }
    hud.setup({
      position = { col = 1 },
      lines_update = { "WinEnter", "WinLeave" },
      lines = function(ctx)
        return ctx.focused and active or { "inactive" }
      end,
    })
    local ns = api.nvim_create_namespace("hud.nvim")
    for _, case in ipairs({
      { 0, "" },
      { 1, "" },
      { 2, "日" },
      { 3, "日" },
      { 4, "日本" },
      { 6, "日本語" },
      { 7, "日本語é" },
      { 8, "日本語é" },
      { 9, "日本語é長" },
    }) do
      local gutter = vim.fn.getwininfo(source)[1].textoff
      api.nvim_win_set_width(source, gutter + 2 + case[1])
      api.nvim_exec_autocmds("WinResized", {})
      settle()
      local lines, float = content(source), floats()[source]
      local info, cfg = vim.fn.getwininfo(source)[1], api.nvim_win_get_config(float.win)
      equal(#lines, 3, "padding must not resurrect empty rows or remove explicit blank rows")
      equal(vim.trim(lines[1]), case[2], "reserve padding before priority selection and Unicode clipping")
      equal(cfg.col + cfg.width, info.wincol - 1 + info.width - 1, "right inset stays clear")
      assert(cfg.width <= info.width - info.textoff - 1, "HUD must fit between gutters and the right inset")
      for _, line in ipairs(lines) do
        equal(line:sub(1, 1), " ", "every actual row starts with a padding cell")
        equal(vim.fn.strdisplaywidth(line), cfg.width)
      end
      local marks = api.nvim_buf_get_extmarks(float.buf, ns, 0, -1, { details = true })
      equal(#marks, case[2] == "" and 0 or 1, "only visible filename bytes retain highlighting")
      if case[2] ~= "" then
        local mark = marks[1]
        equal(mark[4].hl_group, "Title")
        equal(lines[1]:sub(mark[3] + 1, mark[4].end_col), case[2])
        assert(mark[3] >= 1, "padding must stay outside the filename highlight")
      end
      api.nvim_set_current_win(other)
      settle()
      equal(#content(source), 1, "inactive rows still replace active rows")
      equal(content(source)[1]:sub(1, 1), " ")
      api.nvim_set_current_win(source)
      settle()
      equal(#content(source), 3, "active rows return after focus changes")
    end
    local info = vim.fn.getwininfo(source)[1]
    api.nvim_win_set_width(source, info.textoff + 1)
    api.nvim_exec_autocmds("WinResized", {})
    settle()
    equal(floats()[source], nil, "hide when only the right inset fits")
  end)
end
