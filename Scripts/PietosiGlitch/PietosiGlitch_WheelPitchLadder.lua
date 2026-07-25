-- @description PietosiGlitch WheelPitchLadder - wheel pitches slices into a riser
-- @version 1.0.0
-- @author pie
-- @provides [main=main] .
-- @about Bind to a mousewheel gesture. On a chopped item (WheelSplit it first,
--   or this splits a whole item into 8), each wheel tick adds +1 semitone per
--   slice (riser); wheel down goes negative (collapse-faller). Zero restores.
local r = reaper
local L = dofile(debug.getinfo(1, 'S').source:match('@?(.*[/\\])') .. 'PGlitchLib.lua')

local dir = L.wheelDir()

L.undo('WheelPitchLadder', function()
  for _, run in ipairs(L.runs()) do
    local key = 'pl_' .. L.sig(run)
    local S = L.state(key, 0) + dir

    local items = run.items
    if #items == 1 then
      items = L.splitEqual(items[1], run.start, run.fin, 8, true)
    end
    for idx, it in ipairs(items) do
      local tk = r.GetActiveTake(it)
      if tk then
        r.SetMediaItemTakeInfo_Value(tk, 'B_PPITCH', 1)
        r.SetMediaItemTakeInfo_Value(tk, 'D_PITCH', S * (idx - 1))
      end
    end
    L.setState(key, S)
  end
end)
