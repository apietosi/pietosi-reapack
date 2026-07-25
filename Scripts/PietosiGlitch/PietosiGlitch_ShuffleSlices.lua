-- @description PietosiGlitch ShuffleSlices - randomly reorder selected slices
-- @version 1.0.0
-- @author pie
-- @provides [main=main] .
-- @about One keypress randomly reorders the selected slices within their span.
--   Run again for a new roll. An unchopped item gets chopped on the project
--   grid first, so the grid selection sets the slice size: 1/4 = chunky
--   rearrange, 1/32 = granular smear.
local r = reaper
local L = dofile(debug.getinfo(1, 'S').source:match('@?(.*[/\\])') .. 'PGlitchLib.lua')

math.randomseed(math.floor(os.clock() * 100000))

L.undo('ShuffleSlices', function()
  for _, run in ipairs(L.runs()) do
    L.gridChopRun(run)
    if #run.items > 1 then
      local shuffled = {}
      for i, it in ipairs(run.items) do shuffled[i] = it end
      for i = #shuffled, 2, -1 do
        local j = math.random(i)
        shuffled[i], shuffled[j] = shuffled[j], shuffled[i]
      end
      local pos = run.start
      for _, it in ipairs(shuffled) do
        r.SetMediaItemInfo_Value(it, 'D_POSITION', pos)
        pos = pos + r.GetMediaItemInfo_Value(it, 'D_LENGTH')
      end
    end
  end
end)
