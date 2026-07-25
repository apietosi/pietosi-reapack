-- @description PietosiGlitch HalfTimeFlip - toggle dark half-speed on items
-- @version 1.0.0
-- @author pie
-- @provides [main=main] .
-- @about Drops the selected items to half playrate with preserve-pitch OFF:
--   everything an octave down and sludgy, same item length (plays the first
--   half of the content). Run again to restore the original rate.
local r = reaper
local L = dofile(debug.getinfo(1, 'S').source:match('@?(.*[/\\])') .. 'PGlitchLib.lua')

L.undo('HalfTimeFlip', function()
  for i = 0, r.CountSelectedMediaItems(0) - 1 do
    local it = r.GetSelectedMediaItem(0, i)
    local tk = r.GetActiveTake(it)
    if tk and not r.TakeIsMIDI(tk) then
      local _, saved = r.GetSetMediaItemTakeInfo_String(tk, 'P_EXT:PGHT', '', false)
      if saved ~= '' then
        r.SetMediaItemTakeInfo_Value(tk, 'D_PLAYRATE', tonumber(saved) or 1)
        r.SetMediaItemTakeInfo_Value(tk, 'B_PPITCH', 1)
        r.GetSetMediaItemTakeInfo_String(tk, 'P_EXT:PGHT', '', true)
      else
        local rate = r.GetMediaItemTakeInfo_Value(tk, 'D_PLAYRATE')
        r.GetSetMediaItemTakeInfo_String(tk, 'P_EXT:PGHT', tostring(rate), true)
        r.SetMediaItemTakeInfo_Value(tk, 'D_PLAYRATE', rate * 0.5)
        r.SetMediaItemTakeInfo_Value(tk, 'B_PPITCH', 0)
      end
    end
  end
end)
