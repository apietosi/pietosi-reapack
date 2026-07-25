-- @description PostMix_Solo_Vocal_Helper
-- @version 1.0.0
-- @author pie
-- @provides [main=main] .
-- PostMix: Solo Vocal Helper
-- Select a vocal track → exclusive solo, ensure Vocal Strip + Comp,
-- open Vocal Strip UI for quick tone work.

local function lower(s) return string.lower(s or "") end

local function detect_role(name)
  local n = lower(name)
  if n:find("whisper") or n:find("raw") or n:find("talk") then return 3 end
  if n:find("adlib") or n:find("ad%-lib") or n:find("yell") or n:find("hype") then return 2 end
  if n:find("double") or n:find("hook") or n:find("stack") or n:find("harm") or n:find("bgv") then return 1 end
  return 0
end

local function find_fx(track, needle)
  for i = 0, reaper.TrackFX_GetCount(track) - 1 do
    local _, name = reaper.TrackFX_GetFXName(track, i, "")
    if name and name:find(needle, 1, true) then return i end
  end
  return -1
end

local function add_fx(track, name)
  local idx = reaper.TrackFX_AddByName(track, name, false, -1000)
  if idx < 0 then idx = reaper.TrackFX_AddByName(track, name, false, -1) end
  if idx < 0 then idx = reaper.TrackFX_AddByName(track, "JS: " .. name, false, -1) end
  return idx
end

local track = reaper.GetSelectedTrack(0, 0)
if not track then
  reaper.ShowMessageBox("Select a vocal track first.", "PostMix Solo Vocal", 0)
  return
end

reaper.Undo_BeginBlock()

local _, tname = reaper.GetTrackName(track)
local role = detect_role(tname)

local vs = find_fx(track, "PostMix Vocal Strip")
if vs < 0 then vs = add_fx(track, "PostMix Vocal Strip") end
if vs >= 0 then
  reaper.TrackFX_SetParam(track, vs, 0, role)
  reaper.TrackFX_SetParam(track, vs, 1, 55)
  reaper.TrackFX_SetParam(track, vs, 17, 1)
  reaper.TrackFX_Show(track, vs, 3)
end

if find_fx(track, "PostMix Vocal Comp") < 0 then
  add_fx(track, "PostMix Vocal Comp")
end

reaper.SoloAllTracks(0)
reaper.SetMediaTrackInfo_Value(track, "I_SOLO", 1)

reaper.Undo_EndBlock("PostMix: Solo Vocal Helper", -1)
