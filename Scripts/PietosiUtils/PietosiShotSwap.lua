-- @description PietosiShotSwap - reroll every item's sample from a Media Explorer database
-- @version 0.1.0
-- @author pie
-- @provides [main=main] .
-- @about
--   Pick one of your Media Explorer databases, hit ROLL TRACK: every item on
--   the selected track gets its sample replaced by a random file from that
--   database, so every hit is unique. Positions, lengths, rates and pitches
--   are untouched (optionally fit item length to the new sample). "One-shots
--   only" filters the database by file length using the metadata already in
--   the .ReaperFileList, so loops never sneak in. "No repeats" deals samples
--   like a shuffled deck - nothing repeats until the pool runs out.
--   One undo point per roll: don't like it? Ctrl+Z and roll again.

local r = reaper

if not r.ImGui_CreateContext then
  r.MB('PietosiShotSwap needs the ReaImGui extension.\n\nInstall via ReaPack: Extensions > ReaPack > Browse packages > "ReaImGui".', 'PietosiShotSwap', 0)
  return
end
if not r.APIExists('BR_SetTakeSourceFromFile') then
  r.MB('PietosiShotSwap needs the SWS extension (BR_SetTakeSourceFromFile).', 'PietosiShotSwap', 0)
  return
end

local sep = package.config:sub(1, 1)
local resource = r.GetResourcePath()

------------------------------------------------------------------- settings

local function boolSetting(key, def)
  local v = r.GetExtState('PietosiShotSwap', key)
  if v == '' then return def end
  return v == '1'
end

local db_want  = r.GetExtState('PietosiShotSwap', 'db') -- last used DB, by name
local max_len  = tonumber(r.GetExtState('PietosiShotSwap', 'maxlen')) or 2.0
local oneshot  = boolSetting('oneshot', true)
local unique   = boolSetting('unique', true)
local fit_len  = boolSetting('fitlen', false)
local skip_sil = boolSetting('skipsil', true) -- start offset jumps past leading silence

local function save()
  r.SetExtState('PietosiShotSwap', 'db', db_want or '', true)
  r.SetExtState('PietosiShotSwap', 'maxlen', tostring(max_len), true)
  r.SetExtState('PietosiShotSwap', 'oneshot', oneshot and '1' or '0', true)
  r.SetExtState('PietosiShotSwap', 'unique', unique and '1' or '0', true)
  r.SetExtState('PietosiShotSwap', 'fitlen', fit_len and '1' or '0', true)
  r.SetExtState('PietosiShotSwap', 'skipsil', skip_sil and '1' or '0', true)
end

--------------------------------------------------------------- database list

local AUDIO_EXT = {
  wav = true, aif = true, aiff = true, flac = true, mp3 = true, ogg = true,
  wv = true, m4a = true, mp4 = true, opus = true, caf = true, w64 = true,
}

-- Media Explorer databases live in <resource>/MediaDB/*.ReaperFileList; their
-- display names are the ShortcutN/ShortcutTN pairs in reaper.ini's
-- [reaper_explorer] section ("DB: kick" etc). Fall back to raw filenames.
local function listDatabases()
  local byidx = {}
  local ini = io.open(resource .. sep .. 'reaper.ini', 'rb')
  if ini then
    local insec = false
    for rawline in ini:lines() do
      local line = rawline:gsub('%s+$', '')
      local sec = line:match('^%[(.-)%]')
      if sec then insec = (sec == 'reaper_explorer') end
      if insec then
        local i, v = line:match('^Shortcut(%d+)=(.+)')
        if i then
          byidx[tonumber(i)] = byidx[tonumber(i)] or {}
          byidx[tonumber(i)].file = v
        else
          local ti, tv = line:match('^ShortcutT(%d+)=(.+)')
          if ti then
            byidx[tonumber(ti)] = byidx[tonumber(ti)] or {}
            byidx[tonumber(ti)].name = tv
          end
        end
      end
    end
    ini:close()
  end

  local dbs, seen = {}, {}
  for _, e in pairs(byidx) do
    local f = e.file
    if f and f:lower():match('%.reaperfilelist$') then
      local path = f:find('[/\\]') and f or (resource .. sep .. 'MediaDB' .. sep .. f)
      if not seen[path:lower()] then
        seen[path:lower()] = true
        local name = (e.name or f):gsub('^DB:%s*', '')
        dbs[#dbs + 1] = { name = name, path = path }
      end
    end
  end

  if #dbs == 0 then -- no shortcuts in reaper.ini: raw directory listing
    local dir = resource .. sep .. 'MediaDB'
    local i = 0
    while true do
      local f = r.EnumerateFiles(dir, i)
      if not f then break end
      if f:lower():match('%.reaperfilelist$') then
        dbs[#dbs + 1] = { name = f, path = dir .. sep .. f }
      end
      i = i + 1
    end
  end

  table.sort(dbs, function(a, b) return a.name:lower() < b.name:lower() end)
  return dbs
end

-- FILE "path" lines carry the sample path; the DATA lines that follow carry
-- its length as l:M:SS.mmm - free one-shot filtering, no sources opened
local function parseDB(path)
  local files = {}
  local f = io.open(path, 'rb')
  if not f then return files end
  local cur
  for line in f:lines() do
    local fp = line:match('^FILE%s+"(.-)"')
    if fp then
      cur = nil
      local ext = fp:match('%.(%w+)%s*$')
      if ext and AUDIO_EXT[ext:lower()] then
        cur = { path = fp }
        files[#files + 1] = cur
      end
    elseif cur and line:match('^DATA') then
      local m, s = line:match('l:(%d+):([%d%.]+)')
      if m then cur.len = tonumber(m) * 60 + tonumber(s) end
    end
  end
  f:close()
  return files
end

--------------------------------------------------------------------- rolling

math.randomseed(math.floor(os.time() * 271 + os.clock() * 1e6))

local dbs = listDatabases()
local db_sel = nil     -- index into dbs
local db_files = {}    -- parsed entries of the selected DB
local deck, deck_n = {}, 0 -- shuffled no-repeat deck (indices into the pool)
local status = ''

for i, db in ipairs(dbs) do
  if db.name == db_want then db_sel = i end
end

local function selectDB(i)
  db_sel = i
  db_want = dbs[i].name
  db_files = parseDB(dbs[i].path)
  deck_n = 0 -- pool changed: new deck
  save()
end
if db_sel then selectDB(db_sel) end

local function buildPool()
  local pool = {}
  for _, f in ipairs(db_files) do
    -- unknown length passes: REAPER fills DATA l: on scan, so it's rare
    if not oneshot or not f.len or f.len <= max_len then pool[#pool + 1] = f end
  end
  return pool
end

local function drawFromDeck(pool)
  if not unique then return pool[math.random(#pool)] end
  if deck_n == 0 then -- refill + shuffle
    for i = 1, #pool do deck[i] = i end
    deck_n = #pool
    for i = deck_n, 2, -1 do
      local j = math.random(i)
      deck[i], deck[j] = deck[j], deck[i]
    end
  end
  local pick = pool[deck[deck_n]]
  deck_n = deck_n - 1
  return pick
end

-- seconds of leading silence in a take's source (first sample above -48 dBFS,
-- scanning at most the first 5 s). Some library files have a second of dead
-- air before the hit - without this the item plays nothing.
local SIL_THRESH = 10 ^ (-48 / 20)

local function leadingSilence(tk)
  local src = r.GetMediaItemTake_Source(tk)
  local sr = src and r.GetMediaSourceSampleRate(src) or 0
  local nch = src and r.GetMediaSourceNumChannels(src) or 0
  if sr <= 0 or nch <= 0 then return 0 end
  local acc = r.CreateTakeAudioAccessor(tk)
  if not acc then return 0 end
  local blocksz = 4096
  local buf = r.new_array(blocksz * nch)
  local t, found = 0, -1
  while t < 5 do
    buf.clear()
    if r.GetAudioAccessorSamples(acc, sr, nch, t, blocksz, buf) < 1 then break end
    local smp = buf.table()
    for i = 1, blocksz * nch do
      local v = smp[i]
      if v > SIL_THRESH or v < -SIL_THRESH then
        found = t + ((i - 1) // nch) / sr
        break
      end
    end
    if found >= 0 then break end
    t = t + blocksz / sr
  end
  r.DestroyAudioAccessor(acc)
  if found <= 0 then return 0 end
  return math.max(0, found - 0.002) -- keep a hair of ramp-in before the hit
end

local function replaceItemSource(it, f)
  local tk = r.GetActiveTake(it)
  if not tk or r.TakeIsMIDI(tk) then return false end
  if not r.BR_SetTakeSourceFromFile(tk, f.path, false) then return false end
  r.SetMediaItemTakeInfo_Value(tk, 'D_STARTOFFS', 0)
  if skip_sil then
    -- accessor time is take time; with startoffs 0 that's source/rate
    local rate = r.GetMediaItemTakeInfo_Value(tk, 'D_PLAYRATE')
    local sil = leadingSilence(tk)
    if sil > 0.001 and rate > 0 then
      r.SetMediaItemTakeInfo_Value(tk, 'D_STARTOFFS', sil * rate)
    end
  end
  local nm = f.path:match('([^/\\]+)%.%w+%s*$') or f.path
  r.GetSetMediaItemTakeInfo_String(tk, 'P_NAME', nm, true)
  if fit_len then
    local src = r.GetMediaItemTake_Source(tk)
    if src then
      local slen, isQN = r.GetMediaSourceLength(src)
      local offs = r.GetMediaItemTakeInfo_Value(tk, 'D_STARTOFFS')
      local rate = r.GetMediaItemTakeInfo_Value(tk, 'D_PLAYRATE')
      if not isQN and slen - offs > 0 and rate > 0 then
        r.SetMediaItemInfo_Value(it, 'D_LENGTH', (slen - offs) / rate)
      end
    end
  end
  r.UpdateItemInProject(it)
  return true
end

-- gather targets: every item on the selected track (selecting them so you can
-- see the blast radius), or just the already-selected items
local function gatherItems(whole_track)
  local items = {}
  if whole_track then
    local tr = r.GetSelectedTrack(0, 0)
    if not tr then
      local it = r.GetSelectedMediaItem(0, 0)
      tr = it and r.GetMediaItemTrack(it)
    end
    if not tr then return items, 'Select a track first.' end
    r.SelectAllMediaItems(0, false)
    for j = 0, r.CountTrackMediaItems(tr) - 1 do
      local it = r.GetTrackMediaItem(tr, j)
      r.SetMediaItemSelected(it, true)
      items[#items + 1] = it
    end
    if #items == 0 then return items, 'No items on that track.' end
  else
    for j = 0, r.CountSelectedMediaItems(0) - 1 do
      items[#items + 1] = r.GetSelectedMediaItem(0, j)
    end
    if #items == 0 then return items, 'No items selected.' end
  end
  return items
end

local function roll(whole_track)
  if not db_sel then status = 'Pick a database first.' return end
  local pool = buildPool()
  if #pool == 0 then
    status = 'Pool is empty - raise the one-shot length cap.'
    return
  end
  local items, err = gatherItems(whole_track)
  if err then status = err return end

  r.Undo_BeginBlock2(0)
  r.PreventUIRefresh(1)
  local done = 0
  for _, it in ipairs(items) do
    if replaceItemSource(it, drawFromDeck(pool)) then done = done + 1 end
  end
  r.PreventUIRefresh(-1)
  r.Main_OnCommand(40441, 0) -- rebuild peaks for selected items
  r.UpdateArrange()
  r.Undo_EndBlock2(0, ('ShotSwap: %d item%s from %s'):format(done, done == 1 and '' or 's', dbs[db_sel].name), -1)
  status = ('Swapped %d of %d item%s from "%s" (%d in pool).'):format(
    done, #items, #items == 1 and '' or 's', dbs[db_sel].name, #pool)
end

------------------------------------------------------------------------- UI

local ctx = r.ImGui_CreateContext('PietosiShotSwap')
local NOINPUT = r.ImGui_SliderFlags_NoInput()
local DIM = 0xFFFFFF88

local function frame()
  -- target readout
  local tr = r.GetSelectedTrack(0, 0)
  if tr then
    local _, nm = r.GetTrackName(tr)
    local idx = math.floor(r.GetMediaTrackInfo_Value(tr, 'IP_TRACKNUMBER'))
    r.ImGui_Text(ctx, ('Track: %d %s   (%d items)'):format(idx, nm, r.CountTrackMediaItems(tr)))
  else
    r.ImGui_TextColored(ctx, DIM, 'Track: none selected')
  end

  -- database picker
  r.ImGui_SetNextItemWidth(ctx, -1)
  local preview = db_sel and dbs[db_sel].name or 'Select database...'
  if r.ImGui_BeginCombo(ctx, '##db', preview) then
    for i, db in ipairs(dbs) do
      if r.ImGui_Selectable(ctx, db.name .. '###db' .. i, db_sel == i) then
        selectDB(i)
      end
    end
    r.ImGui_EndCombo(ctx)
  end
  if db_sel then
    local pool = buildPool()
    r.ImGui_TextColored(ctx, DIM, ('%d files, %d in pool after filter'):format(#db_files, #pool))
  end

  -- filters
  local ch, v = r.ImGui_Checkbox(ctx, 'One-shots only, max', oneshot)
  if ch then oneshot = v; save() end
  r.ImGui_SameLine(ctx)
  r.ImGui_SetNextItemWidth(ctx, 120)
  local lch, nlen = r.ImGui_SliderDouble(ctx, '##maxlen', max_len, 0.1, 8, '%.1f s',
    NOINPUT | r.ImGui_SliderFlags_Logarithmic())
  if lch then max_len = nlen; save() end

  ch, v = r.ImGui_Checkbox(ctx, 'No repeats until pool used up', unique)
  if ch then unique = v; deck_n = 0; save() end
  ch, v = r.ImGui_Checkbox(ctx, 'Fit item length to sample', fit_len)
  if ch then fit_len = v; save() end
  ch, v = r.ImGui_Checkbox(ctx, 'Skip leading silence in samples', skip_sil)
  if ch then skip_sil = v; save() end

  -- the button
  r.ImGui_Dummy(ctx, 1, 6)
  local availw = select(1, r.ImGui_GetContentRegionAvail(ctx))
  r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Button(), 0x7A2FB8FF)
  r.ImGui_PushStyleColor(ctx, r.ImGui_Col_ButtonHovered(), 0x9440D6FF)
  r.ImGui_PushStyleColor(ctx, r.ImGui_Col_ButtonActive(), 0x5C2390FF)
  if r.ImGui_Button(ctx, 'ROLL TRACK', availw, 34) then roll(true) end
  r.ImGui_PopStyleColor(ctx, 3)
  if r.ImGui_Button(ctx, 'Roll selected items only', availw, 0) then roll(false) end

  if status ~= '' then
    r.ImGui_Dummy(ctx, 1, 2)
    r.ImGui_TextWrapped(ctx, status)
  end
end

local function loop()
  r.ImGui_SetNextWindowSize(ctx, 340, 260, r.ImGui_Cond_FirstUseEver())
  local visible, open = r.ImGui_Begin(ctx, 'ShotSwap###PietosiShotSwap', true)
  if visible then
    local ok, err = pcall(frame)
    r.ImGui_End(ctx)
    if not ok then
      r.ShowConsoleMsg('ShotSwap error: ' .. tostring(err) .. '\n')
      open = false
    end
  end
  if open then r.defer(loop) else save() end
end

r.defer(loop)
