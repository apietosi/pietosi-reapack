-- @description PietosiWheelSplit - wheel splits selected items into equal parts
-- @version 0.1.0
-- @author pie
-- @provides [main=main] .
-- @about
--   Bind to a mousewheel gesture (e.g. Ctrl+wheel): select an item, scroll up
--   and it becomes 2 equal pieces, then 3, 4... in the same overall span.
--   Scroll down to merge back until it's whole again. Contiguous selected
--   pieces (like the ones this script makes) are treated as one group; every
--   separately-selected item gets its own count. Also runs from a key
--   (acts like one wheel-up tick).

local r = reaper

local _, _, _, _, _, _, val = r.get_action_context()
local dir = (val or 0) < 0 and -1 or 1

local nsel = r.CountSelectedMediaItems(0)
if nsel == 0 then return end

-- collect selected items per track, sorted by position
local bytrack, order = {}, {}
for i = 0, nsel - 1 do
  local it = r.GetSelectedMediaItem(0, i)
  local tr = r.GetMediaItemTrack(it)
  local key = tostring(tr)
  if not bytrack[key] then
    bytrack[key] = { tr = tr, items = {} }
    order[#order + 1] = key
  end
  local t = bytrack[key].items
  t[#t + 1] = it
end

-- group each track's items into contiguous runs (gap < 2 ms = same group)
local runs = {}
for _, key in ipairs(order) do
  local grp = bytrack[key]
  table.sort(grp.items, function(a, b)
    return r.GetMediaItemInfo_Value(a, 'D_POSITION') < r.GetMediaItemInfo_Value(b, 'D_POSITION')
  end)
  local cur
  for _, it in ipairs(grp.items) do
    local pos = r.GetMediaItemInfo_Value(it, 'D_POSITION')
    local fin = pos + r.GetMediaItemInfo_Value(it, 'D_LENGTH')
    if cur and pos - cur.fin < 0.002 then
      cur.items[#cur.items + 1] = it
      if fin > cur.fin then cur.fin = fin end
    else
      cur = { tr = grp.tr, items = { it }, start = pos, fin = fin }
      runs[#runs + 1] = cur
    end
  end
end

r.Undo_BeginBlock2(0)
r.PreventUIRefresh(1)

local labelN = 0
for _, run in ipairs(runs) do
  local N = math.max(1, #run.items + dir)
  labelN = math.max(labelN, N)
  if N ~= #run.items then
    -- heal: stretch the first piece across the whole span, drop the rest
    -- (pieces made by this script are contiguous slices of the same take)
    local first = run.items[1]
    for i = #run.items, 2, -1 do
      r.DeleteTrackMediaItem(run.tr, run.items[i])
    end
    r.SetMediaItemInfo_Value(first, 'D_LENGTH', run.fin - run.start)
    -- resplit into N equal parts, keeping everything selected
    r.SetMediaItemSelected(first, true)
    local cur = first
    for k = 1, N - 1 do
      local right = r.SplitMediaItem(cur, run.start + (run.fin - run.start) * k / N)
      if right then
        r.SetMediaItemSelected(right, true)
        cur = right
      end
    end
  end
end

r.PreventUIRefresh(-1)
r.UpdateArrange()
r.Undo_EndBlock2(0, ('WheelSplit: %d equal part%s'):format(labelN, labelN == 1 and '' or 's'), -1)
