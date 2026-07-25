-- @description PostMix_Solo_EQ_Helper
-- @version 1.0.0
-- @author pie
-- @provides [main=main] .
-- PostMix: Solo EQ Helper
-- Select a track → exclusive solo, ensure Smart Strip, open its UI.
-- Bind to a hotkey for fast "fix this track" passes.

local FX_ADD = "PostMix Smart Strip"

local function lower(s) return string.lower(s or "") end

local function detect_source(name)
  local n = lower(name)
  if n:find("808") or n:find("sub") or n:find("bass") then return 1 end
  if n:find("kick") or n:find("kck") then return 0 end
  if n:find("snare") or n:find("snr") or n:find("clap") then return 2 end
  if n:find("hat") or n:find("hh") or n:find("cym") or n:find("perc") then return 3 end
  if n:find("vox") or n:find("vocal") or n:find("rap") or n:find("adlib")
      or n:find("hook") or n:find("yanno") then return 5 end
  if n:find("melody") or n:find("synth") or n:find("lead") or n:find("pad")
      or n:find("keys") then return 4 end
  if n:find("bus") or n:find("group") or n:find("drum") or n:find("master") then return 6 end
  return 7
end

local track = reaper.GetSelectedTrack(0, 0)
if not track then
  reaper.ShowMessageBox("Select a track first.", "PostMix Solo EQ", 0)
  return
end

reaper.Undo_BeginBlock()

local _, tname = reaper.GetTrackName(track)
local fx_idx = -1
local cnt = reaper.TrackFX_GetCount(track)
for i = 0, cnt - 1 do
  local _, name = reaper.TrackFX_GetFXName(track, i, "")
  if name and name:find("PostMix Smart Strip") then
    fx_idx = i
    break
  end
end

if fx_idx < 0 then
  fx_idx = reaper.TrackFX_AddByName(track, FX_ADD, false, -1000)
  if fx_idx < 0 then
    fx_idx = reaper.TrackFX_AddByName(track, "JS: PostMix Smart Strip", false, -1)
  end
end

if fx_idx >= 0 then
  local src = detect_source(tname)
  reaper.TrackFX_SetParam(track, fx_idx, 0, src)
  reaper.TrackFX_SetParam(track, fx_idx, 1, 50)
  reaper.TrackFX_SetParam(track, fx_idx, 18, 1)
  reaper.TrackFX_Show(track, fx_idx, 3) -- floating window
end

reaper.SoloAllTracks(0)
reaper.SetMediaTrackInfo_Value(track, "I_SOLO", 1)

reaper.Undo_EndBlock("PostMix: Solo EQ Helper", -1)
