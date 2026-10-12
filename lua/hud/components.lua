local M = {}
local cache = require("hud.cache")

local function group(value)
  return type(value) == "string" and value:match("^[%w_@.%-]+$") ~= nil
end

M.group = group

local function array_size(value, path, fields)
  local count = 0
  for key in pairs(value) do
    if type(key) == "number" and key >= 1 and key % 1 == 0 then
      count = count + 1
    elseif not fields or not fields[key] then
      error(path .. ": unexpected key " .. tostring(key), 0)
    end
  end
  for index = 1, count do
    if value[index] == nil then
      error(path .. ": expected a dense array", 0)
    end
  end
  return count
end

M.array_size = array_size

local function validate_policy(node, path)
  cache.validate(node.update, node.scope, node.id, path)
  local priority = node.priority
  if priority ~= nil and (type(priority) ~= "number" or priority % 1 ~= 0) then
    error(path .. ".priority: expected a finite integer", 0)
  end
end

function M.validate(node, path, seen, depth)
  if type(node) == "string" or type(node) == "function" then
    return
  end
  if type(node) ~= "table" then
    error(path .. ": expected a string, function, or component table", 0)
  end
  seen, depth = seen or {}, depth or 0
  if seen[node] or depth >= 32 then
    error(path .. ": cyclic or excessively nested component", 0)
  end
  seen[node] = true
  local count = array_size(node, path, {
    provider = true,
    condition = true,
    hl = true,
    update = true,
    scope = true,
    id = true,
    priority = true,
  })
  validate_policy(node, path)
  if node.provider ~= nil and type(node.provider) ~= "string" and type(node.provider) ~= "function" then
    error(path .. ".provider: expected a string or function", 0)
  end
  if node.condition ~= nil and type(node.condition) ~= "boolean" and type(node.condition) ~= "function" then
    error(path .. ".condition: expected a boolean or function", 0)
  end
  if node.hl ~= nil and type(node.hl) ~= "function" and not group(node.hl) then
    error(path .. ".hl: expected a highlight group or function", 0)
  end
  for index = 1, count do
    M.validate(node[index], path .. "[" .. index .. "]", seen, depth + 1)
  end
  seen[node] = nil
end

-- Replace controls and malformed UTF-8; keep every valid printable codepoint intact.
local function normalize(text)
  local out, index = {}, 1
  while index <= #text do
    local first = text:byte(index)
    local size = first < 128 and 1
      or first >= 194 and first <= 223 and 2
      or first >= 224 and first <= 239 and 3
      or first >= 240 and first <= 244 and 4
      or 0
    local valid = size > 0 and index + size - 1 <= #text
    for offset = 1, size - 1 do
      local byte = text:byte(index + offset) or 0
      valid = valid and byte >= 128 and byte <= 191
    end
    local second = text:byte(index + 1) or 0
    valid = valid
      and not (
        first == 224 and second < 160
        or first == 237 and second > 159
        or first == 240 and second < 144
        or first == 244 and second > 143
      )
    if not valid then
      out[#out + 1], index = "?", index + 1
    else
      local control = first < 32 or first == 127 or first == 194 and second <= 159
      out[#out + 1], index = control and " " or text:sub(index, index + size - 1), index + size
    end
  end
  return table.concat(out)
end

function M.render(node, ctx, warn, evaluator)
  local chunks, seen = {}, {}
  local order = 0
  local function new_unit(priority)
    return { priority = priority or 0, explicit = priority ~= nil }
  end
  local function call(fn, role, component)
    local ok, value
    if evaluator then
      ok, value = evaluator:call(fn, ctx, role, component)
    else
      ok, value = pcall(fn, ctx)
    end
    if not ok then
      warn(role .. tostring(fn), role .. " failed: " .. tostring(value))
    end
    return ok, value
  end
  local function visit(value, inherited, depth, origin, unit, root)
    if value == nil then
      return
    end
    if depth > 32 then
      warn("depth" .. tostring(origin), "component nesting exceeds 32 levels")
      return
    end
    if type(value) == "string" then
      local text = normalize(value)
      if text ~= "" then
        unit = unit or new_unit()
        if not unit.order then
          order = order + 1
          unit.order = order
        end
        chunks[#chunks + 1] = { text = text, hl = inherited, unit = unit }
        chunks.prioritized = chunks.prioritized or unit.explicit
      end
    elseif type(value) == "function" then
      local ok, result = call(value, "provider")
      if ok then
        visit(result, inherited, depth + 1, value, unit or new_unit())
      end
    elseif type(value) == "table" then
      local valid, message = pcall(validate_policy, value, "hud.component")
      if not valid then
        warn("policy" .. tostring(origin), tostring(message))
        return
      end
      if seen[value] then
        warn("cycle" .. tostring(origin), "provider returned a cyclic component")
        return
      end
      seen[value] = true
      local allowed, condition = true, value.condition
      if type(condition) == "function" then
        allowed, condition = call(condition, "condition", value)
        if not allowed or condition == nil then
          condition = false
        end
      end
      if condition ~= nil and type(condition) ~= "boolean" then
        warn("condition-type" .. tostring(origin), "condition must return a boolean or nil")
        allowed = false
      end
      if allowed and condition ~= false then
        if value.priority ~= nil then
          unit = new_unit(value.priority)
        elseif not root then
          unit = unit or new_unit()
        end
        local hl = value.hl
        if type(hl) == "function" then
          local ok, result = call(hl, "highlight", value)
          hl = nil
          if ok then
            hl = result
          end
        end
        if hl ~= nil and not group(hl) then
          warn("highlight-type" .. tostring(origin), "highlight must return a group name or nil")
          hl = nil
        end
        hl = hl or inherited
        if type(value.provider) == "function" then
          local ok, result = call(value.provider, "provider", value)
          if ok then
            visit(result, hl, depth + 1, value.provider, unit or new_unit())
          end
        else
          visit(value.provider, hl, depth + 1, origin, unit or new_unit())
        end
        for _, child in ipairs(value) do
          visit(child, hl, depth + 1, origin, unit or new_unit())
        end
      end
      seen[value] = nil
    else
      warn("type" .. tostring(origin), "provider returned an invalid component: " .. type(value))
    end
  end
  visit(node, nil, 0, node, nil, true)
  return chunks
end

-- Units are per rendered occurrence; selecting them never changes cached output.
local function select_chunks(chunks, limit)
  if not chunks.prioritized then
    return chunks
  end
  local units, seen, removed = {}, {}, {}
  for _, chunk in ipairs(chunks) do
    if not seen[chunk.unit] then
      seen[chunk.unit] = true
      units[#units + 1] = chunk.unit
    end
  end
  table.sort(units, function(a, b)
    return a.priority < b.priority or a.priority == b.priority and a.order > b.order
  end)
  local selected = chunks
  for index = 1, #units - 1 do
    local parts = {}
    for _, chunk in ipairs(selected) do
      parts[#parts + 1] = chunk.text
    end
    if vim.fn.strdisplaywidth(table.concat(parts)) <= limit then
      break
    end
    removed[units[index]] = true
    selected = {}
    for _, chunk in ipairs(chunks) do
      if not removed[chunk.unit] then
        selected[#selected + 1] = chunk
      end
    end
  end
  return selected
end

-- Clip the complete row so composing characters spanning chunks stay together.
function M.fit(chunks, limit)
  local parts, marks, offset = {}, {}, 0
  for _, chunk in ipairs(select_chunks(chunks, limit)) do
    parts[#parts + 1] = chunk.text
    if chunk.hl then
      marks[#marks + 1] = { offset, offset + #chunk.text, chunk.hl }
    end
    offset = offset + #chunk.text
  end
  local text = table.concat(parts)
  if vim.fn.strdisplaywidth(text) > limit then
    local prefix = ""
    for index = 0, vim.fn.strchars(text, true) - 1 do
      local next_prefix = prefix .. vim.fn.strcharpart(text, index, 1, true)
      if vim.fn.strdisplaywidth(next_prefix) > limit then
        break
      end
      prefix = next_prefix
    end
    text = prefix
  end
  local clipped = {}
  for _, mark in ipairs(marks) do
    if mark[1] < #text then
      clipped[#clipped + 1] = { mark[1], math.min(mark[2], #text), mark[3] }
    end
  end
  return { text = text, width = vim.fn.strdisplaywidth(text), marks = clipped }
end

return M
