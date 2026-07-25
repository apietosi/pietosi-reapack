-- @description PietosiView - MIDI view (F3): fullscreen MIDI editor
-- @version 1.0.0
-- @author pie
-- @provides [main=main] .
-- @about
--   One of the three PietosiKeys full-screen views:
--     F1 playlist-only   F2 fullscreen mixer   F3 fullscreen MIDI editor
--   Opens the selected item in the built-in MIDI editor (if nothing is
--   selected, grabs the item under the edit cursor on the selected track),
--   then loads window set #07 so a docked editor gets its saved fullscreen
--   layout. With a floating editor just maximize it once - REAPER remembers.
--   No MIDI item to target = silent no-op (same rule as the wheel gadgets).
--   F1 / F2 are bound inside the MIDI editor too, so they exit this view.

local r = reaper

local OPEN_NEEDLE, OPEN_FALLBACK = 'open in built-in midi editor', 40153
local SS_NEEDLE, SS_FALLBACK = 'load window set #07', 40460

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

-- target: current selection, else the item under the edit cursor on the
-- selected track (keyboard-nav friendly: cursor position is the intent)
if r.CountSelectedMediaItems(0) == 0 then
  local tr = r.GetSelectedTrack(0, 0)
  if tr then
    local pos = r.GetCursorPosition()
    for i = 0, r.CountTrackMediaItems(tr) - 1 do
      local it = r.GetTrackMediaItem(tr, i)
      local s = r.GetMediaItemInfo_Value(it, 'D_POSITION')
      if pos >= s and pos < s + r.GetMediaItemInfo_Value(it, 'D_LENGTH') then
        r.SetMediaItemSelected(it, true)
        r.UpdateArrange()
        break
      end
    end
  end
end
if r.CountSelectedMediaItems(0) == 0 then return end

r.Main_OnCommand(findCmd(OPEN_NEEDLE, OPEN_FALLBACK), 0)
r.Main_OnCommand(findCmd(SS_NEEDLE, SS_FALLBACK), 0)
