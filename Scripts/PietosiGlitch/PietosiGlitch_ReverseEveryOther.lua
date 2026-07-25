-- @description PietosiGlitch ReverseEveryOther - flip every 2nd selected slice
-- @version 1.0.0
-- @author pie
-- @provides [main=main] .
-- @about Toggles take-reverse on every second selected slice (sorted by time).
--   Run twice to restore the audio (slices stay). An unchopped item gets
--   chopped on the project grid first, so the grid sets the flip rate:
--   1/8 = churning chugs, 1/16 = zipper texture.
local r = reaper
local L = dofile(debug.getinfo(1, 'S').source:match('@?(.*[/\\])') .. 'PGlitchLib.lua')

local cmd = L.namedCommand('takereverse', { 'toggle take reverse' })
if not cmd then
  r.MB('Could not find the "Toggle take reverse" action.', 'PietosiGlitch', 0)
  return
end

L.undo('ReverseEveryOther', function()
  local targets = {}
  for _, run in ipairs(L.runs()) do
    L.gridChopRun(run)
    for idx, it in ipairs(run.items) do
      if idx % 2 == 0 then targets[#targets + 1] = it end
    end
  end
  L.applyActionToItems(cmd, targets)
end)
