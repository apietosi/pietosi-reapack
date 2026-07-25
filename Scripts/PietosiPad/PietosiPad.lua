-- @description PietosiPad - Launchpad MK1 control surface for the PietosiKeys modes
-- @version 0.4.0
-- @author pie
-- @provides [main=main] .
-- @about
--   Background watcher that turns a Launchpad MK1 into a mode-aware control
--   surface for the PietosiKeys layers.
--
--   Top row of round buttons: first four = the hardware arrows, and they are
--   contextual per mode (MIX: left/right slide the 8-track window by 1,
--   up/down jump it by 8 - so the grid is never stuck on 8 channels;
--   other modes: up/down = prev/next track, left/right = move edit cursor by
--   grid). Last four = mode selectors MIX / EDIT / REC / AUTO.
--
--   Right-side round column is global in every mode: play, record, metronome,
--   FX chain, routing, quantize, master 0 dB, Esc.
--
--   The 8x8 grid changes with the mode:
--     MIX  - live feedback mixer, each column = one visible track
--            (select / vol +- / pan / mute / solo / arm)
--     EDIT - row 1 walk/select (items, transients, razor), row 2 item verbs
--            (split, dup, nudge, pitch, MIDI editor), row 4 the glitch
--            one-keys 1-7 + ShotSwap, row 5 grid sizes (active one bright)
--     REC  - record modes / pre-roll / monitor / loop / lanes, punch points,
--            take prev-next / crop
--     AUTO - automation mode of selected tracks (trim/read/touch/write/latch),
--            envelope visibility and points
--
--   The Launchpad is never routed to any track: input is polled with
--   MIDI_GetRecentInputEvent, and LED feedback goes out through a hidden
--   bridge track ("#PietosiPad Bridge") running PietosiPad_Bridge.jsfx,
--   whose MIDI hardware output is set to the Launchpad.
--
--   Auto-started from Scripts/__startup.lua (same pattern as ModeHUD).

local r = reaper

-- ========================= config =========================

local DEBUG         = true                 -- trace of events + decisions (PietosiPad.log only, never the console)
local DEV_MATCH     = 'launchpad'          -- device name match, case-insensitive
local BRIDGE_TRACK  = '#PietosiPad Bridge'
local VOL_STEP_DB   = 1.0
local PAN_STEP      = 0.05
local HOLD_DELAY    = 0.40                 -- seconds before a held pad repeats
local HOLD_RATE     = 0.12                 -- repeat interval while held

-- MK1 LED velocities: vel = 16*green + red + 12 (flags), red/green 0-3
local OFF, RED_LO, RED       = 12, 13, 15
local GREEN_LO, GREEN        = 28, 60
local AMBER_LO, AMBER        = 29, 63
local ORANGE_LO, ORANGE      = 30, 47

-- ========================= guards =========================

local LOG_PATH = r.GetResourcePath() .. '/Scripts/PietosiPad/PietosiPad.log'
do
  local f = io.open(LOG_PATH, 'w')
  if f then f:write(os.date('%Y-%m-%d %H:%M:%S'), ' PietosiPad starting\n') f:close() end
end

local function dbg(fmt, ...)
  if not DEBUG then return end
  -- file only: ShowConsoleMsg pops the console window and steals focus from REAPER
  local line = ('PietosiPad: ' .. fmt):format(...)
  local f = io.open(LOG_PATH, 'a')
  if f then f:write(os.date('%H:%M:%S '), line, '\n') f:close() end
end

if not r.APIExists('CF_EnumerateActions') then
  r.ShowConsoleMsg('PietosiPad: SWS extension required (CF_EnumerateActions). Not starting.\n')
  return
end

local function findMidiDev(isInput)
  local n = isInput and r.GetNumMIDIInputs() or r.GetNumMIDIOutputs()
  for i = 0, n - 1 do
    local ok, name
    if isInput then ok, name = r.GetMIDIInputName(i, '')
    else ok, name = r.GetMIDIOutputName(i, '') end
    if ok and name and name:lower():find(DEV_MATCH, 1, true) then return i, name end
  end
end

local lpIn, lpInName = findMidiDev(true)
local lpOut, lpOutName = findMidiDev(false)
if not lpIn or not lpOut then
  dbg('FATAL: no Launchpad found on MIDI %ss (enable it in Preferences > MIDI Devices)',
    lpIn and 'output' or 'input')
  r.ShowConsoleMsg('PietosiPad: no Launchpad found. Not starting.\n')
  return
end
dbg('devices: in=%d (%s), out=%d (%s)', lpIn, lpInName, lpOut, lpOutName)

r.gmem_attach('PietosiPad')

-- ========================= action lookup =========================
-- one pass over the action list, same approach as PietosiKeys_ModeHUD

local MODE_ORDER = { 'MIX', 'EDIT', 'REC', 'AUTO' }
local toggles = {}   -- MIX/EDIT/REC/AUTO -> { every matching "toggle override to alt-N" cmd }

-- name-resolved actions for the EDIT/REC/AUTO pages. Each entry is either
-- { {must-contain...}, {must-not-contain...} } matched against the lowercase
-- action name, or { eq = 'exact lowercase name' }. Unresolved keys leave
-- their pad dark (and get listed in the debug log).
local NAMED = {
  grab     = { {'select items under edit cursor'} },
  razor    = { {'razor', 'selected'} },
  razorClr = { {'razor', 'clear'} },
  nudgeL   = { {'move items', 'grid', 'left'} },
  nudgeR   = { {'move items', 'grid', 'right'} },
  pitchUp  = { {'pitch item', 'semitone', 'up'} },
  pitchDn  = { {'pitch item', 'semitone', 'down'} },
  preroll  = { {'pre-roll', 'record'} },
  lanes    = { {'fixed', 'lanes'} },
  volEnv   = { {'volume envelope', 'visible'}, {'pre-fx'} },
  panEnv   = { {'pan envelope', 'visible'}, {'pre-fx'} },
  envIns   = { {'insert new point'} },
  envPrev  = { {'previous envelope point'} },
  envNext  = { {'next envelope point'} },
  gShuf    = { {'pietosiglitch', 'shuffle'} },
  gRev     = { {'pietosiglitch', 'reverse'} },
  gTape    = { {'pietosiglitch', 'tapestop'} },
  gBuild   = { {'pietosiglitch', 'buildup'} },
  gHalf    = { {'pietosiglitch', 'halftime'} },
  gChop    = { {'pietosiglitch', 'vocalchop'} },
  gWheel   = { {'pietosiwheelsplit'} },
  gSwap    = { {'pietosishotswap'} },
  grid4    = { eq = 'grid: set to 1/4' },
  grid8    = { eq = 'grid: set to 1/8' },
  grid16   = { eq = 'grid: set to 1/16' },
  grid32   = { eq = 'grid: set to 1/32' },
  grid8T   = { {'grid: set to', '1/8 triplet'} },
  grid16T  = { {'grid: set to', '1/16 triplet'} },
  -- v0.4: denser pages (the keyboard modes are retired; pads carry it all)
  snapGrid = { {'start to grid (keep length)'} },
  splitTrans = { {'split', 'items at transients'} },
  splitSm  = { {'split selected items at stretch markers'} },
  grvGet   = { {'get groove from selected media items'} },
  grvApply = { {'apply groove to selected media items (within 16th)'} },
  compUp   = { {'move comp area up'} },
  compDn   = { {'move comp area down'} },
  compSplit= { {'split comp area'} },
  compTop  = { {'move active comp to top lane'} },
  compLoop = { {'set loop points to comp area'} },
  envRect  = { {'insert 4 envelope points'} },
  envVal   = { {'envelope point value at cursor'} },
  envPull  = { {'closest envelope point', 'edit cursor'} },
}
local A = {} -- NAMED key -> resolved command id

local playCmd, quantCmd, gridLeftCmd, gridRightCmd
do
  local altmap = { ['alt-1'] = 'MIX', ['alt-2'] = 'EDIT', ['alt-3'] = 'REC', ['alt-4'] = 'AUTO' }
  local quantFallback
  for i = 0, 300000 do
    local cmd, name = r.CF_EnumerateActions(0, i, '')
    if not cmd or cmd <= 0 then break end
    local l = (name or ''):lower()
    if l:find('main action section', 1, true) and l:find('toggle', 1, true) then
      -- extract the exact alt number so 'alt-1' can't also match alt-10..16
      local n = l:match('alt%-(%d+)')
      local mode = n and altmap['alt-' .. n]
      if mode then
        toggles[mode] = toggles[mode] or {}
        local t = toggles[mode]
        -- non-momentary variant goes to slot 1 (used for switching);
        -- every variant is kept so currentMode() can check them all
        if l:find('momentar', 1, true) then t[#t + 1] = cmd
        else table.insert(t, 1, cmd) end
      end
    end
    if not playCmd and (l:find('one-cursor', 1, true) or l:find('one cursor', 1, true)) then
      playCmd = cmd
    end
    if not quantCmd and l:find('quantize track items', 1, true) then quantCmd = cmd end
    if not quantFallback and l:find('pietosiquantize', 1, true) then quantFallback = cmd end
    -- edit-cursor-by-grid pair for the non-MIX arrows ('item' excluded so the
    -- "Item edit: Move items/envelope points..." actions can't match)
    if not l:find('item', 1, true) and l:find('grid', 1, true) then
      if not gridLeftCmd and l:find('cursor left', 1, true) then gridLeftCmd = cmd end
      if not gridRightCmd and l:find('cursor right', 1, true) then gridRightCmd = cmd end
    end
    for key, spec in pairs(NAMED) do
      if not A[key] then
        if spec.eq then
          if l == spec.eq then A[key] = cmd end
        else
          local ok = true
          for _, p in ipairs(spec[1]) do
            if not l:find(p, 1, true) then ok = false break end
          end
          if ok and spec[2] then
            for _, p in ipairs(spec[2]) do
              if l:find(p, 1, true) then ok = false break end
            end
          end
          if ok then A[key] = cmd end
        end
      end
    end
  end
  quantCmd = quantCmd or quantFallback
  playCmd = playCmd or 40044 -- Transport: Play/stop
end

local recCmd = r.NamedCommandLookup('_PietosiRecordArm')
if recCmd == 0 then recCmd = 1013 end -- plain Transport: Record

if not toggles.MIX then
  r.ShowConsoleMsg('PietosiPad: PietosiKeys mode-toggle actions not found. Not starting.\n')
  return
end

-- ========================= bridge track =========================

local function findTrackByName(name)
  for i = 0, r.CountTracks(0) - 1 do
    local tr = r.GetTrack(0, i)
    local _, tn = r.GetSetMediaTrackInfo_String(tr, 'P_NAME', '', false)
    if tn == name then return tr end
  end
end

local function ensureBridge()
  local tr = findTrackByName(BRIDGE_TRACK)
  if not tr then
    r.PreventUIRefresh(1)
    r.InsertTrackAtIndex(r.CountTracks(0), false)
    tr = r.GetTrack(0, r.CountTracks(0) - 1)
    r.GetSetMediaTrackInfo_String(tr, 'P_NAME', BRIDGE_TRACK, true)
    r.SetMediaTrackInfo_Value(tr, 'B_SHOWINTCP', 0)
    r.SetMediaTrackInfo_Value(tr, 'B_SHOWINMIXER', 0)
    r.SetMediaTrackInfo_Value(tr, 'B_MAINSEND', 0)
    r.PreventUIRefresh(-1)
  end
  r.SetMediaTrackInfo_Value(tr, 'I_MIDIHWOUT', lpOut * 32) -- device << 5, ch = original
  if r.TrackFX_GetCount(tr) == 0 then
    local fx = r.TrackFX_AddByName(tr, 'PietosiPad_Bridge', false, 1)
    if fx < 0 then fx = r.TrackFX_AddByName(tr, 'JS:PietosiPad/PietosiPad_Bridge', false, 1) end
    if fx < 0 then
      r.ShowConsoleMsg('PietosiPad: could not load PietosiPad_Bridge.jsfx (Effects/PietosiPad missing?).\n')
      return nil
    end
  end
  return tr
end

if not ensureBridge() then return end

-- ========================= LED output =========================

local function led(s, d1, d2)
  local wp = r.gmem_read(0)
  local base = 16 + (wp % 1024) * 3
  r.gmem_write(base, s)
  r.gmem_write(base + 1, d1)
  r.gmem_write(base + 2, d2)
  r.gmem_write(0, wp + 1)
end

-- frame slots: 0-63 grid (row*8+col), 64-71 right column (row), 72-79 top row (col)
-- (this is exactly the MK1 "rapid LED update" order: grid, scene column, top row)
local sent = {}

local function pushFrame(want, force)
  if force then
    -- rapid update (92h): all 80 LEDs in 40 messages, ~100 ms instead of ~200
    for i = 0, 79, 2 do
      local a, b = want[i] or OFF, want[i + 1] or OFF
      led(0x92, a, b)
      sent[i], sent[i + 1] = a, b
    end
    -- a standard message must follow, or the next 92h burst won't reset the
    -- write cursor; restating a top-row LED is a harmless way to exit the mode
    led(0xB0, 104, sent[72])
    return
  end
  for i = 0, 79 do
    local v = want[i] or OFF
    if sent[i] ~= v then
      if i >= 72 then led(0xB0, 104 + (i - 72), v)
      elseif i >= 64 then led(0x90, (i - 64) * 16 + 8, v)
      else led(0x90, math.floor(i / 8) * 16 + (i % 8), v)
      end
      sent[i] = v
    end
  end
end

-- ========================= mode + track state =========================

local function currentMode()
  for _, m in ipairs(MODE_ORDER) do
    for _, cmd in ipairs(toggles[m] or {}) do
      if r.GetToggleCommandState(cmd) == 1 then return m end
    end
  end
  return 'STOCK'
end

local bankStart = 0
local visTracks = {}

local function refreshVisTracks()
  visTracks = {}
  for i = 0, r.CountTracks(0) - 1 do
    local tr = r.GetTrack(0, i)
    if r.GetMediaTrackInfo_Value(tr, 'B_SHOWINTCP') == 1 then
      visTracks[#visTracks + 1] = tr
    end
  end
  local maxStart = math.max(0, #visTracks - 8)
  if bankStart > maxStart then bankStart = maxStart end
end

local function trackAt(col) return visTracks[bankStart + col + 1] end

-- ========================= actions =========================

local function nudgeVol(tr, db)
  local v = r.GetMediaTrackInfo_Value(tr, 'D_VOL')
  if v < 0.000031623 then v = 0.000031623 end -- floor at -90 dB so nudge-up recovers
  v = v * 10 ^ (db / 20)
  if v > 3.981 then v = 3.981 end             -- +12 dB ceiling
  r.SetMediaTrackInfo_Value(tr, 'D_VOL', v)
end

local function nudgePan(tr, amt)
  local p = r.GetMediaTrackInfo_Value(tr, 'D_PAN') + amt
  if p > 1 then p = 1 elseif p < -1 then p = -1 end
  r.SetMediaTrackInfo_Value(tr, 'D_PAN', p)
end

local function toggleFlag(tr, param, onval)
  local cur = r.GetMediaTrackInfo_Value(tr, param)
  r.SetMediaTrackInfo_Value(tr, param, cur > 0 and 0 or (onval or 1))
end

local function setMode(target)
  local mode = currentMode()
  if mode == target then return end
  r.Main_OnCommand(toggles[target][1], 0)
end

local function escMode()
  local mode = currentMode()
  if mode == 'MIX' then r.Main_OnCommand(toggles.MIX[1], 0)   -- MIX -> stock
  elseif mode ~= 'STOCK' then setMode('MIX') end               -- deeper -> MIX
end

-- ========================= input =========================

local held = {} -- [note] = { fn = repeat_fn, t0 = press time, last = last fire }
local now = 0

local function hold(note, fn)
  fn()
  held[note] = { fn = fn, t0 = now, last = now }
end

local function runA(id) if id then r.Main_OnCommand(id, 0) end end

local function gridPressMix(row, col, note)
  local tr = trackAt(col)
  if not tr then
    dbg('grid %d,%d: no track (bank=%d, %d visible)', row, col, bankStart, #visTracks)
    return
  end
  if row == 0 then
    r.SetOnlyTrackSelected(tr)
    r.Main_OnCommand(40913, 0) -- vertical scroll selected tracks into view
  elseif row == 1 then hold(note, function() nudgeVol(tr,  VOL_STEP_DB) end)
  elseif row == 2 then hold(note, function() nudgeVol(tr, -VOL_STEP_DB) end)
  elseif row == 3 then hold(note, function() nudgePan(tr, -PAN_STEP) end)
  elseif row == 4 then hold(note, function() nudgePan(tr,  PAN_STEP) end)
  elseif row == 5 then toggleFlag(tr, 'B_MUTE')
  elseif row == 6 then toggleFlag(tr, 'I_SOLO', 2)
  elseif row == 7 then toggleFlag(tr, 'I_RECARM')
  end
end

-- EDIT page. Row 1 = walk/select, row 2 = item verbs, row 4 = the glitch
-- one-keys (mirrors keyboard 1-7 + ShotSwap), row 5 = grid sizes.
-- nil slots stay dark; positional nils in these tables are intentional.
local EDIT_ROWS = {
  [0] = { 40416, 40417, A.grab, 41173, 40375, 40376, A.razor, A.razorClr },
  [1] = { 40012, 41295, A.nudgeL, A.nudgeR, A.pitchDn, A.pitchUp, 40153, A.splitTrans },
  [3] = { A.gShuf, A.gRev, A.gTape, A.gBuild, A.gHalf, A.gChop, A.gWheel, A.gSwap },
  [4] = { A.grid4, A.grid8, A.grid16, A.grid32, A.grid8T, A.grid16T },
  [6] = { A.snapGrid, A.splitSm, A.grvGet, A.grvApply },
}
-- pads that repeat while held: item walk, transients, nudge, pitch
local EDIT_HOLD = {
  [0] = { [0] = true, [1] = true, [4] = true, [5] = true },
  [1] = { [2] = true, [3] = true, [4] = true, [5] = true },
}

local function gridPressEdit(row, col, note)
  local id = EDIT_ROWS[row] and EDIT_ROWS[row][col + 1]
  if not id then dbg('grid %d,%d: unmapped (EDIT)', row, col) return end
  if EDIT_HOLD[row] and EDIT_HOLD[row][col] then
    hold(note, function() r.Main_OnCommand(id, 0) end)
  else
    r.Main_OnCommand(id, 0)
  end
end

local function gridPressRec(row, col, note)
  if row == 0 then
    if col == 0 then runA(40252)          -- record mode: normal
    elseif col == 1 then runA(40076)      -- record mode: time selection auto-punch
    elseif col == 2 then runA(40253)      -- record mode: auto-punch selected items
    elseif col == 3 then runA(A.preroll)
    elseif col == 4 then runA(40495)      -- cycle track record monitor
    elseif col == 5 then runA(1068)       -- toggle repeat
    elseif col == 6 then runA(A.lanes)
    end
  elseif row == 1 then
    if col == 0 then runA(40625)          -- time selection: set start point
    elseif col == 1 then runA(40626)      -- time selection: set end point
    elseif col == 2 then runA(40126)      -- previous take
    elseif col == 3 then runA(40125)      -- next take
    elseif col == 4 then runA(40131)      -- crop to active take
    end
  elseif row == 3 then
    if col == 0 then runA(A.compUp)
    elseif col == 1 then runA(A.compDn)
    elseif col == 2 then runA(A.compSplit)
    elseif col == 3 then runA(A.compTop)
    elseif col == 4 then runA(A.compLoop)
    end
  end
end

local function gridPressAuto(row, col, note)
  if row == 0 and col <= 4 then
    -- I_AUTOMODE: 0 trim/read, 1 read, 2 touch, 3 write, 4 latch
    for i = 0, r.CountSelectedTracks(0) - 1 do
      r.SetMediaTrackInfo_Value(r.GetSelectedTrack(0, i), 'I_AUTOMODE', col)
    end
  elseif row == 1 then
    if col == 0 then runA(A.volEnv)
    elseif col == 1 then runA(A.panEnv)
    elseif col == 2 then runA(A.envIns)
    elseif col == 3 then runA(A.envPrev)
    elseif col == 4 then runA(A.envNext)
    elseif col == 5 then runA(40625)      -- time selection: set start point
    elseif col == 6 then runA(40626)      -- time selection: set end point
    end
  elseif row == 3 then
    if col == 0 then runA(A.envRect)      -- 4 points at time selection
    elseif col == 1 then runA(A.envVal)   -- type point value at cursor
    elseif col == 2 then runA(A.envPull)  -- pull closest point to cursor
    end
  end
end

local function gridPress(row, col, note)
  local mode = currentMode()
  dbg('grid %d,%d (mode=%s)', row, col, mode)
  if mode == 'MIX' then gridPressMix(row, col, note)
  elseif mode == 'EDIT' then gridPressEdit(row, col, note)
  elseif mode == 'REC' then gridPressRec(row, col, note)
  elseif mode == 'AUTO' then gridPressAuto(row, col, note)
  end
end

-- right-side round column: global transport/utility strip, same in every mode
local function rightPress(row)
  if row == 0 then r.Main_OnCommand(playCmd, 0)
  elseif row == 1 then r.Main_OnCommand(recCmd, 0)
  elseif row == 2 then r.Main_OnCommand(40364, 0)              -- metronome
  elseif row == 3 then r.Main_OnCommand(40291, 0)              -- FX chain
  elseif row == 4 then r.Main_OnCommand(40293, 0)              -- routing
  elseif row == 5 then if quantCmd then r.Main_OnCommand(quantCmd, 0) end
  elseif row == 6 then r.SetMediaTrackInfo_Value(r.GetMasterTrack(0), 'D_VOL', 1.0)
  elseif row == 7 then escMode()
  end
end

local function bankBy(d)
  local maxStart = math.max(0, #visTracks - 8)
  bankStart = math.max(0, math.min(maxStart, bankStart + d))
end

-- top row: 0-3 = hardware arrows (contextual per mode), 4-7 = mode strip.
-- CCs get pseudo-note ids 200+ so they can share the hold-repeat table.
local function topPress(i)
  if i >= 4 then setMode(MODE_ORDER[i - 3]) return end
  local note = 200 + i
  if currentMode() == 'MIX' then
    -- the grid is a window onto the track list, not a hard 8-channel limit:
    -- left/right slide it a track at a time, up/down jump a full bank
    if i == 0 then hold(note, function() bankBy(-8) end)
    elseif i == 1 then hold(note, function() bankBy(8) end)
    elseif i == 2 then hold(note, function() bankBy(-1) end)
    elseif i == 3 then hold(note, function() bankBy(1) end)
    end
  else
    if i == 0 then hold(note, function() r.Main_OnCommand(40286, 0) end)      -- prev track
    elseif i == 1 then hold(note, function() r.Main_OnCommand(40285, 0) end)  -- next track
    elseif i == 2 and gridLeftCmd then hold(note, function() r.Main_OnCommand(gridLeftCmd, 0) end)
    elseif i == 3 and gridRightCmd then hold(note, function() r.Main_OnCommand(gridRightCmd, 0) end)
    end
  end
end

local function handleMidi(s, d1, d2)
  local st = s & 0xF0
  if st == 0xB0 then
    if d1 >= 104 and d1 <= 111 then
      if d2 > 0 then topPress(d1 - 104)
      else held[200 + (d1 - 104)] = nil end
    end
  elseif st == 0x90 or st == 0x80 then
    local row, col = d1 >> 4, d1 & 0x0F
    if row > 7 or col > 8 then return end
    if st == 0x90 and d2 > 0 then
      if col == 8 then rightPress(row) else gridPress(row, col, d1) end
    else
      held[d1] = nil
    end
  end
end

local lastCnt
local function pollInput()
  local cnt = r.MIDI_GetRecentInputEvent(0)
  if lastCnt == nil then lastCnt = cnt return end -- ignore pre-start history
  local new = cnt - lastCnt
  lastCnt = cnt
  if new <= 0 then return end
  if new > 64 then new = 64 end
  for i = new - 1, 0, -1 do
    local _, buf, _, devIdx = r.MIDI_GetRecentInputEvent(i)
    if buf and #buf >= 3 then
      local match = devIdx == lpIn or (devIdx & 0xFFFF) == lpIn
      dbg('in dev=%d%s: %02X %02X %02X', devIdx, match and '' or ' (not launchpad, ignored)',
        buf:byte(1), buf:byte(2), buf:byte(3))
      if match then handleMidi(buf:byte(1), buf:byte(2), buf:byte(3)) end
    end
  end
end

local function processHolds()
  for note, h in pairs(held) do
    if now - h.t0 > 5 then held[note] = nil -- lost release, safety
    elseif now - h.t0 >= HOLD_DELAY and now - h.last >= HOLD_RATE then
      h.fn()
      h.last = now
    end
  end
end

-- ========================= LED frames =========================

local MODE_COLOR = {
  MIX  = { GREEN,  GREEN_LO  },
  EDIT = { AMBER,  AMBER_LO  },
  REC  = { RED,    RED_LO    },
  AUTO = { ORANGE, ORANGE_LO },
}

local function computeFrame(mode)
  local w = {}

  -- top row 72-75: arrows, lit when they can do something in this mode
  if mode == 'MIX' then
    local maxStart = math.max(0, #visTracks - 8)
    w[72] = bankStart > 0 and GREEN_LO or OFF        -- up: bank -8
    w[73] = bankStart < maxStart and GREEN_LO or OFF -- down: bank +8
    w[74] = bankStart > 0 and AMBER_LO or OFF        -- left: window -1
    w[75] = bankStart < maxStart and AMBER_LO or OFF -- right: window +1
  else
    w[72], w[73] = GREEN_LO, GREEN_LO                          -- prev/next track
    w[74] = gridLeftCmd and AMBER_LO or OFF                    -- cursor by grid
    w[75] = gridRightCmd and AMBER_LO or OFF
  end
  -- top row 76-79: mode strip
  for i, m in ipairs(MODE_ORDER) do
    local c = MODE_COLOR[m]
    w[76 + i - 1] = (mode == m) and c[1] or c[2]
  end

  -- right column 64-71: global transport strip
  local ps = r.GetPlayState()
  w[64] = (ps & 1) == 1 and GREEN or GREEN_LO
  w[65] = (ps & 4) == 4 and RED or RED_LO
  w[66] = r.GetToggleCommandState(40364) == 1 and AMBER or AMBER_LO
  w[67] = AMBER_LO                                   -- FX chain
  w[68] = AMBER_LO                                   -- routing
  w[69] = quantCmd and AMBER_LO or OFF               -- quantize
  w[70] = GREEN_LO                                   -- master 0 dB
  w[71] = mode ~= 'STOCK' and RED_LO or OFF          -- Esc

  if mode == 'MIX' then
    for col = 0, 7 do
      local tr = trackAt(col)
      if tr then
        local sel = r.GetMediaTrackInfo_Value(tr, 'I_SELECTED') > 0
        w[0 * 8 + col] = sel and GREEN or GREEN_LO
        w[1 * 8 + col] = GREEN_LO
        w[2 * 8 + col] = GREEN_LO
        w[3 * 8 + col] = AMBER_LO
        w[4 * 8 + col] = AMBER_LO
        w[5 * 8 + col] = r.GetMediaTrackInfo_Value(tr, 'B_MUTE') > 0 and AMBER or OFF
        w[6 * 8 + col] = r.GetMediaTrackInfo_Value(tr, 'I_SOLO') > 0 and GREEN or OFF
        w[7 * 8 + col] = r.GetMediaTrackInfo_Value(tr, 'I_RECARM') > 0 and RED or OFF
      end
    end

  elseif mode == 'EDIT' then
    for _, row in ipairs({ 0, 1, 3, 6 }) do
      for c = 0, 7 do
        if EDIT_ROWS[row][c + 1] then w[row * 8 + c] = AMBER_LO end
      end
    end
    -- grid-size row: the active division lights bright
    local _, div = r.GetSetProjectGrid(0, false)
    local G = { 0.25, 0.125, 0.0625, 0.03125, 1 / 12, 1 / 24 }
    for c = 0, 5 do
      if EDIT_ROWS[4][c + 1] then
        w[4 * 8 + c] = (div and math.abs(div - G[c + 1]) < 0.001) and AMBER or AMBER_LO
      end
    end

  elseif mode == 'REC' then
    w[0] = r.GetToggleCommandState(40252) == 1 and RED or RED_LO
    w[1] = r.GetToggleCommandState(40076) == 1 and RED or RED_LO
    w[2] = r.GetToggleCommandState(40253) == 1 and RED or RED_LO
    w[3] = A.preroll and (r.GetToggleCommandState(A.preroll) == 1 and RED or RED_LO) or OFF
    local st = r.GetSelectedTrack(0, 0)
    w[4] = (st and r.GetMediaTrackInfo_Value(st, 'I_RECMON') > 0) and RED or RED_LO
    w[5] = r.GetToggleCommandState(1068) == 1 and RED or RED_LO
    w[6] = A.lanes and (r.GetToggleCommandState(A.lanes) == 1 and RED or RED_LO) or OFF
    for c = 0, 4 do w[8 + c] = RED_LO end
    local comp = { A.compUp, A.compDn, A.compSplit, A.compTop, A.compLoop }
    for c = 0, 4 do
      if comp[c + 1] then w[3 * 8 + c] = RED_LO end
    end

  elseif mode == 'AUTO' then
    local st = r.GetSelectedTrack(0, 0)
    local am = st and r.GetMediaTrackInfo_Value(st, 'I_AUTOMODE') or -1
    for c = 0, 4 do w[c] = (am == c) and ORANGE or ORANGE_LO end
    w[8 + 0] = A.volEnv and
      ((st and r.GetTrackEnvelopeByName(st, 'Volume')) and ORANGE or ORANGE_LO) or OFF
    w[8 + 1] = A.panEnv and
      ((st and r.GetTrackEnvelopeByName(st, 'Pan')) and ORANGE or ORANGE_LO) or OFF
    w[8 + 2] = A.envIns and ORANGE_LO or OFF
    w[8 + 3] = A.envPrev and ORANGE_LO or OFF
    w[8 + 4] = A.envNext and ORANGE_LO or OFF
    w[8 + 5], w[8 + 6] = ORANGE_LO, ORANGE_LO
    w[3 * 8 + 0] = A.envRect and ORANGE_LO or OFF
    w[3 * 8 + 1] = A.envVal and ORANGE_LO or OFF
    w[3 * 8 + 2] = A.envPull and ORANGE_LO or OFF
  end
  return w
end

-- ========================= main loop =========================

led(0xB0, 0, 0) -- full LED reset on start
led(0xB0, 0, 1) -- force X-Y grid mapping, in case another app left drum layout
local tick = 0
local lastMode, lastBank

if DEBUG then
  for _, m in ipairs(MODE_ORDER) do
    dbg('mode %s: %d toggle action(s) resolved', m, #(toggles[m] or {}))
  end
  local miss = {}
  for k in pairs(NAMED) do if not A[k] then miss[#miss + 1] = k end end
  if #miss > 0 then
    table.sort(miss)
    dbg('unresolved page actions (pads stay dark): %s', table.concat(miss, ', '))
  end
end

local function loop()
  now = r.time_precise()
  pollInput()
  processHolds()
  tick = tick + 1
  if tick % 2 == 0 then
    refreshVisTracks()
    local mode = currentMode()
    local force = mode ~= lastMode or bankStart ~= lastBank
    if mode ~= lastMode then dbg('mode -> %s (%d tracks visible)', mode, #visTracks) end
    lastMode, lastBank = mode, bankStart
    pushFrame(computeFrame(mode), force)
  end
  if tick % 300 == 0 and not findTrackByName(BRIDGE_TRACK) then ensureBridge() end
  r.defer(loop)
end

r.atexit(function() led(0xB0, 0, 0) end)

dbg('running (in: %s, out: %s)%s', lpInName, lpOutName,
  quantCmd and '' or ' [quantize pad inactive - action not found]')
loop()
