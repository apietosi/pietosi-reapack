-- @description PietosiView - Mixer view (F2): fullscreen mixer, thin arrange strip
-- @version 1.0.0
-- @author pie
-- @provides [main=main] .
-- @about
--   One of the three PietosiKeys full-screen views:
--     F1 playlist-only   F2 fullscreen mixer   F3 fullscreen MIDI editor
--   Closes any MIDI editor, loads window set #06, and makes sure the mixer
--   is visible. Save the set once with the mixer docked and dragged nearly
--   full height (right-click mixer > Dock mixer in docker), FX inserts /
--   sends / I-O enabled in the mixer right-click menu, and a thin zoomed-out
--   arrange strip left above it.

local r = reaper

local SS_NEEDLE, SS_FALLBACK = 'load window set #06', 40459
local MIXER_TOGGLE = 40078 -- View: Toggle mixer visible

local function findCmd(needle, fallback)
  if r.APIExists('CF_EnumerateActions') then
    for i = 0, 200000 do
      local cmd, name = r.CF_EnumerateActions(0, i, '')
      if not cmd or cmd <= 0 then break end
      if (name or ''):lower():find(needle, 1, true) then return cmd end
    end
  end
  return fallback
end

local function closeMidiEditors()
  for _ = 1, 8 do
    local me = r.MIDIEditor_GetActive()
    if not me then return end
    r.MIDIEditor_OnCommand(me, 2) -- File: Close window
    if r.MIDIEditor_GetActive() == me then return end
  end
end

closeMidiEditors()
r.Main_OnCommand(findCmd(SS_NEEDLE, SS_FALLBACK), 0)
if r.GetToggleCommandState(MIXER_TOGGLE) == 0 then
  r.Main_OnCommand(MIXER_TOGGLE, 0)
end
