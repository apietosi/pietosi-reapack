-- @description Pietosi_HatRandomRR_LoadRS5K
-- @version 1.0.0
-- @author pie
-- @provides [main=main] .
-- Pietosi_HatRandomRR_LoadRS5K.lua
-- Loads 6 RS5K instances on the selected (or named) hat RR track.
-- Each sample responds to one MIDI note (60..65).
-- MIDI item already has random notes in that range (no immediate repeats).

-- ==== config ================================================================
-- Folder holding the round-robin hat one-shots. Leave blank and the script
-- will ask once, then remember it per machine (so Windows and macOS can each
-- point somewhere different without editing this file).
local SAMPLE_DIR = ""

-- Files are used in sorted order, so the rr0_ / rr1_ / rr2_ naming keeps
-- each sample on a predictable note.
local EXTS = { wav = true, aif = true, aiff = true, flac = true, mp3 = true, ogg = true }
-- ===========================================================================

local SEP = package.config:sub(1, 1)

local function remembered()
  local d = reaper.GetExtState("PietosiHatRR", "sample_dir")
  return (d ~= "" ) and d or nil
end

local function resolve_dir()
  if SAMPLE_DIR ~= "" then return SAMPLE_DIR end

  local saved = remembered()
  if saved and reaper.EnumerateFiles(saved, 0) then return saved end

  -- JS_ReaScriptAPI gives a proper folder picker; fall back to file-picker.
  if reaper.JS_Dialog_BrowseForFolder then
    local ok, path = reaper.JS_Dialog_BrowseForFolder("Choose the hat round-robin folder", "")
    if ok == 1 and path and path ~= "" then
      reaper.SetExtState("PietosiHatRR", "sample_dir", path, true)
      return path
    end
    return nil
  end

  local ok, file = reaper.GetUserFileNameForRead("", "Pick ANY hat sample in the folder", "")
  if not ok then return nil end
  local dir = file:match("^(.*)[/\\][^/\\]+$")
  if dir then reaper.SetExtState("PietosiHatRR", "sample_dir", dir, true) end
  return dir
end

local function collect(dir)
  local found = {}
  local i = 0
  while true do
    local f = reaper.EnumerateFiles(dir, i)
    if not f then break end
    local ext = f:match("%.([^.]+)$")
    if ext and EXTS[ext:lower()] then found[#found + 1] = f end
    i = i + 1
  end
  table.sort(found)
  return found
end

local SAMPLE_DIR_RESOLVED = resolve_dir()
if not SAMPLE_DIR_RESOLVED then
  reaper.ShowMessageBox("No hat folder chosen.", "Hat RR", 0)
  return
end

local samples = {}
for _, f in ipairs(collect(SAMPLE_DIR_RESOLVED)) do
  samples[#samples + 1] = SAMPLE_DIR_RESOLVED .. SEP .. f
end

if #samples == 0 then
  reaper.ShowMessageBox(
    "No audio files found in:\n" .. SAMPLE_DIR_RESOLVED ..
    "\n\nClear the saved folder with:\nExtensions > ReaScript console, or just pick again next run.",
    "Hat RR", 0)
  reaper.DeleteExtState("PietosiHatRR", "sample_dir", true)
  return
end
local notes = {}
for i = 1, #samples do notes[i] = 59 + i end  -- 60, 61, 62, ...

local function find_track()
  local sel = reaper.GetSelectedTrack(0, 0)
  if sel then
    local _, name = reaper.GetTrackName(sel)
    if name and name:find("HAT RR") then return sel end
  end
  for i = 0, reaper.CountTracks(0) - 1 do
    local tr = reaper.GetTrack(0, i)
    local _, name = reaper.GetTrackName(tr)
    if name and name:find("HAT RR") then return tr end
  end
  return reaper.GetSelectedTrack(0, 0)
end

local function set_note_range(track, fx, note)
  -- RS5K exposes "Note range start/end" (or similar) as parameters
  local nparams = reaper.TrackFX_GetNumParams(track, fx)
  local start_idx, end_idx = nil, nil
  for p = 0, nparams - 1 do
    local _, pname = reaper.TrackFX_GetParamName(track, fx, p, "")
    local low = (pname or ""):lower()
    if low:find("note range start") or low == "note start" or low:find("min note") then
      start_idx = p
    elseif low:find("note range end") or low == "note end" or low:find("max note") then
      end_idx = p
    end
  end
  -- fallback common RS5K param indices vary by version; also try named config
  reaper.TrackFX_SetNamedConfigParm(track, fx, "NOTE_START", tostring(note))
  reaper.TrackFX_SetNamedConfigParm(track, fx, "NOTE_END", tostring(note))
  if start_idx then
    -- many builds store note as 0..1 = 0..127
    reaper.TrackFX_SetParamNormalized(track, fx, start_idx, note / 127.0)
  end
  if end_idx then
    reaper.TrackFX_SetParamNormalized(track, fx, end_idx, note / 127.0)
  end
end

reaper.Undo_BeginBlock()
local track = find_track()
if not track then
  reaper.ShowMessageBox("Select the 'HAT RR random' track first.", "Hat RR", 0)
  return
end

-- clear existing RS5K on track
for fx = reaper.TrackFX_GetCount(track) - 1, 0, -1 do
  local _, name = reaper.TrackFX_GetFXName(track, fx, "")
  if name and name:find("ReaSamplOmatic") then
    reaper.TrackFX_Delete(track, fx)
  end
end

local loaded = 0
for i, path in ipairs(samples) do
  local note = notes[i]
  if not reaper.file_exists(path) then
    reaper.ShowConsoleMsg("Missing sample: " .. path .. "\n")
  else
    local fx = reaper.TrackFX_AddByName(track, "ReaSamplOmatic5000 (Cockos)", false, -1)
    if fx < 0 then
      fx = reaper.TrackFX_AddByName(track, "VSTi: ReaSamplOmatic5000 (Cockos)", false, -1)
    end
    if fx >= 0 then
      reaper.TrackFX_SetNamedConfigParm(track, fx, "FILE0", path)
      reaper.TrackFX_SetNamedConfigParm(track, fx, "DONE", "")
      -- one-shot / sample mode (best-effort)
      reaper.TrackFX_SetNamedConfigParm(track, fx, "MODE", "1")
      set_note_range(track, fx, note)
      loaded = loaded + 1
      reaper.ShowConsoleMsg(string.format("RS5K #%d note %d <- %s\n", i, note, path))
    end
  end
end

reaper.TrackFX_Show(track, 0, 1) -- show FX chain
reaper.Undo_EndBlock("Load hat RR RS5K samples", -1)
reaper.ShowMessageBox(
  string.format("Loaded %d/%d hat samples on track.\nMIDI notes %d-%d are random per hit.\nTweak RS5K note ranges if a sample triggers on multiple notes.",
    loaded, #samples, notes[1], notes[#notes]),
  "Hat RR setup",
  0
)
