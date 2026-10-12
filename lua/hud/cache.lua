local M = {}

-- Local dependencies use the event's source window/buffer; other events are global.
local window_events = {
  CursorMoved = true,
  CursorMovedI = true,
  WinEnter = true,
  WinLeave = true,
  ModeChanged = true,
  InsertEnter = true,
  InsertLeave = true,
  WinScrolled = true,
}
local buffer_events = {
  DiagnosticChanged = true,
  TextChanged = true,
  TextChangedI = true,
  TextChangedP = true,
  BufModifiedSet = true,
  BufWritePost = true,
  FileType = true,
}
M.events = {
  "CursorMoved",
  "CursorMovedI",
  "TextChanged",
  "TextChangedI",
  "TextChangedP",
  "DiagnosticChanged",
  "BufEnter",
  "BufWinEnter",
  "BufWinLeave",
  "BufDelete",
  "BufWipeout",
  "BufModifiedSet",
  "BufWritePost",
  "FileType",
  "WinEnter",
  "WinLeave",
  "WinNew",
  "WinClosed",
  "WinResized",
  "WinScrolled",
  "TabEnter",
  "TabLeave",
  "TabClosed",
  "VimResized",
  "ModeChanged",
  "OptionSet",
  "InsertEnter",
  "InsertLeave",
  "FocusGained",
  "FocusLost",
  "User",
  "ColorScheme",
}
local supported = {}
for _, event in ipairs(M.events) do
  supported[event] = true
end
local policies = setmetatable({}, { __mode = "k" })

-- Only built-ins proven independent of window context may share results by buffer.
function M.builtin(fn, update, by_buffer)
  policies[fn] = { update = update, by_buffer = by_buffer }
  return fn
end

function M.validate(update, scope, id, path)
  if id ~= nil and (type(id) ~= "string" or id == "") then
    error(path .. ".id: expected a nonempty string", 0)
  end
  if scope ~= nil and scope ~= "local" and scope ~= "global" then
    error(path .. ".scope: expected local or global", 0)
  end
  if scope ~= nil and update == nil then
    error(path .. ".scope: requires an update array", 0)
  end
  if update == nil then
    return
  end
  if type(update) ~= "table" then
    error(path .. ".update: expected an event array", 0)
  end
  local count = 0
  for key, event in pairs(update) do
    if type(key) ~= "number" or key < 1 or key % 1 ~= 0 or not supported[event] then
      error(path .. ".update: expected supported event names in a dense array", 0)
    end
    count = count + 1
  end
  for index = 1, count do
    if update[index] == nil then
      error(path .. ".update: expected a dense array", 0)
    end
  end
end

local Cache = {}
Cache.__index = Cache

function M.new()
  local self = setmetatable({}, Cache)
  self:clear()
  return self
end

function Cache:clear()
  self.serial, self.total, self.global, self.windows, self.buffers = 0, {}, {}, {}, {}
  self.window_events, self.buffer_events = {}, {}
end

function Cache:forget_buffer(buf)
  self.buffers[buf], self.buffer_events[buf] = nil, nil
  for win, state in pairs(self.windows) do
    if state.buf == buf then
      self.windows[win] = nil
    end
  end
end

function Cache:record(event, buf, win)
  self.serial = self.serial + 1
  self.total[event] = self.serial
  local target, key
  if buffer_events[event] then
    target, key = self.buffer_events, buf
  elseif window_events[event] then
    target, key = self.window_events, win
  end
  if target and key and key > 0 then
    target[key] = target[key] or {}
    target[key][event] = self.serial
  else
    self.global[event] = self.serial
  end
  if event == "BufWipeout" or event == "BufDelete" then
    self:forget_buffer(buf)
  elseif event == "WinClosed" then
    self.windows[win], self.window_events[win] = nil, nil
  end
end

function Cache:begin(ctx)
  local state = self.windows[ctx.win]
  if not state or state.buf ~= ctx.buf then
    state = { buf = ctx.buf, slots = {}, ids = {} }
    self.windows[ctx.win] = state
  end
  state.seen, state.seen_ids = {}, {}
end

function Cache:finish(ctx)
  local state = self.windows[ctx.win]
  if not state then
    return
  end
  for key in pairs(state.slots) do
    if not state.seen[key] then
      state.slots[key] = nil
    end
  end
  for key in pairs(state.ids) do
    if not state.seen_ids[key] then
      state.ids[key] = nil
    end
  end
end

function Cache:prune(live, buffers)
  for win in pairs(self.windows) do
    if not live[win] then
      self.windows[win], self.window_events[win] = nil, nil
    end
  end
  for buf in pairs(self.buffers) do
    if not buffers[buf] then
      self.buffers[buf] = nil
    end
  end
end

function Cache:stamp(rule, ctx)
  local stamp = {}
  for _, event in ipairs(rule.update) do
    if rule.scope == "global" then
      stamp[#stamp + 1] = self.total[event] or 0
    else
      stamp[#stamp + 1] = math.max(
        self.global[event] or 0,
        (self.buffer_events[ctx.buf] or {})[event] or 0,
        not rule.by_buffer and (self.window_events[ctx.win] or {})[event] or 0
      )
    end
  end
  return stamp
end

-- Cache each callback, not a rendered subtree: child dependencies stay independent.
function Cache:call(fn, ctx, role, node)
  local rule = node and node.update ~= nil and node or policies[fn]
  if not rule then
    return pcall(fn, ctx)
  end
  local slots, seen, key, definition
  if rule.by_buffer then
    self.buffers[ctx.buf] = self.buffers[ctx.buf] or {}
    slots, key = self.buffers[ctx.buf], fn
  else
    local state = self.windows[ctx.win]
    if node and node.update ~= nil then
      slots, seen, key = state.slots, state.seen, node
      if node.id then
        slots, seen, key = state.ids, state.seen_ids, node.id
      end
      definition = { node.provider, node.condition, node.hl, node.scope, node.update }
    else
      slots, seen, key = state.slots, state.seen, fn
    end
    seen[key] = true
  end
  local slot = slots[key]
  if not slot or not vim.deep_equal(slot.definition, definition) then
    slot = { definition = vim.deepcopy(definition) }
    slots[key] = slot
  end
  local stamp = self:stamp(rule, ctx)
  local cell = slot[role]
  if cell and cell.fn == fn and vim.deep_equal(cell.stamp, stamp) then
    return true, cell.value
  end
  local ok, value = pcall(fn, ctx)
  if ok then
    slot[role] = { fn = fn, stamp = stamp, value = value }
  else
    slot[role] = nil
  end
  return ok, value
end

return M
