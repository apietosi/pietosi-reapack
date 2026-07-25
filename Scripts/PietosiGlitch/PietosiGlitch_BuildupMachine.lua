-- @description PietosiGlitch BuildupMachine - accelerating fill into the downbeat
-- @version 1.0.0
-- @author pie
-- @provides [main=main] .
-- @about Rebuilds the last 4 beats of the selected item as an accelerating
--   stutter: grid repeats -> grid x2 -> grid x4 -> reversed crash slice.
--   With grid 1/8 that's the classic 1/8 -> 1/16 -> 1/32 riser; coarser grid =
--   chunkier trap fill, finer grid = drill madness. One keypress. Undo restores.
local r = reaper
local L = dofile(debug.getinfo(1, 'S').source:match('@?(.*[/\\])') .. 'PGlitchLib.lua')

local revcmd = L.namedCommand('takereverse', { 'toggle take reverse' })

L.undo('BuildupMachine', function()
  for _, run in ipairs(L.runs()) do
    local item = L.heal(run)
    r.SetMediaItemSelected(item, true)

    local bl = L.beatLen(math.max(run.start, run.fin - 0.05))
    local barStart = run.fin - bl * 4
    if barStart <= run.start + 0.01 then barStart = run.start end
    local B = run.fin - barStart

    -- repeats per zone follow the project grid: each zone is half as long as
    -- the last but keeps n repeats, so the stutter rate doubles every zone.
    -- n is how many grid divisions fit in 2 beats (grid 1/8 -> 4 = the classic)
    local _, gdiv = r.GetSetProjectGrid(0, false)
    if not gdiv or gdiv <= 0 then gdiv = 0.125 end
    local n = math.floor(2 / (gdiv * 4) + 0.5)
    if n < 2 then n = 2 elseif n > 32 then n = 32 end

    -- zones as fractions of the fill: {from, to, repeats-per-zone}
    local zones = {
      { 0.000, 0.500, n },  -- two beats at grid rate
      { 0.500, 0.750, n },  -- one beat at grid x2
      { 0.750, 0.875, n },  -- half beat at grid x4
      { 0.875, 1.000, 1 },  -- reversed crash slice
    }

    local cuts = {}
    for _, z in ipairs(zones) do
      local t = barStart + B * z[1]
      if t > run.start + 0.002 then cuts[#cuts + 1] = t end
    end
    local pieces = L.splitAtTimes(item, cuts, true)

    -- map produced pieces back to zones (skip the head piece if present)
    local zi = #pieces - #zones + 1
    for k, z in ipairs(zones) do
      local piece = pieces[zi + k - 1]
      if piece then
        local zs = r.GetMediaItemInfo_Value(piece, 'D_POSITION')
        local ze = zs + r.GetMediaItemInfo_Value(piece, 'D_LENGTH')
        if z[3] > 1 then
          local reps = L.splitEqual(piece, zs, ze, z[3], true)
          L.offsetLock(reps)
        elseif revcmd then
          L.applyActionToItems(revcmd, { piece })
        end
      end
    end
  end
end)
