-- @description PostMix_Apply_Vocal_Strips
-- @version 1.0.0
-- @author pie
-- @provides [main=main] .
-- PostMix: Apply vocal strips by track name
-- Only processes vocal-like tracks. Adds:
--   PostMix Vocal Strip (role from name)
--   PostMix Vocal Comp
--   PostMix De-Esser (extra control after strip)
--   PostMix Gain Stage
--
-- Roles:
--   Lead  — vox, vocal, lead, main, verse, chorus (default)
--   Double/Hook — double, hook, stack, harm, harmony
--   Adlib — adlib, ad-lib, yell, hype, tag
--   Raw   — whisper, raw, talk, spoken

local function lower(s) return string.lower(s or "") end

local function is_vocal(name)
  local n = lower(name)
  return n:find("vox") or n:find("vocal") or n:find("rap") or n:find("topline")
      or n:find("adlib") or n:find("ad%-lib") or n:find("hook") or n:find("verse")
      or n:find("chorus") or n:find("yanno") or n:find("yan2") or n:find("choir")
      or n:find("talk") or n:find("double") or n:find("harm") or n:find("stack")
      or n:find("whisper") or n:find("hype") or n:find("yell") or n:find("tag")
      or n:find("lead v") or n:find("lvox") or n:find("bvox") or n:find("bgv")
end

-- role: 0 Lead, 1 Double, 2 Adlib, 3 Raw
local function detect_role(name)
  local n = lower(name)
  if n:find("whisper") or n:find("raw") or n:find("talk") or n:find("spoken") then
    return 3, "Raw/Whisper"
  end
  if n:find("adlib") or n:find("ad%-lib") or n:find("yell") or n:find("hype")
      or n:find("tag") or n:find("riff") then
    return 2, "Adlib"
  end
  if n:find("double") or n:find("hook") or n:find("stack") or n:find("harm")
      or n:find("choir") or n:find("bgv") or n:find("bvox") then
    return 1, "Double/Hook"
  end
  return 0, "Lead"
end

local function find_fx(track, needle)
  for i = 0, reaper.TrackFX_GetCount(track) - 1 do
    local _, name = reaper.TrackFX_GetFXName(track, i, "")
    if name and name:find(needle, 1, true) then return i end
  end
  return -1
end

local function add_fx(track, name)
  local idx = reaper.TrackFX_AddByName(track, name, false, -1)
  if idx < 0 then
    idx = reaper.TrackFX_AddByName(track, "JS: " .. name, false, -1)
  end
  return idx
end

local function ensure_fx(track, needle, add_name)
  local idx = find_fx(track, needle)
  if idx >= 0 then return idx, false end
  idx = add_fx(track, add_name)
  return idx, true
end

local function process_track(track)
  local _, tname = reaper.GetTrackName(track)
  if not is_vocal(tname) then
    return "skip", tname, "not vocal"
  end

  local role, role_label = detect_role(tname)
  local parts = {}

  -- 1) Vocal Strip
  local vs, new_vs = ensure_fx(track, "PostMix Vocal Strip", "PostMix Vocal Strip")
  if vs < 0 then
    return "fail", tname, "Vocal Strip not found (restart REAPER / check Effects/PostMix)"
  end
  reaper.TrackFX_SetParam(track, vs, 0, role)      -- role
  reaper.TrackFX_SetParam(track, vs, 1, 55)        -- polish
  reaper.TrackFX_SetParam(track, vs, 17, 1)        -- auto-load
  parts[#parts+1] = new_vs and "Strip+" or "Strip"

  -- 2) Vocal Comp
  local vc, new_vc = ensure_fx(track, "PostMix Vocal Comp", "PostMix Vocal Comp")
  if vc >= 0 then
    if role == 0 then -- lead: more GR
      reaper.TrackFX_SetParam(track, vc, 0, -18) -- thresh
      reaper.TrackFX_SetParam(track, vc, 1, 3)    -- ratio
      reaper.TrackFX_SetParam(track, vc, 9, 1)    -- auto makeup
    elseif role == 1 then -- double: lighter
      reaper.TrackFX_SetParam(track, vc, 0, -16)
      reaper.TrackFX_SetParam(track, vc, 1, 2.5)
      reaper.TrackFX_SetParam(track, vc, 9, 1)
    elseif role == 2 then -- adlib: lighter
      reaper.TrackFX_SetParam(track, vc, 0, -14)
      reaper.TrackFX_SetParam(track, vc, 1, 2.2)
      reaper.TrackFX_SetParam(track, vc, 9, 1)
    else -- raw
      reaper.TrackFX_SetParam(track, vc, 0, -20)
      reaper.TrackFX_SetParam(track, vc, 1, 2)
      reaper.TrackFX_SetParam(track, vc, 9, 1)
    end
    parts[#parts+1] = new_vc and "Comp+" or "Comp"
  end

  -- 3) Extra De-Esser after strip (for fine control)
  local de, new_de = ensure_fx(track, "PostMix De-Esser", "PostMix De-Esser")
  if de >= 0 then
    if role == 2 then
      reaper.TrackFX_SetParam(track, de, 1, 6)  -- range
      reaper.TrackFX_SetParam(track, de, 2, 7000)
    else
      reaper.TrackFX_SetParam(track, de, 1, 8)
      reaper.TrackFX_SetParam(track, de, 2, 6500)
    end
    reaper.TrackFX_SetParam(track, de, 0, -28) -- thresh
    parts[#parts+1] = new_de and "DeEss+" or "DeEss"
  end

  -- 4) Gain Stage
  local gs, new_gs = ensure_fx(track, "PostMix Gain Stage", "PostMix Gain Stage")
  if gs >= 0 then
    reaper.TrackFX_SetParam(track, gs, 1, -12) -- target peak
    parts[#parts+1] = new_gs and "Gain+" or "Gain"
  end

  return "ok", tname, role_label .. " [" .. table.concat(parts, " ") .. "]"
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
  else
    fail_n = fail_n + 1
    report[#report+1] = string.format("  FAIL %s -> %s", name, info)
  end
end

reaper.Undo_EndBlock("PostMix: Apply vocal strips", -1)

reaper.ShowMessageBox(
  string.format(
    "PostMix vocal strips\n\nOK: %d   Skipped (non-vox): %d   Failed: %d\n\n%s",
    ok_n, skip_n, fail_n,
    #report > 0 and table.concat(report, "\n") or "(no vocal tracks matched)"
  ),
  "PostMix Vocals",
  0
)
