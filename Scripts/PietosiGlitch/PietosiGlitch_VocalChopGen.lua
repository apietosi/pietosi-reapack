-- @description PietosiGlitch VocalChopGen - grid-chop + random scale pitches
-- @version 1.0.0
-- @author pie
-- @provides [main=main] .
-- @about Splits the selected item on the project grid and pitches every slice
--   to a random note of a minor scale (preserve-pitch on = chipmunk formants).
--   The hyperpop vocal chop generator. Run again for a new roll.
local r = reaper
local L = dofile(debug.getinfo(1, 'S').source:match('@?(.*[/\\])') .. 'PGlitchLib.lua')

local SCALE = { 0, 2, 3, 5, 7, 10, 12, 12, 15 } -- weighted toward the octave

math.randomseed(math.floor(os.clock() * 100000))

L.undo('VocalChopGen', function()
  for _, run in ipairs(L.runs()) do
    local item = L.heal(run)
    r.SetMediaItemSelected(item, true)
    local times, p = {}, run.start
    for _ = 1, 512 do
      p = p + L.gridLen(p)
      if p >= run.fin - 0.002 then break end
      times[#times + 1] = p
    end
    local pieces = L.splitAtTimes(item, times, true)
    for _, piece in ipairs(pieces) do
      local tk = r.GetActiveTake(piece)
      if tk and not r.TakeIsMIDI(tk) then
        r.SetMediaItemTakeInfo_Value(tk, 'B_PPITCH', 1)
        r.SetMediaItemTakeInfo_Value(tk, 'D_PITCH', SCALE[math.random(#SCALE)])
      end
    end
  end
end)
