-- @description PostMix_Wire_Kick_to_808_Duck
-- @version 1.0.0
-- @author pie
-- @provides [main=main] .
-- PostMix: Wire Kick → 808 Duck
-- Finds tracks named like Kick and 808/Bass.
-- Puts PostMix Kick Duck on the 808 track and creates a pre-FX send
-- from Kick → 808 channels 3/4 (sidechain). Audio send is silent to mix
-- (channels 3/4 only) so kick doesn't double in the 808 track.
--
-- Select tracks to limit search, or run with nothing selected = whole project.

local DUCK_FX = "PostMix Kick Duck"

local function lower(s) return string.lower(s or "") end

local function is_kick(name)
  local n = lower(name)
  return n:find("kick") or n:find("kck") or n:match("%f[%w]bd%f[%W]") or n:find("bd ")
end

local function is_duck_target(name)
  local n = lower(name)
  -- 808 / sub / bass — not "mid bass" only tracks still ok
  if n:find("808") or n:find("sub") then return true end
  if n:find("bass") and not n:find("kick") then return true end
  return false
end

local function track_list()
  local sel = reaper.CountSelectedTracks(0)
  local t = {}
  if sel > 0 then
    for i = 0, sel - 1 do t[#t+1] = reaper.GetSelectedTrack(0, i) end
  else
    for i = 0, reaper.CountTracks(0) - 1 do t[#t+1] = reaper.GetTrack(0, i) end
  end
  return t
end

local function find_fx(track, needle)
  for i = 0, reaper.TrackFX_GetCount(track) - 1 do
    local _, name = reaper.TrackFX_GetFXName(track, i, "")
    if name and name:find(needle, 1, true) then return i end
  end
  return -1
end

local function ensure_duck_fx(track)
  local idx = find_fx(track, "PostMix Kick Duck")
  if idx >= 0 then return idx end
  idx = reaper.TrackFX_AddByName(track, DUCK_FX, false, -1)
  if idx < 0 then
    idx = reaper.TrackFX_AddByName(track, "JS: PostMix Kick Duck", false, -1)
  end
  return idx
end

local function ensure_nchan(track, n)
  local cur = reaper.GetMediaTrackInfo_Value(track, "I_NCHAN")
  if cur < n then
    reaper.SetMediaTrackInfo_Value(track, "I_NCHAN", n)
  end
end

-- True if this send already goes src → dst on channels 3/4
local function send_is_sc(src, send_idx, dst)
  local dest_tr = reaper.GetTrackSendInfo_Value(src, 0, send_idx, "P_DESTTRACK")
  if dest_tr ~= dst then return false end
  local dstchan = reaper.GetTrackSendInfo_Value(src, 0, send_idx, "I_DSTCHAN")
  return dstchan == 2 -- 0=ch1/2, 2=ch3/4
end

local function ensure_sc_send(src, dst)
  local n = reaper.GetTrackNumSends(src, 0)
  local send_idx = -1
  for i = 0, n - 1 do
    if send_is_sc(src, i, dst) then
      send_idx = i
      break
    end
  end

  if send_idx < 0 then
    send_idx = reaper.CreateTrackSend(src, dst)
  end
  if send_idx < 0 then return -1 end

  -- ch 1/2 → ch 3/4 (sidechain only; not main mix of dest)
  reaper.SetTrackSendInfo_Value(src, 0, send_idx, "I_SRCCHAN", 0)
  reaper.SetTrackSendInfo_Value(src, 0, send_idx, "I_DSTCHAN", 2)
  reaper.SetTrackSendInfo_Value(src, 0, send_idx, "I_SENDMODE", 0) -- post-fader
  reaper.SetTrackSendInfo_Value(src, 0, send_idx, "D_VOL", 1.0)
  reaper.SetTrackSendInfo_Value(src, 0, send_idx, "B_MUTE", 0)

  return send_idx
end

----------------------------------------------------------------
reaper.Undo_BeginBlock()

local tracks = track_list()
local kicks, targets = {}, {}

for _, tr in ipairs(tracks) do
  local _, name = reaper.GetTrackName(tr)
  if is_kick(name) then kicks[#kicks+1] = {tr = tr, name = name} end
  if is_duck_target(name) then targets[#targets+1] = {tr = tr, name = name} end
end

if #kicks == 0 then
  reaper.ShowMessageBox(
    "No Kick track found.\n\nName a track with 'Kick' (or select tracks and retry).",
    "PostMix Kick Duck", 0)
  reaper.Undo_EndBlock("PostMix: Wire Kick→808 (nothing)", -1)
  return
end

if #targets == 0 then
  reaper.ShowMessageBox(
    "No 808/Bass track found.\n\nName a track with '808', 'Sub', or 'Bass'.",
    "PostMix Kick Duck", 0)
  reaper.Undo_EndBlock("PostMix: Wire Kick→808 (nothing)", -1)
  return
end

-- Use first kick as key (most common)
local kick = kicks[1]
local report = { string.format("Key: %s", kick.name) }

for _, t in ipairs(targets) do
  ensure_nchan(t.tr, 4)
  local fx = ensure_duck_fx(t.tr)
  local send = ensure_sc_send(kick.tr, t.tr)
  if fx >= 0 and send >= 0 then
    -- sensible defaults
    reaper.TrackFX_SetParam(t.tr, fx, 0, 8)   -- depth 8 dB
    reaper.TrackFX_SetParam(t.tr, fx, 1, 5)   -- attack
    reaper.TrackFX_SetParam(t.tr, fx, 3, 120) -- release
    report[#report+1] = string.format("  OK  %s  (duck FX + SC send)", t.name)
  else
    report[#report+1] = string.format("  FAIL %s  (fx=%s send=%s)", t.name, tostring(fx), tostring(send))
  end
end

if #kicks > 1 then
  report[#report+1] = string.format("\n(Note: %d kick tracks found; used first: %s)", #kicks, kick.name)
end

reaper.Undo_EndBlock("PostMix: Wire Kick→808 Duck", -1)
reaper.ShowMessageBox(table.concat(report, "\n"), "PostMix Kick Duck", 0)
