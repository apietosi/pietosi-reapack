-- @description PostMix_Apply_Instrument_Strips
-- @version 1.0.0
-- @author pie
-- @provides [main=main] .
-- PostMix: Apply instrument (non-vocal) Smart Strips
-- Like Apply-by-name, but SKIPS vocal-named tracks and only processes
-- Kick / 808 / Snare / Hats / Melody / Bus style tracks.

local FX_ADD = "PostMix Smart Strip"
local SOURCE_PARAM = 0
local POLISH_PARAM = 1
local AUTO_PARAM = 18

local function lower(s) return string.lower(s or "") end

local function is_vocal(name)
  local n = lower(name)
  return n:find("vox") or n:find("vocal") or n:find("rap") or n:find("topline")
      or n:find("adlib") or n:find("hook") or n:find("verse") or n:find("yanno")
      or n:find("yan2") or n:find("choir") or n:find("talk")
end

-- returns source index or nil to skip
local function detect_instrument(name)
  local n = lower(name)
  if is_vocal(name) then return nil, "skip vocal" end
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
      or n:find("perc") or n:find("shaker") or n:find("ohat") then
    return 3, "Hats"
  end
  if n:find("melody") or n:find("mel") or n:find("synth") or n:find("lead")
      or n:find("pad") or n:find("keys") or n:find("guitar") or n:find("gtr")
      or n:find("piano") or n:find("pluck") or n:find("bell") or n:find("arp") then
    return 4, "Melody/Synth"
  end
  if n:find("bus") or n:find("group") or n:find("drum") or n:find("master")
      or n:find("mixbus") or n:find("instr") then
    return 6, "Bus/Group"
  end
  return nil, "no match"
end

local function find_fx(track)
  for i = 0, reaper.TrackFX_GetCount(track) - 1 do
    local _, name = reaper.TrackFX_GetFXName(track, i, "")
    if name and name:find("PostMix Smart Strip") then return i end
  end
  return -1
end

local function process_track(track)
  local _, tname = reaper.GetTrackName(track)
  local src, label = detect_instrument(tname)
  if not src then
    return "skip", tname, label
  end

  local fx_idx = find_fx(track)
  if fx_idx < 0 then
    fx_idx = reaper.TrackFX_AddByName(track, FX_ADD, false, -1000)
    if fx_idx < 0 then
      fx_idx = reaper.TrackFX_AddByName(track, "JS: PostMix Smart Strip", false, -1)
    end
  end
  if fx_idx < 0 then
    return "fail", tname, "Smart Strip not found"
  end

  reaper.TrackFX_SetParam(track, fx_idx, SOURCE_PARAM, src)
  reaper.TrackFX_SetParam(track, fx_idx, POLISH_PARAM, 50)
  reaper.TrackFX_SetParam(track, fx_idx, AUTO_PARAM, 1)

  -- Add Low End finisher on kick/808
  if src == 0 or src == 1 then
    local has_le = false
    for i = 0, reaper.TrackFX_GetCount(track) - 1 do
      local _, name = reaper.TrackFX_GetFXName(track, i, "")
      if name and name:find("PostMix Low End") then has_le = true break end
    end
    if not has_le then
      local le = reaper.TrackFX_AddByName(track, "PostMix Low End", false, -1)
      if le >= 0 then
        if src == 0 then -- kick: more punch, less sub weight
          reaper.TrackFX_SetParam(track, le, 0, 120) -- mono
          reaper.TrackFX_SetParam(track, le, 1, 40)  -- punch
          reaper.TrackFX_SetParam(track, le, 3, 20)  -- weight
          reaper.TrackFX_SetParam(track, le, 5, 15)  -- sat
        else -- 808
          reaper.TrackFX_SetParam(track, le, 0, 150)
          reaper.TrackFX_SetParam(track, le, 1, 15)
          reaper.TrackFX_SetParam(track, le, 3, 45)
          reaper.TrackFX_SetParam(track, le, 5, 25)
        end
      end
    end
  end

  -- Gain stage at end of chain for everything we touch
  local has_gs = false
  for i = 0, reaper.TrackFX_GetCount(track) - 1 do
    local _, name = reaper.TrackFX_GetFXName(track, i, "")
    if name and name:find("PostMix Gain Stage") then has_gs = true break end
  end
  if not has_gs then
    local gs = reaper.TrackFX_AddByName(track, "PostMix Gain Stage", false, -1)
    if gs >= 0 then
      -- buses a bit hotter
      local tgt = (src == 6) and -6 or -12
      reaper.TrackFX_SetParam(track, gs, 1, tgt)
    end
  end

  return "ok", tname, label
end

----------------------------------------------------------------
reaper.Undo_BeginBlock()

local sel = reaper.CountSelectedTracks(0)
local targets = {}
if sel > 0 then
  for i = 0, sel - 1 do targets[#targets+1] = reaper.GetSelectedTrack(0, i) end
else
  for i = 0, reaper.CountTracks(0) - 1 do targets[#targets+1] = reaper.GetTrack(0, i) end
end

local ok_n, skip_n, fail_n = 0, 0, 0
local report = {}

for _, tr in ipairs(targets) do
  local status, name, info = process_track(tr)
  if status == "ok" then
    ok_n = ok_n + 1
    report[#report+1] = string.format("  OK   %s -> %s", name, info)
  elseif status == "skip" then
    skip_n = skip_n + 1
    report[#report+1] = string.format("  skip %s (%s)", name, info)
  else
    fail_n = fail_n + 1
    report[#report+1] = string.format("  FAIL %s -> %s", name, info)
  end
end

reaper.Undo_EndBlock("PostMix: Apply instrument strips", -1)
reaper.ShowMessageBox(
  string.format(
    "PostMix instrument strips\n\nOK: %d   Skipped: %d   Failed: %d\n\n%s",
    ok_n, skip_n, fail_n, table.concat(report, "\n")
  ),
  "PostMix",
  0
)
