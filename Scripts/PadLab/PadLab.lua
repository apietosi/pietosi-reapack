-- @description PadLab - launchpad-style drum sampler for REAPER
-- @version 1.0.0
-- @author pie
-- @provides [main=main] .
-- @about
--   One row per pad. Each row is a normal REAPER track holding native RS5K
--   instances (one per sample), a note-repeat JSFX and a sample-router JSFX.
--   Feed it folders, loose files, or Media Explorer databases; play pads from
--   the GUI, a MIDI controller, or the virtual keyboard. Everything is plain
--   tracks + FX, so routing/sidechain/buses and external scripting (MCP) all
--   work natively.

local r = reaper

if not r.ImGui_CreateContext then
  r.MB('PadLab needs the ReaImGui extension.\n\nInstall via ReaPack: Extensions > ReaPack > Browse packages > "ReaImGui".', 'PadLab', 0)
  return
end

local sep = package.config:sub(1, 1)
local script_path = debug.getinfo(1, 'S').source:match('@?(.*[/\\])') or ''
local resource = r.GetResourcePath()

------------------------------------------------------------------- constants

local RATES = { '1/4', '1/8', '1/8T', '1/16', '1/16T', '1/32', '1/32T', '1/64' }
local RATE_STR = table.concat(RATES, '\0') .. '\0'
local MODES = { 'Normal', 'Random', 'Round-Robin' }
local MODE_STR = table.concat(MODES, '\0') .. '\0'
local MAX_SAMPLES = 64
local PAD_VEL = 110
local BASE_NOTE = 36 -- C1, GM kick; rows count upward from here
local AUDIO_EXT = { wav = true, flac = true, aif = true, aiff = true, ogg = true, mp3 = true, wv = true, m4a = true }

local JSFX_FILES = { 'PadLab_NoteRepeat.jsfx', 'PadLab_Router.jsfx', 'PadLab_Monitor.jsfx' }
local JS_REPEAT = 'PadLab/PadLab_NoteRepeat.jsfx'
local JS_ROUTER = 'PadLab/PadLab_Router.jsfx'
local JS_MONITOR = 'PadLab/PadLab_Monitor.jsfx'

-- NoteRepeat JSFX param indices
local P_RPT_ON, P_RPT_RATE, P_RPT_GATE = 0, 1, 2
local P_RPT_MAPRPT, P_RPT_MAPMODE, P_RPT_MAPRATE, P_RPT_MAPRATEDN = 5, 6, 7, 8

math.randomseed(os.time())

--------------------------------------------------------------- JSFX install

local function InstallJSFX()
  local dst_dir = resource .. sep .. 'Effects' .. sep .. 'PadLab'
  r.RecursiveCreateDirectory(dst_dir, 0)
  for _, f in ipairs(JSFX_FILES) do
    local sf = io.open(script_path .. 'JSFX' .. sep .. f, 'rb')
    if sf then
      local data = sf:read('*a'); sf:close()
      local dst = dst_dir .. sep .. f
      local df = io.open(dst, 'rb')
      local cur = df and df:read('*a') or nil
      if df then df:close() end
      if cur ~= data then
        local wf = io.open(dst, 'wb')
        if wf then wf:write(data); wf:close() end
      end
    end
  end
end
InstallJSFX()

------------------------------------------------------------------- helpers

local function TrackIndex(tr)
  return math.floor(r.GetMediaTrackInfo_Value(tr, 'IP_TRACKNUMBER')) - 1
end

local function GetExt(tr)
  local _, v = r.GetSetMediaTrackInfo_String(tr, 'P_EXT:PADLAB', '', false)
  return v
end

local function FindParent()
  for i = 0, r.CountTracks(0) - 1 do
    local tr = r.GetTrack(0, i)
    if GetExt(tr) == 'parent' then return tr end
  end
end

-- rows are the contiguous run of P_EXT:PADLAB == 'row' tracks after the parent
local function GetRowTracks(parent)
  local rows = {}
  if not parent then return rows end
  local i = TrackIndex(parent) + 1
  while i < r.CountTracks(0) do
    local tr = r.GetTrack(0, i)
    if GetExt(tr) == 'row' then rows[#rows + 1] = tr else break end
    i = i + 1
  end
  return rows
end

local function FixFolder(parent)
  if not parent then return end
  local rows = GetRowTracks(parent)
  r.SetMediaTrackInfo_Value(parent, 'I_FOLDERDEPTH', #rows > 0 and 1 or 0)
  for i, tr in ipairs(rows) do
    r.SetMediaTrackInfo_Value(tr, 'I_FOLDERDEPTH', i == #rows and -1 or 0)
  end
end

local function EnsureParent()
  local p = FindParent()
  if p then return p end
  local idx = r.CountTracks(0)
  r.InsertTrackAtIndex(idx, true)
  local tr = r.GetTrack(0, idx)
  r.GetSetMediaTrackInfo_String(tr, 'P_NAME', 'PadLab', true)
  r.GetSetMediaTrackInfo_String(tr, 'P_EXT:PADLAB', 'parent', true)
  r.SetMediaTrackInfo_Value(tr, 'I_RECINPUT', 4096 + (63 << 5)) -- all MIDI inputs, all channels
  r.SetMediaTrackInfo_Value(tr, 'I_RECARM', 1)
  r.SetMediaTrackInfo_Value(tr, 'I_RECMON', 1)
  r.SetMediaTrackInfo_Value(tr, 'I_RECMODE', 2)                 -- monitor only, never records by accident
  return tr
end

local function AddFXAtEnd(tr, name)
  return r.TrackFX_AddByName(tr, name, false, -1000 - r.TrackFX_GetCount(tr))
end

local function AddJSFX(tr, relpath)
  local back = relpath:gsub('/', '\\')
  for _, name in ipairs({ 'JS:' .. relpath, 'JS:' .. back, relpath, back }) do
    local fx = AddFXAtEnd(tr, name)
    if fx >= 0 then return fx end
  end
  return -1
end

local function ParamIndexByName(tr, fx, needle)
  needle = needle:lower()
  for i = 0, r.TrackFX_GetNumParams(tr, fx) - 1 do
    local ok, pname = r.TrackFX_GetParamName(tr, fx, i, '')
    if ok and pname and pname:lower():find(needle, 1, true) then return i end
  end
end

------------------------------------------------------------------ row model

-- identify FX by internal identity, not display name (which can be renamed
-- or formatted differently depending on REAPER settings)
local function FXKey(tr, fx)
  local parts = {}
  local ok, s = r.TrackFX_GetNamedConfigParm(tr, fx, 'fx_ident')
  if ok and s and s ~= '' then parts[#parts + 1] = s end
  ok, s = r.TrackFX_GetNamedConfigParm(tr, fx, 'fx_name')
  if ok and s and s ~= '' then parts[#parts + 1] = s end
  local _, dn = r.TrackFX_GetFXName(tr, fx, '')
  parts[#parts + 1] = dn or ''
  return table.concat(parts, ' '):lower()
end

local function BuildRow(tr)
  local row = { track = tr, samples = 0, fxRepeat = -1, fxRouter = -1, rs5k = {} }
  local _, name = r.GetTrackName(tr)
  row.name = (name or ''):gsub('^PL: ', '')
  for fx = 0, r.TrackFX_GetCount(tr) - 1 do
    local key = FXKey(tr, fx)
    if key:find('padlab_noterepeat', 1, true) then
      row.fxRepeat = fx
    elseif key:find('padlab_router', 1, true) then
      row.fxRouter = fx
    elseif key:find('reasampl', 1, true) then
      row.rs5k[#row.rs5k + 1] = fx
    end
  end
  row.samples = #row.rs5k
  local _, src = r.GetSetMediaTrackInfo_String(tr, 'P_EXT:PADLAB_SRC', '', false)
  row.src = (src and src ~= '') and src or nil
  if row.fxRouter >= 0 then
    row.mode = math.floor((r.TrackFX_GetParam(tr, row.fxRouter, 0) or 0) + 0.5)
    row.padnote = math.floor((r.TrackFX_GetParam(tr, row.fxRouter, 2) or BASE_NOTE) + 0.5)
    row.humvel = math.floor((r.TrackFX_GetParam(tr, row.fxRouter, 3) or 0) + 0.5)
    row.humpitch = math.floor((r.TrackFX_GetParam(tr, row.fxRouter, 4) or 0) + 0.5)
  end
  if row.fxRepeat >= 0 then
    row.rptOn = (r.TrackFX_GetParam(tr, row.fxRepeat, 0) or 0) >= 0.5
    row.rptRate = math.floor((r.TrackFX_GetParam(tr, row.fxRepeat, 1) or 3) + 0.5)
    row.gate = math.floor((r.TrackFX_GetParam(tr, row.fxRepeat, 2) or 60) + 0.5)
  end
  if row.rs5k[1] then
    local fx = row.rs5k[1]
    local pi = ParamIndexByName(tr, fx, 'minimum velocity')
    row.dyn = pi and (r.TrackFX_GetParamNormalized(tr, fx, pi) < 0.5) or false
    pi = ParamIndexByName(tr, fx, 'obey note')
    row.choke = pi and (r.TrackFX_GetParamNormalized(tr, fx, pi) >= 0.5) or false
  end
  row.mute = r.GetMediaTrackInfo_Value(tr, 'B_MUTE') >= 0.5
  row.solo = r.GetMediaTrackInfo_Value(tr, 'I_SOLO') >= 0.5
  return row
end

-- the parent carries a tiny monitor JSFX so the GUI can MIDI-learn
local function EnsureMonitor(parent)
  for fx = 0, r.TrackFX_GetCount(parent) - 1 do
    local _, fxname = r.TrackFX_GetFXName(parent, fx, '')
    if (fxname or ''):find('PadLab_Monitor') then return end
  end
  AddJSFX(parent, JS_MONITOR)
end

local cache = { rows = {}, parent = nil, stamp = -1 }
local function InvalidateRows() cache.stamp = -1 end

local function Rows()
  local stamp = r.GetProjectStateChangeCount(0)
  if stamp ~= cache.stamp then
    cache.parent = FindParent()
    if cache.parent then EnsureMonitor(cache.parent) end
    cache.rows = {}
    for _, tr in ipairs(GetRowTracks(cache.parent)) do
      cache.rows[#cache.rows + 1] = BuildRow(tr)
    end
    cache.stamp = stamp
  end
  return cache.rows, cache.parent
end

-- state mirror for external tools (MCP etc.)
local function SaveState()
  local rows = GetRowTracks(FindParent())
  local parts = {}
  for _, tr in ipairs(rows) do
    local row = BuildRow(tr)
    parts[#parts + 1] = string.format(
      '{"name":%q,"guid":%q,"note":%d,"samples":%d,"mode":%d}',
      row.name, r.GetTrackGUID(tr), row.padnote or 0, row.samples, row.mode or 0)
  end
  r.SetProjExtState(0, 'PADLAB', 'state', '[' .. table.concat(parts, ',') .. ']')
end

local function NextFreePadNote()
  local used = {}
  for _, tr in ipairs(GetRowTracks(FindParent())) do
    local row = BuildRow(tr)
    if row.padnote then used[row.padnote] = true end
  end
  local n = BASE_NOTE
  while used[n] do n = n + 1 end
  return n
end

-- each pad track listens to all MIDI inputs itself (monitor only, never
-- records); its Router JSFX filters to just its own pad note
local function ArmChild(tr)
  r.SetMediaTrackInfo_Value(tr, 'I_RECINPUT', 4096 + (63 << 5))
  r.SetMediaTrackInfo_Value(tr, 'I_RECARM', 1)
  r.SetMediaTrackInfo_Value(tr, 'I_RECMON', 1)
  r.SetMediaTrackInfo_Value(tr, 'I_RECMODE', 2)
end

-- repair older projects: arm every row + drop the parent->child MIDI sends
-- (dead on some setups, and a double-trigger risk on others)
local function FixRouting()
  local parent = FindParent()
  if not parent then return end
  for _, tr in ipairs(GetRowTracks(parent)) do
    ArmChild(tr)
    for s = r.GetTrackNumSends(parent, 0) - 1, 0, -1 do
      local dest = r.GetTrackSendInfo_Value(parent, 0, s, 'P_DESTTRACK')
      if dest == tr or tostring(dest) == tostring(tr) then
        r.RemoveTrackSend(parent, 0, s)
      end
    end
  end
  InvalidateRows()
end

local function CreateRow(name)
  local parent = EnsureParent()
  local rows = GetRowTracks(parent)
  local insertIdx = TrackIndex(parent) + 1 + #rows
  local padnote = NextFreePadNote()
  r.InsertTrackAtIndex(insertIdx, true)
  local tr = r.GetTrack(0, insertIdx)
  r.GetSetMediaTrackInfo_String(tr, 'P_NAME', 'PL: ' .. name, true)
  r.GetSetMediaTrackInfo_String(tr, 'P_EXT:PADLAB', 'row', true)
  ArmChild(tr)
  local fxRep = AddJSFX(tr, JS_REPEAT)
  local fxRoute = AddJSFX(tr, JS_ROUTER)
  if fxRoute >= 0 then r.TrackFX_SetParam(tr, fxRoute, 2, padnote) end
  -- new rows inherit the saved hardware mappings
  if fxRep >= 0 then
    local function stored(key, def)
      return tonumber(r.GetExtState('PADLAB', key)) or def
    end
    r.TrackFX_SetParam(tr, fxRep, P_RPT_MAPRPT, stored('map_repeat', -1))
    r.TrackFX_SetParam(tr, fxRep, P_RPT_MAPMODE, stored('map_rptmode', 0))
    r.TrackFX_SetParam(tr, fxRep, P_RPT_MAPRATE, stored('map_rate', -1))
    r.TrackFX_SetParam(tr, fxRep, P_RPT_MAPRATEDN, stored('map_ratedn', -1))
  end
  FixFolder(parent)
  return tr
end

local function AddSampleToRow(row, file)
  if row.samples >= MAX_SAMPLES then return false end
  local tr = row.track
  local fx = AddFXAtEnd(tr, 'ReaSamplomatic5000')
  if fx < 0 then return false end
  r.TrackFX_SetNamedConfigParm(tr, fx, 'FILE0', file)
  r.TrackFX_SetNamedConfigParm(tr, fx, 'DONE', '')
  local internal = row.samples -- internal note = sample index
  local pi
  pi = ParamIndexByName(tr, fx, 'note range start'); if pi then r.TrackFX_SetParamNormalized(tr, fx, pi, internal / 127) end
  pi = ParamIndexByName(tr, fx, 'note range end');   if pi then r.TrackFX_SetParamNormalized(tr, fx, pi, internal / 127) end
  pi = ParamIndexByName(tr, fx, 'minimum velocity'); if pi then r.TrackFX_SetParamNormalized(tr, fx, pi, 0) end -- velocity dynamics on
  pi = ParamIndexByName(tr, fx, 'obey note');        if pi then r.TrackFX_SetParamNormalized(tr, fx, pi, 0) end -- one-shot
  row.samples = row.samples + 1
  if row.fxRouter >= 0 then r.TrackFX_SetParam(tr, row.fxRouter, 1, row.samples) end
  return true
end

local function SetRowDynamics(row, on)
  for _, fx in ipairs(row.rs5k) do
    local pi = ParamIndexByName(row.track, fx, 'minimum velocity')
    if pi then r.TrackFX_SetParamNormalized(row.track, fx, pi, on and 0 or 1) end
  end
end

local function SetRowChoke(row, on)
  for _, fx in ipairs(row.rs5k) do
    local pi = ParamIndexByName(row.track, fx, 'obey note')
    if pi then r.TrackFX_SetParamNormalized(row.track, fx, pi, on and 1 or 0) end
  end
end

local function DeleteRow(row)
  local parent = FindParent()
  r.Undo_BeginBlock2(0)
  r.DeleteTrack(row.track)
  FixFolder(parent)
  SaveState()
  r.Undo_EndBlock2(0, 'PadLab: remove row', -1)
  InvalidateRows()
end

------------------------------------------------------------- file gathering

local function CollectAudioFiles(dir, out, depth)
  out = out or {}
  local i = 0
  while true do
    local fn = r.EnumerateFiles(dir, i)
    if not fn then break end
    local ext = fn:match('%.([^.]+)$')
    if ext and AUDIO_EXT[ext:lower()] then out[#out + 1] = dir .. sep .. fn end
    i = i + 1
  end
  if (depth or 0) < 3 then
    local d = 0
    while true do
      local sub = r.EnumerateSubdirectories(dir, d)
      if not sub then break end
      CollectAudioFiles(dir .. sep .. sub, out, (depth or 0) + 1)
      d = d + 1
    end
  end
  return out
end

local function TakeRandom(list, n)
  if n >= #list then return list end
  for i = 1, n do
    local j = math.random(i, #list)
    list[i], list[j] = list[j], list[i]
  end
  local out = {}
  for i = 1, n do out[i] = list[i] end
  return out
end

local function AskCount(total)
  local default = math.min(16, total, MAX_SAMPLES)
  local ok, csv = r.GetUserInputs('PadLab: add samples', 1,
    'Load how many? (random pick of ' .. total .. '),extrawidth=60', tostring(default))
  if not ok then return nil end
  local n = math.floor(tonumber(csv) or 0)
  if n <= 0 then n = math.min(total, MAX_SAMPLES) end
  return math.min(n, total, MAX_SAMPLES)
end

local function BrowseFolder()
  if r.JS_Dialog_BrowseForFolder then
    local rv, path = r.JS_Dialog_BrowseForFolder('Pick a sample folder', '')
    if rv == 1 and path and path ~= '' then return path end
    return nil
  end
  local ok, csv = r.GetUserInputs('PadLab: folder path', 1, 'Folder:,extrawidth=250', '')
  if ok and csv ~= '' then return csv end
end

local function BrowseFiles()
  if r.JS_Dialog_BrowseForOpenFiles then
    local rv, list = r.JS_Dialog_BrowseForOpenFiles('Pick samples', '', '',
      'Audio files\0*.wav;*.flac;*.aif;*.aiff;*.ogg;*.mp3;*.wv\0All files\0*.*\0\0', true)
    if (rv or 0) > 0 and list and list ~= '' then
      local parts = {}
      for s in list:gmatch('[^\0]+') do parts[#parts + 1] = s end
      if #parts == 0 then return nil end
      if #parts == 1 then return { parts[1] } end
      -- multi-select returns: folder \0 file1 \0 file2 ...
      if r.file_exists(parts[1] .. sep .. parts[2]) then
        local out = {}
        for i = 2, #parts do out[#out + 1] = parts[1] .. sep .. parts[i] end
        return out
      end
      return parts
    end
    return nil
  end
  local ok, fn = r.GetUserFileNameForRead('', 'Pick a sample', '')
  if ok then return { fn } end
end

------------------------------------------------------- media explorer DBs

local function GetMediaDBs()
  local dbs = {}
  local f = io.open(resource .. sep .. 'reaper.ini', 'r')
  if not f then return dbs end
  local in_sec, files, titles = false, {}, {}
  for line in f:lines() do
    local s = line:match('^%[(.-)%]')
    if s then in_sec = (s == 'reaper_explorer') end
    if in_sec then
      local n, v = line:match('^Shortcut(%d+)=(.+)$')
      if n and v and v:match('%.ReaperFileList$') then files[n] = v end
      local tn, tv = line:match('^ShortcutT(%d+)=(.+)$')
      if tn then titles[tn] = tv end
    end
  end
  f:close()
  for n, file in pairs(files) do
    local t = (titles[n] or file):gsub('^DB:%s*', '')
    dbs[#dbs + 1] = { file = resource .. sep .. 'MediaDB' .. sep .. file, name = t }
  end
  table.sort(dbs, function(a, b) return a.name:lower() < b.name:lower() end)
  return dbs
end

local function ReadDBFiles(dbfile)
  local files = {}
  local f = io.open(dbfile, 'r')
  if not f then return files end
  for line in f:lines() do
    local p = line:match('^FILE%s+"(.-)"')
    if p then
      local ext = p:match('%.([^.]+)$')
      if ext and AUDIO_EXT[ext:lower()] then files[#files + 1] = p end
    end
  end
  f:close()
  return files
end

--------------------------------------------------------------- add actions

-- src ('folder:<path>' or 'db:<file>') is remembered so the row can re-roll
-- a fresh random pick later
local function CreateRowWithFiles(name, files, src, wantN)
  if #files == 0 then r.MB('No audio files found.', 'PadLab', 0) return end
  r.Undo_BeginBlock2(0)
  r.PreventUIRefresh(1)
  local tr = CreateRow(name)
  if src then
    r.GetSetMediaTrackInfo_String(tr, 'P_EXT:PADLAB_SRC', src, true)
    r.GetSetMediaTrackInfo_String(tr, 'P_EXT:PADLAB_SRCN', tostring(wantN or #files), true)
  end
  local row = BuildRow(tr)
  for _, f in ipairs(files) do
    if not AddSampleToRow(row, f) then break end
  end
  SaveState()
  r.PreventUIRefresh(-1)
  r.Undo_EndBlock2(0, 'PadLab: add row "' .. name .. '"', -1)
  InvalidateRows()
end

-- throw out the row's samples and load a fresh random pick from its source
local function RerollRow(row)
  if not row.src then return end
  local _, nstr = r.GetSetMediaTrackInfo_String(row.track, 'P_EXT:PADLAB_SRCN', '', false)
  local n = math.min(tonumber(nstr) or 16, MAX_SAMPLES)
  local kind, path = row.src:match('^(%w+):(.+)$')
  local files = {}
  if kind == 'folder' then
    files = CollectAudioFiles(path)
  elseif kind == 'db' then
    files = ReadDBFiles(path)
  end
  if #files == 0 then
    r.MB('Source is empty or missing:\n' .. tostring(path), 'PadLab', 0)
    return
  end
  local picked, keep = TakeRandom(files, n), {}
  for _, f in ipairs(picked) do
    if r.file_exists(f) then keep[#keep + 1] = f end
  end
  if #keep == 0 then return end
  r.Undo_BeginBlock2(0)
  r.PreventUIRefresh(1)
  for i = #row.rs5k, 1, -1 do r.TrackFX_Delete(row.track, row.rs5k[i]) end
  row.rs5k, row.samples = {}, 0
  for _, f in ipairs(keep) do
    if not AddSampleToRow(row, f) then break end
  end
  SaveState()
  r.PreventUIRefresh(-1)
  r.Undo_EndBlock2(0, 'PadLab: re-roll "' .. row.name .. '"', -1)
  InvalidateRows()
end

local function AppendFilesToRow(row, files)
  r.Undo_BeginBlock2(0)
  r.PreventUIRefresh(1)
  for _, f in ipairs(files) do
    if not AddSampleToRow(row, f) then break end
  end
  SaveState()
  r.PreventUIRefresh(-1)
  r.Undo_EndBlock2(0, 'PadLab: add samples to "' .. row.name .. '"', -1)
  InvalidateRows()
end

local function AddFromFolder()
  local dir = BrowseFolder()
  if not dir then return end
  dir = dir:gsub('[/\\]+$', '')
  local files = CollectAudioFiles(dir)
  if #files == 0 then r.MB('No audio files found in:\n' .. dir, 'PadLab', 0) return end
  local n = AskCount(#files)
  if not n then return end
  local name = dir:match('([^/\\]+)$') or 'Pads'
  CreateRowWithFiles(name, TakeRandom(files, n), 'folder:' .. dir, n)
end

local function AddFromFiles(row)
  local files = BrowseFiles()
  if not files or #files == 0 then return end
  if row then
    AppendFilesToRow(row, files)
  else
    local name = files[1]:match('([^/\\]+)%.[^.]+$') or 'Pads'
    if #files > 1 then
      name = files[1]:match('([^/\\]+)[/\\][^/\\]+$') or name
    end
    CreateRowWithFiles(name, files)
  end
end

local function AddFromDB(db)
  local files = ReadDBFiles(db.file)
  if #files == 0 then r.MB('Database "' .. db.name .. '" has no audio entries.', 'PadLab', 0) return end
  local n = AskCount(#files)
  if not n then return end
  local picked = TakeRandom(files, n)
  local existing = {}
  for _, f in ipairs(picked) do
    if r.file_exists(f) then existing[#existing + 1] = f end
  end
  if #existing == 0 then r.MB('None of the picked files exist on disk anymore.\nRe-scan the database in Media Explorer.', 'PadLab', 0) return end
  CreateRowWithFiles(db.name, existing, 'db:' .. db.file, n)
end

------------------------------------------------------------------ misc GUI

local NOTE_NAMES = { 'C', 'C#', 'D', 'D#', 'E', 'F', 'F#', 'G', 'G#', 'A', 'A#', 'B' }
local function NoteName(n)
  if not n then return '?' end
  return NOTE_NAMES[(n % 12) + 1] .. tostring(math.floor(n / 12) - 1)
end

local function ApplyRepeatAll(rows, on)
  for _, row in ipairs(rows) do
    if row.fxRepeat >= 0 then r.TrackFX_SetParam(row.track, row.fxRepeat, 0, on and 1 or 0) end
  end
end

local function ApplyRateAll(rows, rate)
  for _, row in ipairs(rows) do
    if row.fxRepeat >= 0 then r.TrackFX_SetParam(row.track, row.fxRepeat, 1, rate) end
  end
end

--------------------------------------------------------------- MIDI learn

local gmemOK = r.gmem_attach ~= nil
if gmemOK then r.gmem_attach('PadLab') end
local lastGmemCount = gmemOK and r.gmem_read(0) or -1

-- learn = { target = 'padnote'|'repeat'|'rate'|'ratedn', track=?, fxRouter=?, name=? }
local learn = nil

local MAPS = {
  ['repeat'] = { key = 'map_repeat', param = P_RPT_MAPRPT,    label = 'Repeat' },
  rate       = { key = 'map_rate',   param = P_RPT_MAPRATE,   label = 'Rate' },
  ratedn     = { key = 'map_ratedn', param = P_RPT_MAPRATEDN, label = 'Rate down' },
}

local function ApplyMapToAll(param, value)
  for _, tr in ipairs(GetRowTracks(FindParent())) do
    local row = BuildRow(tr)
    if row.fxRepeat >= 0 then r.TrackFX_SetParam(tr, row.fxRepeat, param, value) end
  end
  InvalidateRows()
end

-- returns true when the learn is done (false = keep listening)
local function ApplyLearn(l, isnote, num)
  if l.target == 'padnote' then
    if not isnote then return false end -- pad notes are notes; ignore CCs, keep listening
    if r.ValidatePtr2(0, l.track, 'MediaTrack*') and l.fxRouter and l.fxRouter >= 0 then
      r.TrackFX_SetParam(l.track, l.fxRouter, 2, num)
      SaveState()
      InvalidateRows()
    end
    return true
  end
  local m = MAPS[l.target]
  if m then
    local enc = isnote and (128 + num) or num
    r.SetExtState('PADLAB', m.key, tostring(enc), true)
    ApplyMapToAll(m.param, enc)
  end
  return true
end

local function MapDesc(key)
  local v = tonumber(r.GetExtState('PADLAB', key)) or -1
  if v < 0 then return '(not mapped)' end
  if v < 128 then return 'CC ' .. math.floor(v) end
  return 'Note ' .. math.floor(v - 128)
end

---------------------------------------------------------------------- GUI

local ctx = r.ImGui_CreateContext('PadLab')
local DBS = GetMediaDBs()
local masterOn = false
local masterRate = 3
local lastEff = false
local doctorText = nil

local RATE_KEYS = {}
for k = 1, 8 do
  local fn = r['ImGui_Key_' .. k]
  if fn then RATE_KEYS[k] = fn() end
end
local KEY_R = r.ImGui_Key_R and r.ImGui_Key_R() or nil
local hasDnD = r.ImGui_AcceptDragDropPayloadFiles ~= nil

------------------------------------------------------------- drag and drop

-- dropped paths can be files or folders; folders get scanned
local function ExpandDropped(paths)
  local files = {}
  for _, p in ipairs(paths) do
    if r.file_exists(p) then
      local ext = p:match('%.([^.]+)$')
      if ext and AUDIO_EXT[ext:lower()] then files[#files + 1] = p end
    else
      CollectAudioFiles(p, files) -- not a file -> assume directory
    end
  end
  return files
end

local function HandleDrop(paths, row)
  local files = ExpandDropped(paths)
  if #files == 0 then
    r.MB('Nothing droppable found (audio files or folders containing them).', 'PadLab', 0)
    return
  end
  if #files > MAX_SAMPLES then
    local n = AskCount(#files)
    if not n then return end
    files = TakeRandom(files, n)
  end
  if row then
    AppendFilesToRow(row, files)
  else
    local name, src
    if #paths == 1 and not r.file_exists(paths[1]) then
      local dir = paths[1]:gsub('[/\\]+$', '')
      name = dir:match('([^/\\]+)$') or 'Pads' -- folder name
      src = 'folder:' .. dir
    elseif #files == 1 then
      name = files[1]:match('([^/\\]+)%.[^.]+$') or 'Pads'
    else
      name = files[1]:match('([^/\\]+)[/\\][^/\\]+$') or 'Pads'
    end
    CreateRowWithFiles(name, files, src, #files)
  end
end

--------------------------------------------------------------------- doctor

local function BuildDoctorReport()
  local out = {}
  local function add(s) out[#out + 1] = s end
  add('PadLab doctor  |  REAPER ' .. r.GetAppVersion())
  local parent = FindParent()
  if not parent then
    add('Parent track: NOT FOUND (add a pad to create it)')
    return table.concat(out, '\n')
  end
  add(('Parent: track %d  recinput=%d  arm=%d  monitor=%d  recmode=%d'):format(
    TrackIndex(parent) + 1,
    r.GetMediaTrackInfo_Value(parent, 'I_RECINPUT'),
    r.GetMediaTrackInfo_Value(parent, 'I_RECARM'),
    r.GetMediaTrackInfo_Value(parent, 'I_RECMON'),
    r.GetMediaTrackInfo_Value(parent, 'I_RECMODE')))
  for fx = 0, r.TrackFX_GetCount(parent) - 1 do
    local _, dn = r.TrackFX_GetFXName(parent, fx, '')
    add(('  parent fx%d: %s'):format(fx, dn or '?'))
  end
  add(('Parent MIDI sends remaining: %d'):format(r.GetTrackNumSends(parent, 0)))
  for i, tr in ipairs(GetRowTracks(parent)) do
    local _, name = r.GetTrackName(tr)
    add(('Row %d: "%s"  recinput=%d  arm=%d  monitor=%d'):format(
      i, name or '?',
      r.GetMediaTrackInfo_Value(tr, 'I_RECINPUT'),
      r.GetMediaTrackInfo_Value(tr, 'I_RECARM'),
      r.GetMediaTrackInfo_Value(tr, 'I_RECMON')))
    for fx = 0, r.TrackFX_GetCount(tr) - 1 do
      local _, dn = r.TrackFX_GetFXName(tr, fx, '')
      local _, ident = r.TrackFX_GetNamedConfigParm(tr, fx, 'fx_ident')
      local _, file = r.TrackFX_GetNamedConfigParm(tr, fx, 'FILE0')
      local extra = (file and file ~= '') and ('  sample=' .. (file:match('([^/\\]+)$') or file)) or ''
      add(('  fx%d: "%s"  ident="%s"%s'):format(fx, dn or '?', ident or '?', extra))
    end
  end
  return table.concat(out, '\n')
end

-- attach to the last drawn item; row = nil makes a new pad from the drop
local function DropTarget(row)
  if not hasDnD then return end
  if not r.ImGui_BeginDragDropTarget(ctx) then return end
  local rv, count = r.ImGui_AcceptDragDropPayloadFiles(ctx)
  if rv then
    local paths = {}
    for i = 0, (count or 1) - 1 do
      local ok, file = r.ImGui_GetDragDropPayloadFile(ctx, i)
      if ok and file and file ~= '' then paths[#paths + 1] = file end
    end
    if #paths > 0 then HandleDrop(paths, row) end
  end
  r.ImGui_EndDragDropTarget(ctx)
end

local function Frame()
  local rows = Rows()

  -- ============ MIDI learn polling ============
  if gmemOK then
    local c = r.gmem_read(0)
    if c ~= lastGmemCount then
      lastGmemCount = c
      if learn then
        local isnote = r.gmem_read(1) >= 0.5
        local num = math.floor(r.gmem_read(2) + 0.5)
        if ApplyLearn(learn, isnote, num) then learn = nil end
      end
    end
  end
  if learn and r.ImGui_IsKeyPressed(ctx, r.ImGui_Key_Escape()) then learn = nil end

  -- ============ header ============
  if r.ImGui_Button(ctx, '+ Folder') then AddFromFolder() end
  r.ImGui_SameLine(ctx)
  if r.ImGui_Button(ctx, '+ Files') then AddFromFiles(nil) end
  r.ImGui_SameLine(ctx)
  if r.ImGui_Button(ctx, '+ Media DB') then r.ImGui_OpenPopup(ctx, 'dbpopup') end
  if r.ImGui_BeginPopup(ctx, 'dbpopup') then
    if #DBS == 0 then r.ImGui_Text(ctx, 'No Media Explorer databases found') end
    for _, db in ipairs(DBS) do
      if r.ImGui_MenuItem(ctx, db.name) then AddFromDB(db) end
    end
    r.ImGui_Separator(ctx)
    if r.ImGui_MenuItem(ctx, 'Refresh list') then DBS = GetMediaDBs() end
    r.ImGui_EndPopup(ctx)
  end

  r.ImGui_SameLine(ctx)
  if r.ImGui_Button(ctx, 'MIDI Map') then r.ImGui_OpenPopup(ctx, 'midimap') end
  if r.ImGui_BeginPopup(ctx, 'midimap') then
    if not gmemOK then
      r.ImGui_Text(ctx, 'MIDI learn needs a newer REAPER (gmem API missing).')
    else
      r.ImGui_Text(ctx, 'Hardware buttons (applies to all pads):')
      r.ImGui_Separator(ctx)
      for _, target in ipairs({ 'repeat', 'rate', 'ratedn' }) do
        local m = MAPS[target]
        r.ImGui_Text(ctx, string.format('%-10s %s', m.label, MapDesc(m.key)))
        r.ImGui_SameLine(ctx, 200)
        if r.ImGui_SmallButton(ctx, 'Learn##' .. m.key) then learn = { target = target } end
        r.ImGui_SameLine(ctx)
        if r.ImGui_SmallButton(ctx, 'Clear##' .. m.key) then
          r.SetExtState('PADLAB', m.key, '-1', true)
          ApplyMapToAll(m.param, -1)
        end
      end
      r.ImGui_Separator(ctx)
      r.ImGui_SetNextItemWidth(ctx, 130)
      local mv = math.floor(tonumber(r.GetExtState('PADLAB', 'map_rptmode')) or 0)
      local mc2, nv = r.ImGui_Combo(ctx, 'Repeat button', mv, 'Momentary (hold)\0Toggle\0')
      if mc2 then
        r.SetExtState('PADLAB', 'map_rptmode', tostring(nv), true)
        ApplyMapToAll(P_RPT_MAPMODE, nv)
      end
      r.ImGui_TextDisabled(ctx, 'Rate mapped to a CC knob = absolute speed sweep.')
      r.ImGui_TextDisabled(ctx, 'Rate mapped to a note/button = steps faster; use')
      r.ImGui_TextDisabled(ctx, '"Rate down" for a second button that steps slower.')
      r.ImGui_TextDisabled(ctx, 'Pad notes: right-click a pad > Learn pad note.')
    end
    r.ImGui_EndPopup(ctx)
  end

  r.ImGui_SameLine(ctx)
  if r.ImGui_Button(ctx, 'Doctor') then
    doctorText = BuildDoctorReport()
    r.ImGui_OpenPopup(ctx, 'doctor')
  end
  if r.ImGui_BeginPopup(ctx, 'doctor') then
    if r.ImGui_Button(ctx, 'Fix MIDI routing (arm pad tracks)') then
      FixRouting()
      doctorText = BuildDoctorReport()
    end
    r.ImGui_SameLine(ctx)
    if r.ImGui_Button(ctx, 'Copy report') then
      r.ImGui_SetClipboardText(ctx, doctorText or '')
    end
    r.ImGui_Separator(ctx)
    if r.ImGui_BeginChild(ctx, 'doctxt', 600, 280) then
      r.ImGui_Text(ctx, doctorText or '')
      r.ImGui_EndChild(ctx)
    end
    r.ImGui_EndPopup(ctx)
  end

  local chg
  chg, masterOn = r.ImGui_Checkbox(ctx, 'REPEAT', masterOn)
  local rHeld = KEY_R and r.ImGui_IsKeyDown(ctx, KEY_R) or false
  local eff = masterOn or rHeld
  if chg or eff ~= lastEff then
    ApplyRepeatAll(rows, eff)
    lastEff = eff
    InvalidateRows()
  end
  r.ImGui_SameLine(ctx)
  r.ImGui_SetNextItemWidth(ctx, 76)
  chg, masterRate = r.ImGui_Combo(ctx, '##mrate', masterRate, RATE_STR)
  if chg then ApplyRateAll(rows, masterRate); InvalidateRows() end
  for k = 1, 8 do
    if RATE_KEYS[k] and r.ImGui_IsKeyPressed(ctx, RATE_KEYS[k]) then
      masterRate = k - 1
      ApplyRateAll(rows, masterRate)
      InvalidateRows()
    end
  end

  r.ImGui_Separator(ctx)

  if learn then
    local what = learn.target == 'padnote'
      and ('pad note for "' .. (learn.name or '?') .. '" — hit a pad on your controller')
      or ('the ' .. (MAPS[learn.target] and MAPS[learn.target].label or learn.target) .. ' control — press a button or move a knob')
    r.ImGui_TextColored(ctx, 0xFFB030FF, 'MIDI LEARN: ' .. what .. '   (Esc cancels)')
    r.ImGui_Separator(ctx)
  end

  -- ============ rows ============
  if #rows == 0 then
    r.ImGui_Text(ctx, 'No pads yet. Add a Folder, Files, or a Media Explorer DB above.')
    r.ImGui_Text(ctx, 'Each source becomes one pad row (a track under the "PadLab" folder).')
  end

  for i, row in ipairs(rows) do
    r.ImGui_PushID(ctx, i)

    -- pad button (hold to play; repeat JSFX rolls it while held)
    if row.rptOn then
      r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Button(), 0xB03828FF)
    else
      r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Button(), 0x3D6B4FFF)
    end
    r.ImGui_Button(ctx, NoteName(row.padnote) .. '##pad', 44, 24)
    r.ImGui_PopStyleColor(ctx)
    if r.ImGui_IsItemActivated(ctx) then r.StuffMIDIMessage(0, 0x90, row.padnote or BASE_NOTE, PAD_VEL) end
    if r.ImGui_IsItemDeactivated(ctx) then r.StuffMIDIMessage(0, 0x80, row.padnote or BASE_NOTE, 0) end

    -- right-click pad: extras
    if r.ImGui_BeginPopupContextItem(ctx, 'padctx') then
      r.ImGui_Text(ctx, row.name)
      r.ImGui_Separator(ctx)
      if row.fxRouter >= 0 then
        r.ImGui_SetNextItemWidth(ctx, 140)
        local hc, hv = r.ImGui_SliderInt(ctx, 'Vel humanize', row.humvel or 0, 0, 64)
        if hc then r.TrackFX_SetParam(row.track, row.fxRouter, 3, hv); InvalidateRows() end
        r.ImGui_SetNextItemWidth(ctx, 140)
        local pc, pv = r.ImGui_SliderInt(ctx, 'Pitch humanize (cents)', row.humpitch or 0, 0, 100)
        if pc then r.TrackFX_SetParam(row.track, row.fxRouter, 4, pv); InvalidateRows() end
      end
      if row.fxRepeat >= 0 then
        r.ImGui_SetNextItemWidth(ctx, 140)
        local gc, gv = r.ImGui_SliderInt(ctx, 'Repeat gate %', row.gate or 60, 5, 100)
        if gc then r.TrackFX_SetParam(row.track, row.fxRepeat, 2, gv); InvalidateRows() end
      end
      local cc, cv = r.ImGui_Checkbox(ctx, 'Choke (obey note-offs)', row.choke or false)
      if cc then SetRowChoke(row, cv); InvalidateRows() end
      r.ImGui_Separator(ctx)
      if row.src and r.ImGui_MenuItem(ctx, 'Re-roll: new random samples from source') then
        RerollRow(row)
      end
      if r.ImGui_MenuItem(ctx, 'Learn pad note (hit your controller)') then
        learn = { target = 'padnote', track = row.track, fxRouter = row.fxRouter, name = row.name }
      end
      if r.ImGui_MenuItem(ctx, 'Show track FX chain') then
        r.TrackFX_Show(row.track, 0, 1)
      end
      if row.samples > 0 then
        r.ImGui_Separator(ctx)
        r.ImGui_TextDisabled(ctx, 'Loaded samples:')
        if r.ImGui_BeginChild(ctx, 'smpllist', 280, math.min(row.samples, 12) * 17 + 6) then
          for _, fx in ipairs(row.rs5k) do
            local ok, file = r.TrackFX_GetNamedConfigParm(row.track, fx, 'FILE0')
            r.ImGui_Text(ctx, (ok and file and file:match('([^/\\]+)$')) or '(?)')
          end
          r.ImGui_EndChild(ctx)
        end
      end
      r.ImGui_EndPopup(ctx)
    end

    -- name + count
    r.ImGui_SameLine(ctx, 58)
    local label = row.name
    if #label > 20 then label = label:sub(1, 19) .. '…' end
    r.ImGui_Text(ctx, string.format('%-21s [%d]', label, row.samples))
    DropTarget(row) -- drag files/folders onto the name to add them to this pad
    if r.ImGui_IsItemHovered(ctx) then r.ImGui_SetTooltip(ctx, row.name .. '  (' .. row.samples .. ' samples, pad note ' .. tostring(row.padnote) .. ')\nDrop audio files here to add them to this pad') end

    -- mode
    r.ImGui_SameLine(ctx, 268)
    r.ImGui_SetNextItemWidth(ctx, 108)
    if row.fxRouter >= 0 then
      local mc, mv = r.ImGui_Combo(ctx, '##mode', row.mode or 0, MODE_STR)
      if mc then r.TrackFX_SetParam(row.track, row.fxRouter, 0, mv); InvalidateRows() end
    else
      r.ImGui_Text(ctx, '(no router)')
    end

    -- dynamics
    r.ImGui_SameLine(ctx, 384)
    local dc, dv = r.ImGui_Checkbox(ctx, 'Dyn', row.dyn or false)
    if dc then SetRowDynamics(row, dv); InvalidateRows() end

    -- repeat per-row
    r.ImGui_SameLine(ctx, 434)
    if row.fxRepeat >= 0 then
      local rc, rv2 = r.ImGui_Checkbox(ctx, 'Rpt', row.rptOn or false)
      if rc then r.TrackFX_SetParam(row.track, row.fxRepeat, 0, rv2 and 1 or 0); InvalidateRows() end
      r.ImGui_SameLine(ctx)
      r.ImGui_SetNextItemWidth(ctx, 66)
      local rrc, rrv = r.ImGui_Combo(ctx, '##rate', row.rptRate or 3, RATE_STR)
      if rrc then r.TrackFX_SetParam(row.track, row.fxRepeat, 1, rrv); InvalidateRows() end
    end

    -- mute/solo
    r.ImGui_SameLine(ctx, 566)
    if row.mute then r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Button(), 0xC03030FF) end
    if r.ImGui_SmallButton(ctx, 'M') then
      r.SetMediaTrackInfo_Value(row.track, 'B_MUTE', row.mute and 0 or 1)
      InvalidateRows()
    end
    if row.mute then r.ImGui_PopStyleColor(ctx) end
    r.ImGui_SameLine(ctx)
    if row.solo then r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Button(), 0xC0A030FF) end
    if r.ImGui_SmallButton(ctx, 'S') then
      r.SetMediaTrackInfo_Value(row.track, 'I_SOLO', row.solo and 0 or 2)
      InvalidateRows()
    end
    if row.solo then r.ImGui_PopStyleColor(ctx) end

    -- add samples / routing / delete
    r.ImGui_SameLine(ctx, 622)
    if r.ImGui_SmallButton(ctx, '+') then AddFromFiles(row) end
    if r.ImGui_IsItemHovered(ctx) then r.ImGui_SetTooltip(ctx, 'Add more samples to this pad') end
    r.ImGui_SameLine(ctx)
    if r.ImGui_SmallButton(ctx, 'Route') then
      r.SetOnlyTrackSelected(row.track)
      r.Main_OnCommand(40293, 0) -- track routing dialog: sends, sidechain, hardware outs
    end
    if r.ImGui_IsItemHovered(ctx) then r.ImGui_SetTooltip(ctx, 'Open REAPER routing for this pad\n(sends, buses, sidechain)') end
    r.ImGui_SameLine(ctx)
    if r.ImGui_SmallButton(ctx, 'X') then DeleteRow(row) end

    r.ImGui_PopID(ctx)
  end

  r.ImGui_Spacing(ctx)
  if r.ImGui_Button(ctx,
    hasDnD and 'Drop samples or folders here for a new pad   (or click to browse)'
    or 'Click to add samples as a new pad', -1, 26) then
    AddFromFiles(nil)
  end
  DropTarget(nil)

  r.ImGui_Separator(ctx)
  r.ImGui_TextDisabled(ctx, 'Drag files onto a pad name to stack them  |  hold R = repeat all  |  keys 1-8 = rate  |  right-click pad = more')
end

local function Main()
  r.ImGui_SetNextWindowSize(ctx, 730, 300, r.ImGui_Cond_FirstUseEver())
  local visible, open = r.ImGui_Begin(ctx, 'PadLab', true)
  if visible then
    local ok, err = pcall(Frame)
    if not ok then
      r.ImGui_Text(ctx, 'PadLab error (still running):')
      r.ImGui_Text(ctx, tostring(err))
    end
    r.ImGui_End(ctx)
  end
  if open then r.defer(Main) end
end

FixRouting() -- repair rows made by older versions (idempotent, no-op when fine)
r.defer(Main)
