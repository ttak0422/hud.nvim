local api = vim.api
local components = require("hud.components")
local providers = require("hud.providers")
local cache = require("hud.cache")
local previous = rawget(_G, "__hud_nvim")
if previous then
  previous.disable()
end

local M = {}
-- Survives clearing package.loaded so old scheduled work can be invalidated.
_G.__hud_nvim = M

local ns = api.nvim_create_namespace("hud.nvim")
local entries, warned = {}, {}
local enabled, hidden, running, pending = false, false, false, false
local generation, augroup = 0, nil
local config
local evaluator = cache.new()
local line_component

local function defaults()
  return {
    lines = { providers.diagnostics(), providers.cursor() },
    position = { row = 0, col = 0 },
    zindex = 30,
    hl = "HudNormal",
    inactive_hl = "HudInactive",
    avoid = { cursor = false, visual = false },
  }
end

local function integer(value, minimum)
  return type(value) == "number" and value % 1 == 0 and value >= minimum and value <= 2147483647
end

local function validate_lines(lines, path)
  if type(lines) ~= "table" then
    error(path .. ": expected an array", 0)
  end
  local size = components.array_size(lines, path)
  for index = 1, size do
    components.validate(lines[index], path .. "[" .. index .. "]")
  end
  return lines
end

local function validate(opts)
  if type(opts) ~= "table" then
    error("hud.setup: expected an options table", 0)
  end
  local result = defaults()
  for key, value in pairs(opts) do
    if key == "position" or key == "avoid" then
      if type(value) ~= "table" then
        error("hud.setup: " .. key .. " must be a table", 0)
      end
      for nested, item in pairs(value) do
        if result[key][nested] == nil then
          error("hud.setup: unknown " .. key .. "." .. tostring(nested), 0)
        end
        result[key][nested] = item
      end
    elseif result[key] ~= nil or key == "filter" or key == "lines_update" or key == "lines_scope" then
      result[key] = value
    else
      error("hud.setup: unknown option " .. tostring(key), 0)
    end
  end
  if type(result.lines) ~= "function" then
    validate_lines(result.lines, "hud.setup.lines")
    if result.lines_update ~= nil or result.lines_scope ~= nil then
      error("hud.setup: lines_update/lines_scope require a lines function", 0)
    end
  end
  cache.validate(result.lines_update, result.lines_scope, nil, "hud.setup.lines")
  if not integer(result.position.row, 0) or not integer(result.position.col, 0) then
    error("hud.setup: position row/col must be nonnegative integers", 0)
  end
  if not integer(result.zindex, 1) then
    error("hud.setup: zindex must be a positive integer", 0)
  end
  if not components.group(result.hl) or not components.group(result.inactive_hl) then
    error("hud.setup: hl and inactive_hl must be highlight group names", 0)
  end
  if type(result.avoid.cursor) ~= "boolean" or type(result.avoid.visual) ~= "boolean" then
    error("hud.setup: avoid.cursor and avoid.visual must be booleans", 0)
  end
  if result.filter ~= nil and type(result.filter) ~= "function" then
    error("hud.setup: filter must be a function", 0)
  end
  return vim.deepcopy(result)
end

local function warn(key, message)
  if not warned[key] then
    warned[key] = true
    pcall(vim.notify, "hud.nvim: " .. message, vim.log.levels.WARN)
  end
end

-- Resolve structure without copying or changing component identities.
local function resolve_lines(ctx)
  if type(config.lines) ~= "function" then
    return config.lines
  end
  local ok, result = evaluator:call(config.lines, ctx, "lines", line_component)
  if ok and result == nil then
    return {}
  end
  if ok then
    ok, result = pcall(validate_lines, result, "hud.lines")
  end
  if not ok then
    warn("lines" .. tostring(config.lines), "lines failed: " .. tostring(result))
    return {}
  end
  return result
end

local function highlights()
  api.nvim_set_hl(0, "HudNormal", { default = true, link = "NormalFloat" })
  api.nvim_set_hl(0, "HudInactive", { default = true, link = "Comment" })
end

local function close(entry)
  if entry.win and api.nvim_win_is_valid(entry.win) then
    pcall(api.nvim_win_close, entry.win, true)
  end
  entry.win, entry.geometry, entry.base = nil, nil, nil
end

local function destroy(source)
  local entry = entries[source]
  if entry then
    close(entry)
    if entry.buf and api.nvim_buf_is_valid(entry.buf) then
      pcall(api.nvim_buf_delete, entry.buf, { force = true })
    end
    entries[source] = nil
  end
end

local function scratch(entry, source)
  if entry.buf and api.nvim_buf_is_valid(entry.buf) then
    return
  end
  close(entry)
  entry.buf = api.nvim_create_buf(false, true)
  entry.lines, entry.marks = nil, nil
  vim.b[entry.buf].hud_source_win = source
  for name, value in pairs({ buftype = "nofile", bufhidden = "hide", swapfile = false, undolevels = -1 }) do
    api.nvim_set_option_value(name, value, { buf = entry.buf })
  end
end

local function paint(source, rows, width, info, base)
  local entry = entries[source] or {}
  entries[source] = entry
  scratch(entry, source)
  local lines, marks = {}, {}
  for row, line in ipairs(rows) do
    local padding = width - line.width
    lines[row] = string.rep(" ", padding) .. line.text
    for _, mark in ipairs(line.marks) do
      marks[#marks + 1] = { row - 1, padding + mark[1], padding + mark[2], mark[3] }
    end
  end
  local changed = not vim.deep_equal(entry.lines, lines)
  if changed then
    api.nvim_set_option_value("modifiable", true, { buf = entry.buf })
    api.nvim_buf_set_lines(entry.buf, 0, -1, false, lines)
    api.nvim_set_option_value("modifiable", false, { buf = entry.buf })
    entry.lines = lines
  end
  if changed or not vim.deep_equal(entry.marks, marks) then
    api.nvim_buf_clear_namespace(entry.buf, ns, 0, -1)
    for _, mark in ipairs(marks) do
      api.nvim_buf_set_extmark(entry.buf, ns, mark[1], mark[2], { end_col = mark[3], hl_group = mark[4] })
    end
    entry.marks = marks
  end
  local right = info.width - (vim.wo[source].rightleft and info.textoff or 0)
  local geometry = {
    relative = "editor",
    row = info.winrow - 1 + (info.winbar or 0) + config.position.row,
    col = info.wincol - 1 + right - config.position.col - width,
    width = width,
    height = #rows,
    focusable = false,
    style = "minimal",
    border = "none",
    zindex = config.zindex,
  }
  if not entry.win or not api.nvim_win_is_valid(entry.win) then
    entry.win = api.nvim_open_win(entry.buf, false, vim.tbl_extend("force", geometry, { noautocmd = true }))
    for name, value in pairs({
      wrap = false,
      winbar = "",
      winblend = 0,
      rightleft = false,
      foldenable = false,
      conceallevel = 0,
      scrolloff = 0,
      sidescrolloff = 0,
    }) do
      api.nvim_set_option_value(name, value, { win = entry.win })
    end
    entry.geometry, entry.base = geometry, nil
  elseif not vim.deep_equal(entry.geometry, geometry) then
    api.nvim_win_set_config(entry.win, geometry)
    entry.geometry, entry.base = geometry, nil
  end
  if entry.base ~= base then
    api.nvim_set_option_value(
      "winhighlight",
      "Normal:" .. base .. ",NormalNC:" .. base .. ",EndOfBuffer:" .. base,
      { win = entry.win }
    )
    entry.base = base
  end
end

local visual_modes = { v = true, V = true, ["\22"] = true, s = true, S = true, ["\19"] = true }

local function render(source, focused, mode)
  local info = vim.fn.getwininfo(source)[1]
  if not info or api.nvim_win_get_config(source).relative ~= "" then
    return false
  end
  local buf = api.nvim_win_get_buf(source)
  if vim.b[buf].hud_source_win then
    return false
  end
  return api.nvim_win_call(source, function()
    local cursor = api.nvim_win_get_cursor(source)
    local ctx = {
      win = source,
      buf = buf,
      focused = source == focused,
      lnum = cursor[1],
      col = vim.fn.virtcol("."),
      byte_col = cursor[2],
      width = info.width - info.textoff,
      height = info.height,
    }
    local allowed = vim.bo[buf].buftype == "" and not vim.wo[source].previewwindow
    if config.filter then
      local ok, result = pcall(config.filter, ctx)
      if not ok then
        warn("filter" .. tostring(config.filter), "filter failed: " .. tostring(result))
        return false
      end
      if type(result) ~= "boolean" and result ~= nil then
        warn("filter-type", "filter must return a boolean or nil")
        return false
      end
      allowed = not not result
    end
    if not allowed then
      return false
    end
    local limit = ctx.width - config.position.col
    local concealed = hidden
      or limit < 1
      or config.position.row >= ctx.height
      or (ctx.focused and config.avoid.visual and visual_modes[mode:sub(1, 1)])
    if concealed then
      if entries[source] then
        close(entries[source])
      end
      return true
    end
    evaluator:begin(ctx)
    local rows, width = {}, 0
    for _, node in ipairs(resolve_lines(ctx)) do
      local chunks = components.render(node, ctx, warn, evaluator)
      -- Compact absent rows before layout, never mutate the configured nodes.
      -- A row clipped to zero cells still occupies its original visible slot.
      if #chunks > 0 then
        -- Reserve one leading cell before fitting and right-aligning every row.
        local line = components.fit(chunks, limit - 1)
        rows[#rows + 1], width = line, math.max(width, line.width + 1)
      end
    end
    evaluator:finish(ctx)
    local count = #rows
    concealed = config.position.row + count > ctx.height
    if ctx.focused and config.avoid.cursor then
      local row = vim.fn.winline() - 1
      concealed = concealed or row < 0 or (row >= config.position.row and row < config.position.row + count)
    end
    if count == 0 or width == 0 or concealed then
      if entries[source] then
        close(entries[source])
      end
    else
      paint(source, rows, width, info, ctx.focused and config.hl or config.inactive_hl)
    end
    return true
  end)
end

local function update()
  if running or not enabled then
    return
  end
  running = true
  local live, live_buffers = {}, {}
  local focused, mode = api.nvim_get_current_win(), api.nvim_get_mode().mode
  for _, source in ipairs(api.nvim_tabpage_list_wins(0)) do
    local ok, keep = pcall(render, source, focused, mode)
    if ok and keep then
      live[source] = true
      live_buffers[api.nvim_win_get_buf(source)] = true
    elseif not ok then
      warn("render" .. source, "window rendering failed: " .. tostring(keep))
    end
  end
  for source in pairs(entries) do
    if not live[source] then
      destroy(source)
    end
  end
  evaluator:prune(live, live_buffers)
  running = false
end

local function schedule()
  if not enabled or pending or running then
    return
  end
  pending = true
  local scheduled_generation = generation
  vim.schedule(function()
    if scheduled_generation ~= generation or not enabled then
      return
    end
    pending = false
    update()
  end)
end

function M.refresh()
  if enabled and not running then
    evaluator:clear()
    schedule()
  end
end

function M.disable()
  enabled, pending = false, false
  generation = generation + 1
  if augroup then
    pcall(api.nvim_del_augroup_by_id, augroup)
    augroup = nil
  end
  for source in pairs(entries) do
    destroy(source)
  end
  evaluator:clear()
end

local function on_event(event)
  if running or (event.event:match("^TextChanged") and vim.b[event.buf].hud_source_win) then
    return
  end
  if event.event == "ColorScheme" then
    evaluator:clear()
    highlights()
  else
    local win = api.nvim_get_current_win()
    if event.event == "WinClosed" or event.event == "WinScrolled" then
      win = tonumber(event.match) or win
    end
    if event.event == "WinScrolled" then
      for key in pairs(vim.v.event) do
        local scrolled = tonumber(key)
        if scrolled and api.nvim_win_is_valid(scrolled) then
          evaluator:record(event.event, api.nvim_win_get_buf(scrolled), scrolled)
        end
      end
    end
    evaluator:record(event.event, event.buf, win)
  end
  schedule()
end

function M.enable()
  if enabled then
    return
  end
  config = config or defaults()
  line_component = { provider = config.lines, update = config.lines_update, scope = config.lines_scope }
  evaluator:clear()
  enabled = true
  highlights()
  augroup = api.nvim_create_augroup("HudNvim", { clear = true })
  api.nvim_create_autocmd(cache.events, { group = augroup, callback = on_event })
  api.nvim_create_autocmd("VimLeavePre", { group = augroup, callback = M.disable })
  schedule()
end

function M.hide()
  hidden = true
  schedule()
end

function M.show()
  hidden = false
  schedule()
end

function M.setup(opts)
  if vim.fn.has("nvim-0.10") == 0 then
    error("hud.nvim requires Neovim >= 0.10", 0)
  end
  local checked = validate(opts == nil and {} or opts)
  M.disable()
  config, warned, hidden = checked, {}, false
  M.enable()
end

return M
