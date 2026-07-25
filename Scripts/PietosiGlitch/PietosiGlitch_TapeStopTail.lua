-- @description PietosiGlitch TapeStopTail - rendered-in tape stop on the last grid division
-- @version 1.0.0
-- @author pie
-- @provides [main=main] .
-- @about Splits off the final grid division of the selected item and writes
--   decelerating varispeed stretch markers into it (preserve-pitch off): a real
--   tape stop, baked into the item, no plugin. The grid sets the stop length:
--   1/1 = long dramatic dive, 1/4 = one-beat stop, 1/16 = quick hiccup.
--   Undo restores.
local r = reaper
local L = dofile(debug.getinfo(1, 'S').source:match('@?(.*[/\\])') .. 'PGlitchLib.lua')

local STEPS = 8

L.undo('TapeStopTail', function()
  for _, run in ipairs(L.runs()) do
    local item = L.heal(run)
    r.SetMediaItemSelected(item, true)
    local bl = L.gridLen(math.max(run.start, run.fin - 0.05))
    local tailStart = run.fin - bl
    if tailStart <= run.start + 0.01 then
      tailStart = run.start + (run.fin - run.start) / 2
    end

    local pieces = L.splitAtTimes(item, { tailStart }, true)
    local tail = pieces[#pieces]
    local tk = r.GetActiveTake(tail)
    if tk and not r.TakeIsMIDI(tk) then
      local len = r.GetMediaItemInfo_Value(tail, 'D_LENGTH')
      local rate = r.GetMediaItemTakeInfo_Value(tk, 'D_PLAYRATE')
      local offs = r.GetMediaItemTakeInfo_Value(tk, 'D_STARTOFFS')
      r.SetMediaItemTakeInfo_Value(tk, 'B_PPITCH', 0)
      local nsm = r.GetTakeNumStretchMarkers(tk)
      if nsm > 0 then r.DeleteTakeStretchMarkers(tk, 0, nsm) end
      -- linear tape deceleration: source progress = t - t^2/2
      for s = 0, STEPS do
        local f = s / STEPS
        local src = f - f * f / 2
        r.SetTakeStretchMarker(tk, -1, len * f * rate, offs + rate * len * src)
      end
      r.SetMediaItemInfo_Value(tail, 'D_FADEOUTLEN', len * 0.1)
    end
  end
end)
