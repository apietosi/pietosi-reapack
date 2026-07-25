-- @description PGlitchLib - Shared helpers for the PietosiGlitch tools
-- @version 1.0.0
-- @author pie
-- @provides [nomain] .
-- PGlitchLib - shared helpers for the PietosiGlitch item gadgets
local r = reaper
local L = {}

function L.wheelDir()
  local _, _, _, _, _, _, val = r.get_action_context()
  return (val or 0) < 0 and -1 or 1
end

-- contiguous runs of selected items, grouped per track (gap < 2 ms)
function L.runs()
  local n = r.CountSelectedMediaItems(0)
  local bytr, order, runs = {}, {}, {}
  for i = 0, n - 1 do
    local it = r.GetSelectedMediaItem(0, i)
    local tr = r.GetMediaItemTrack(it)
    local key = tostring(tr)
    if not bytr[key] then
      bytr[key] = { tr = tr, items = {} }
      order[#order + 1] = key
    end
    local t = bytr[key].items
    t[#t + 1] = it
  end
  for _, key in ipairs(order) do
    local g = bytr[key]
    table.sort(g.items, function(a, b)
      return r.GetMediaItemInfo_Value(a, 'D_POSITION') < r.GetMediaItemInfo_Value(b, 'D_POSITION')
    end)
    local cur
    for _, it in ipairs(g.items) do
      local pos = r.GetMediaItemInfo_Value(it, 'D_POSITION')
      local fin = pos + r.GetMediaItemInfo_Value(it, 'D_LENGTH')
      if cur and pos - cur.fin < 0.002 then
        cur.items[#cur.items + 1] = it
        if fin > cur.fin then cur.fin = fin end
      else
        cur = { tr = g.tr, items = { it }, start = pos, fin = fin }
        runs[#runs + 1] = cur
      end
    end
  end
  return runs
end

-- collapse a run to its first piece spanning the whole run (valid for
-- contiguous same-take slices, which is what the gadgets produce)
function L.heal(run)
  local first = run.items[1]
  for i = #run.items, 2, -1 do
    r.DeleteTrackMediaItem(run.tr, run.items[i])
  end
  r.SetMediaItemInfo_Value(first, 'D_LENGTH', run.fin - run.start)
  run.items = { first }
  return first
end

function L.splitEqual(item, start, fin, N, sel)
  local pieces = { item }
  local cur = item
  for k = 1, N - 1 do
    local right = r.SplitMediaItem(cur, start + (fin - start) * k / N)
    if right then
      pieces[#pieces + 1] = right
      cur = right
    end
  end
  if sel then
    for _, p in ipairs(pieces) do r.SetMediaItemSelected(p, true) end
  end
  return pieces
end

function L.splitAtTimes(item, times, sel)
  local pieces = { item }
  local cur = item
  for _, t in ipairs(times) do
    local pos = r.GetMediaItemInfo_Value(cur, 'D_POSITION')
    local len = r.GetMediaItemInfo_Value(cur, 'D_LENGTH')
    if t > pos + 0.001 and t < pos + len - 0.001 then
      local right = r.SplitMediaItem(cur, t)
      if right then
        pieces[#pieces + 1] = right
        cur = right
      end
    end
  end
  if sel then
    for _, p in ipairs(pieces) do r.SetMediaItemSelected(p, true) end
  end
  return pieces
end

-- lock every piece to play the same audio as the first (stutter repeats)
function L.offsetLock(pieces)
  if #pieces < 2 then return end
  local tk0 = r.GetActiveTake(pieces[1])
  if not tk0 then return end
  local off0 = r.GetMediaItemTakeInfo_Value(tk0, 'D_STARTOFFS')
  for i = 2, #pieces do
    local tk = r.GetActiveTake(pieces[i])
    if tk then r.SetMediaItemTakeInfo_Value(tk, 'D_STARTOFFS', off0) end
  end
end

-- span signature for wheel state (30 s memory)
function L.sig(run)
  local _, guid = r.GetSetMediaTrackInfo_String(run.tr, 'GUID', '', false)
  return ('%s_%.3f_%.3f'):format(guid, run.start, run.fin)
end

function L.state(key, def)
  local v = r.GetExtState('PGlitch', key)
  local num, t = v:match('^([%-%d%.]+)@([%d%.]+)$')
  if num and os.time() - tonumber(t) < 30 then return tonumber(num) end
  return def
end

function L.setState(key, num)
  r.SetExtState('PGlitch', key, ('%s@%d'):format(tostring(num), os.time()), false)
end

-- seconds of one quarter note / one grid division at time t
function L.beatLen(t)
  local qn = r.TimeMap2_timeToQN(0, t)
  return r.TimeMap2_QNToTime(0, qn + 1) - t
end

function L.gridLen(t)
  local _, div = r.GetSetProjectGrid(0, false)
  if div <= 0 then div = 0.25 end
  local qn = r.TimeMap2_timeToQN(0, t)
  return r.TimeMap2_QNToTime(0, qn + div * 4) - t
end

-- chop a single-item run on the project grid, so slice gadgets work on an
-- unchopped item and the grid selection shapes the result (finer grid =
-- smaller pieces). Runs that are already sliced pass through untouched.
function L.gridChopRun(run)
  if #run.items > 1 then return run.items end
  local times, p = {}, run.start
  for _ = 1, 512 do
    p = p + L.gridLen(p)
    if p >= run.fin - 0.002 then break end
    times[#times + 1] = p
  end
  if #times > 0 then
    run.items = L.splitAtTimes(run.items[1], times, true)
  end
  return run.items
end

-- resolve a native action by name (cached in ext state, validated via SWS)
function L.namedCommand(label, patterns)
  local cached = tonumber(r.GetExtState('PGlitch', 'cmd_' .. label))
  if cached and r.APIExists('CF_GetCommandText') then
    local nm = (r.CF_GetCommandText(0, cached) or ''):lower()
    for _, p in ipairs(patterns) do
      if nm:find(p, 1, true) then return cached end
    end
  end
  if not r.APIExists('CF_EnumerateActions') then return nil end
  for i = 0, 200000 do
    local cmd, name = r.CF_EnumerateActions(0, i, '')
    if not cmd or cmd <= 0 then break end
    local l = (name or ''):lower()
    for _, p in ipairs(patterns) do
      if l:find(p, 1, true) then
        r.SetExtState('PGlitch', 'cmd_' .. label, tostring(cmd), true)
        return cmd
      end
    end
  end
  return nil
end

-- run an item action on specific items only, preserving the selection
function L.applyActionToItems(cmd, items)
  if not cmd then return end
  local sel = {}
  for i = 0, r.CountSelectedMediaItems(0) - 1 do
    sel[#sel + 1] = r.GetSelectedMediaItem(0, i)
  end
  r.SelectAllMediaItems(0, false)
  for _, it in ipairs(items) do r.SetMediaItemSelected(it, true) end
  r.Main_OnCommand(cmd, 0)
  r.SelectAllMediaItems(0, false)
  for _, it in ipairs(sel) do
    if r.ValidatePtr2(0, it, 'MediaItem*') then r.SetMediaItemSelected(it, true) end
  end
end

function L.undo(name, fn)
  r.Undo_BeginBlock2(0)
  r.PreventUIRefresh(1)
  local ok, err = pcall(fn)
  r.PreventUIRefresh(-1)
  r.UpdateArrange()
  r.Undo_EndBlock2(0, name, -1)
  if not ok then r.ShowConsoleMsg('PietosiGlitch error: ' .. tostring(err) .. '\n') end
end

return L
