-- @description PietosiGlitch WheelStutter - wheel retriggers the last beat
-- @version 1.0.0
-- @author pie
-- @provides [main=main] .
-- @about Bind to a mousewheel gesture. Wheel up: the final beat of the selected
--   item becomes 2, 4, 8... repeats of its own first slice (the trap fill).
--   Wheel down relaxes it back to the untouched item.
local r = reaper
local L = dofile(debug.getinfo(1, 'S').source:match('@?(.*[/\\])') .. 'PGlitchLib.lua')

local dir = L.wheelDir()

L.undo('WheelStutter', function()
  for _, run in ipairs(L.runs()) do
    local key = 'st_' .. L.sig(run)
    local K = L.state(key, 1)
    K = dir > 0 and math.min(K * 2, 32) or math.max(math.floor(K / 2), 1)

    local item = L.heal(run)
    r.SetMediaItemSelected(item, true)
    local bl = L.beatLen(math.max(run.start, run.fin - 0.05))
    local tailStart = run.fin - bl
    if tailStart <= run.start + 0.01 then
      tailStart = run.start + (run.fin - run.start) / 2
    end

    if K > 1 then
      local head_tail = L.splitAtTimes(item, { tailStart }, true)
      local tail = head_tail[#head_tail]
      local ts = r.GetMediaItemInfo_Value(tail, 'D_POSITION')
      local pieces = L.splitEqual(tail, ts, run.fin, K, true)
      L.offsetLock(pieces)
    end
    L.setState(key, K)
  end
end)
