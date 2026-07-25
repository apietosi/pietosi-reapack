-- @description PostMix_Apply_SmartStrip_By_Name
-- @version 1.0.0
-- @author pie
-- @provides [main=main] .
-- PostMix: Apply Smart Strip by track name
-- Selected tracks, or all tracks if none selected.
-- Inserts PostMix Smart Strip (if missing) and sets Source from name keywords.

local FX_ADD = "PostMix Smart Strip"
local SOURCE_PARAM = 0 -- slider1
local POLISH_PARAM = 1 -- slider2
local AUTO_PARAM = 18  -- slider19

local function lower(s)
  return string.lower(s or "")
end

local function detect_source(name)
  local n = lower(name)
  if n:find("808") or n:find("sub") or (n:find("bass") and not n:find("mid")) then
    return 1, "808/Sub"
  end
  if n:find("kick") or n:find("kck") or n:find("bd") then
    return 0, "Kick"
  end
  if n:find("snare") or n:find("snr") or n:find("clap") or n:find("rim") then
    return 2, "Snare"
  end
  if n:find("hat") or n:find("hh") or n:find("cym") or n:find("ride")
      or n:find("perc") or n:find("shaker") then
    return 3, "Hats"
  end
  if n:find("vox") or n:find("vocal") or n:find("rap") or n:find("topline")
      or n:find("adlib") or n:find("hook") or n:find("verse")
      or n:find("yanno") or n:find("yan2") then
    return 5, "Vocal"
  end
  if n:find("melody") or n:find("mel") or n:find("synth") or n:find("lead")
      or n:find("pad") or n:find("keys") or n:find("guitar") or n:find("gtr")
      or n:find("piano") or n:find("pluck") then
    return 4, "Melody/Synth"
  end
  if n:find("bus") or n:find("group") or n:find("drum") or n:find("master") or n:find("mix") then
    return 6, "Bus/Group"
  end
  return 7, "Flat"
end

local function find_fx(track)
  local cnt = reaper.TrackFX_GetCount(track)
  for i = 0, cnt - 1 do
    local retval, name = reaper.TrackFX_GetFXName(track, i, "")
    if name and name:find("PostMix Smart Strip") then
      return i
    end
  end
  return -1
end

local function process_track(track)
  local _, tname = reaper.GetTrackName(track)
  local src, label = detect_source(tname)
  local fx_idx = find_fx(track)

  if fx_idx < 0 then
    -- -1000 = add at first slot if supported; else instantiate
    fx_idx = reaper.TrackFX_AddByName(track, FX_ADD, false, -1000)
    if fx_idx < 0 then
      fx_idx = reaper.TrackFX_AddByName(track, "JS: PostMix Smart Strip", false, -1000)
    end
    if fx_idx < 0 then
      fx_idx = reaper.TrackFX_AddByName(track, "PostMix_SmartStrip", false, -1)
    end
  end

  if fx_idx < 0 then
    return false, tname, "FX not found — open FX browser and confirm JS: PostMix Smart Strip exists"
  end

  -- Enumerated Source: set as raw value 0..7
  reaper.TrackFX_SetParam(track, fx_idx, SOURCE_PARAM, src)
  reaper.TrackFX_SetParam(track, fx_idx, POLISH_PARAM, 50)
  reaper.TrackFX_SetParam(track, fx_idx, AUTO_PARAM, 1)

  return true, tname, label
end

----------------------------------------------------------------
reaper.Undo_BeginBlock()

local sel = reaper.CountSelectedTracks(0)
local targets = {}

if sel > 0 then
  for i = 0, sel - 1 do
    targets[#targets + 1] = reaper.GetSelectedTrack(0, i)
  end
else
  local nt = reaper.CountTracks(0)
  for i = 0, nt - 1 do
    targets[#targets + 1] = reaper.GetTrack(0, i)
  end
end

local ok_n, fail_n = 0, 0
local report = {}

for _, tr in ipairs(targets) do
  local ok, name, info = process_track(tr)
  if ok then
    ok_n = ok_n + 1
    report[#report + 1] = string.format("  OK  %s -> %s", name, info)
  else
    fail_n = fail_n + 1
    report[#report + 1] = string.format("  FAIL %s -> %s", name, info)
  end
end

reaper.Undo_EndBlock("PostMix: Apply Smart Strip by name", -1)

reaper.ShowMessageBox(
  string.format("PostMix Smart Strip applied\n\nOK: %d   Failed: %d\n\n%s",
    ok_n, fail_n, table.concat(report, "\n")),
  "PostMix",
  0
)
