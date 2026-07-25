-- @description PietosiGlitch WheelGateChop - wheel gates the item on the grid
-- @version 1.0.0
-- @author pie
-- @provides [main=main] .
-- @about Bind to a mousewheel gesture. Splits the selected item on the project
--   grid and mutes slices in patterns that get denser as you scroll up:
--   every 8th -> every 4th -> every 2nd -> 3 of 4 -> 7 of 8. Wheel down eases
--   off; level 0 restores the whole item. Non-destructive (mutes only).
local r = reaper
local L = dofile(debug.getinfo(1, 'S').source:match('@?(.*[/\\])') .. 'PGlitchLib.lua')

local dir = L.wheelDir()

local patterns = {
  function(i) return false end,
  function(i) return i % 8 == 7 end,
  function(i) return i % 4 == 3 end,
  function(i) return i % 2 == 1 end,
  function(i) return i % 4 ~= 0 end,
  function(i) return i % 8 ~= 0 end,
}

L.undo('WheelGateChop', function()
  for _, run in ipairs(L.runs()) do
    local key = 'gc_' .. L.sig(run)
    local lvl = math.max(0, math.min(#patterns - 1, L.state(key, 0) + dir))

    local item = L.heal(run)
    r.SetMediaItemSelected(item, true)
    r.SetMediaItemInfo_Value(item, 'B_MUTE', 0)

    if lvl > 0 then
      local times, p = {}, run.start
      for _ = 1, 512 do
        p = p + L.gridLen(p)
        if p >= run.fin - 0.002 then break end
        times[#times + 1] = p
      end
      local pieces = L.splitAtTimes(item, times, true)
      local pat = patterns[lvl + 1]
      for i, piece in ipairs(pieces) do
        r.SetMediaItemInfo_Value(piece, 'B_MUTE', pat(i - 1) and 1 or 0)
      end
    end
    L.setState(key, lvl)
  end
end)
