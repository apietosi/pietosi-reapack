-- @description PietosiKeys - build the no-mouse keymap for native REAPER
-- @version 0.6.0
-- @author pie
-- @provides [main=main] .
-- @about
--   Generates PietosiKeys.ReaperKeyMap. v0.6 is the UNIFIED scheme:
--   navigation and the shared verbs are bound IDENTICALLY in all four modes -
--   only the number row (the mode's palette) and a few documented mode
--   letters change per mode.
--
--   Everywhere (MIX / EDIT / REC / AUTO):
--     Up/Down = track nav, Left/Right = native scrub (left unbound on
--     purpose), Ctrl+arrows = item walk (2D), Alt+L/R = transients,
--     Shift+Up/Down = track volume, Shift+L/R = pan, Alt+Up/Down = pitch,
--     M/S mute/solo, R record (auto-arm), Shift+R arm, Shift+M monitor,
--     G grab, X split, D duplicate, Z razor, Q quantize, F/Tab FX chain,
--     I routing, 0 vol reset, Shift+0 master 0 dB, Shift+1-6 grid sizes,
--     Enter -> EDIT, W -> REC, A -> AUTO, Esc backs out one level.
--   Palettes (number row): MIX 1-8 = select track 1-8, EDIT 1-7 = glitch
--   one-keys, REC 1-3 = record modes, AUTO 1-5 = automation modes.
--
--   Every action id is resolved BY NAME on this machine at build time, so
--   nothing is hardcoded. Unresolvable actions are skipped and reported.
--   Run this script once, then: Actions window > Key map... (bottom left) >
--   Import... > KeyMaps\PietosiKeys.ReaperKeyMap.

local r = reaper

if not r.APIExists('CF_EnumerateActions') then
  r.MB('PietosiKeys needs the SWS extension (CF_EnumerateActions).', 'PietosiKeys', 0)
  return
end

local function log(s) r.ShowConsoleMsg(s .. '\n') end
r.ClearConsole()
log('PietosiKeys builder v0.5')
log('========================')

--------------------------------------------------------- action resolution

local MIDI_SEC = 32060

local function scanSection(section)
  local t = {}
  for i = 0, 200000 do
    local cmd, name = r.CF_EnumerateActions(section, i, '')
    if not cmd or cmd <= 0 then break end
    t[#t + 1] = { cmd = cmd, name = name, l = (name or ''):lower() }
  end
  return t
end

local acts = scanSection(0)
local midiacts = scanSection(MIDI_SEC)
log(('scanned %d main actions, %d MIDI editor actions'):format(#acts, #midiacts))

-- resolve by trying pattern-sets in order; every substring in a set must match
local unresolved = {}
local function resolve(label, patternsets, prefer, pool)
  pool = pool or acts
  for _, set in ipairs(patternsets) do
    if #set == 1 then -- exact match first
      for _, a in ipairs(pool) do
        if a.l == set[1] then return a end
      end
    end
    local best
    for _, a in ipairs(pool) do
      local ok = true
      for _, p in ipairs(set) do
        if not a.l:find(p, 1, true) then ok = false break end
      end
      if ok then
        if prefer and a.l:find(prefer, 1, true) then best = a break end
        best = best or a
      end
    end
    if best then return best end
  end
  unresolved[#unresolved + 1] = label
  return nil
end

local function token(a)
  if not a then return nil end
  if a.token then return a.token end
  local named = r.ReverseNamedCommandLookup(a.cmd)
  a.token = named and ('_' .. named) or tostring(a.cmd)
  return a.token
end

local A = {
  -- transport / global
  play_stop     = resolve('Transport: Play/stop', { { 'transport: play/stop' } }),
  edit_to_play  = resolve('View: Move edit cursor to play cursor', { { 'move edit cursor to play cursor' } }),
  record        = resolve('Transport: Record', { { 'transport: record' } }),
  repeat_tgl    = resolve('Transport: Toggle repeat', { { 'transport: toggle repeat' } }),
  -- tracks
  next_track    = resolve('Track: Go to next track', { { 'track: go to next track' } }),
  prev_track    = resolve('Track: Go to previous track', { { 'track: go to previous track' } }),
  vol_up        = resolve('Nudge volume up (selected tracks)', { { 'nudge volume of selected tracks up' }, { 'nudge track volume up' } }),
  vol_down      = resolve('Nudge volume down (selected tracks)', { { 'nudge volume of selected tracks down' }, { 'nudge track volume down' } }),
  pan_left      = resolve('Nudge pan left (selected tracks)', { { 'pan of selected tracks left' }, { 'nudge track pan left' } }),
  pan_right     = resolve('Nudge pan right (selected tracks)', { { 'pan of selected tracks right' }, { 'nudge track pan right' } }),
  vol_reset     = resolve('Reset volume to 0 dB (selected tracks)', { { 'reset volume of selected tracks' }, { 'set volume of selected tracks to 0' }, { 'reset volume', 'selected' } }),
  mute          = resolve('Toggle mute (selected tracks)', { { 'track: toggle mute for selected tracks' }, { 'toggle mute', 'selected tracks' } }),
  solo          = resolve('Toggle solo (selected tracks)', { { 'track: toggle solo for selected tracks' }, { 'toggle solo', 'selected tracks' } }),
  arm_toggle    = resolve('Toggle record arm (selected tracks)', { { 'toggle record arming' }, { 'arm/disarm record', 'selected' }, { 'record arm', 'selected tracks' } }),
  arm_on        = resolve('Record arm ON (selected tracks)', { { 'set record arming', 'selected' }, { 'arm record for selected' } }),
  fx_chain      = resolve('View FX chain (current track)', { { 'view fx chain' } }, 'current'),
  routing       = resolve('View routing (current track)', { { 'view routing' } }, 'current'),
  -- items
  -- NB: pattern order matters — the "in current time selection" variant must
  -- NOT win here, or Q only quantizes inside a time selection
  sel_items_trk = resolve('Select all items in selected track(s)', { { 'track: select all items in track' }, { 'select all items in track' }, { 'select all items on selected track' } }),
  unsel_items   = resolve('Unselect all items', { { 'unselect (clear selection of) all items' }, { 'item: unselect all items' }, { 'unselect all items' } }),
  grab          = resolve('Select items under edit cursor on selected tracks', { { 'select items under edit cursor on selected tracks' } }),
  item_next     = resolve('Select and move to next item', { { 'select and move to next item' } }),
  item_prev     = resolve('Select and move to previous item', { { 'select and move to previous item' } }),
  item_start    = resolve('Move cursor to start of items', { { 'move cursor to start of items' } }),
  duplicate     = resolve('Duplicate items', { { 'item: duplicate items' } }),
  split         = resolve('Split items at edit/play cursor', { { 'split items at edit or play cursor' } }),
  midi_editor   = resolve('Open in built-in MIDI editor', { { 'open in built-in midi editor' } }),
  nudge_right   = resolve('Move items right by grid', { { 'move items/envelope points right by grid' }, { 'nudge items right', 'grid' } }),
  nudge_left    = resolve('Move items left by grid', { { 'move items/envelope points left by grid' }, { 'nudge items left', 'grid' } }),
  -- grid divisions (arrange)
  g4   = resolve('Grid 1/4', { { 'grid: set to 1/4' } }),
  g8   = resolve('Grid 1/8', { { 'grid: set to 1/8' } }),
  g16  = resolve('Grid 1/16', { { 'grid: set to 1/16' } }),
  g32  = resolve('Grid 1/32', { { 'grid: set to 1/32' } }),
  g8t  = resolve('Grid 1/8 triplet', { { 'grid: set to 1/12' }, { 'grid', '1/8 triplet' } }),
  g16t = resolve('Grid 1/16 triplet', { { 'grid: set to 1/24' }, { 'grid', '1/16 triplet' } }),
  -- relative grid adjust (the numpad keys, bound in EVERY mode so they can
  -- never be shadowed again - a stray alt-1 ShotSwap binding on Num+ was
  -- why grid adjust "randomly" stopped working in MIX)
  grid_x2    = resolve('Grid adjust x2', { { 'grid', 'adjust by 2' }, { 'multiply grid size by 2' } }),
  grid_half  = resolve('Grid adjust /2', { { 'grid', 'adjust by 1/2' }, { 'multiply grid size by 1/2' } }),
  grid_x3    = resolve('Grid adjust x3', { { 'grid', 'adjust by 3' }, { 'multiply grid size by 3' } }),
  grid_third = resolve('Grid adjust /3', { { 'grid', 'adjust by 1/3' }, { 'multiply grid size by 1/3' } }),
  -- recording
  monitor    = resolve('Toggle record monitoring', { { 'toggle record monitoring' }, { 'cycle track record monitor' } }),
  preroll    = resolve('Toggle pre-roll on record', { { 'toggle pre-roll on record' }, { 'pre-roll on record' } }),
  rec_normal = resolve('Record mode: normal', { { 'record mode: normal' }, { 'set record mode to normal' } }),
  rec_punch  = resolve('Record mode: auto-punch time selection', { { 'record mode to time selection auto-punch' }, { 'time selection auto-punch' }, { 'record mode: auto-punch' }, { 'auto-punch' } }),
  rec_punch_items = resolve('Record mode: auto-punch selected items', { { 'auto-punch selected items' } }),
  take_next  = resolve('Switch items to next take', { { 'switch items to next take' } }),
  take_prev  = resolve('Switch items to previous take', { { 'switch items to previous take' } }),
  lanes      = resolve('Toggle fixed item lanes', { { 'toggle fixed item lanes' }, { 'fixed item lanes' } }, 'toggle'),
  crop_take  = resolve('Crop to active take', { { 'crop to active take' } }),
  tsel_start = resolve('Time selection: set start point', { { 'time selection: set start point' } }),
  tsel_end   = resolve('Time selection: set end point', { { 'time selection: set end point' } }),
  -- automation
  env_vol   = resolve('Toggle volume envelope visible', { { 'toggle track volume envelope visible' }, { 'volume envelope', 'visible' } }),
  env_pan   = resolve('Toggle pan envelope visible', { { 'toggle track pan envelope visible' }, { 'pan envelope', 'visible' } }),
  am_trim   = resolve('Automation mode: trim/read', { { 'automation mode to trim' } }),
  am_read   = resolve('Automation mode: read', { { 'automation mode to read' } }),
  am_touch  = resolve('Automation mode: touch', { { 'automation mode to touch' } }),
  am_write  = resolve('Automation mode: write', { { 'automation mode to write' } }),
  am_latch  = resolve('Automation mode: latch', { { 'automation mode to latch' } }, 'latch preview'),
  env_pt    = resolve('Envelope: insert point at cursor', { { 'insert new point at current position' } }),
  env_next  = resolve('Move cursor to next envelope point', { { 'move edit cursor to next envelope point' }, { 'next envelope point' } }),
  env_prev  = resolve('Move cursor to previous envelope point', { { 'move edit cursor to previous envelope point' }, { 'previous envelope point' } }),
  -- v0.5 additions (curated from X-Raym's action list dump)
  -- MIX: ReaConsole typed values + master volume
  console_vol = resolve("Console 'V' set track volume", { { "open console with 'v' to set track(s) volume" } }),
  console_pan = resolve("Console 'P' set track pan", { { "open console with 'p' to set track(s) pan" } }),
  master_up   = resolve('Nudge master +1 dB', { { 'nudge master output 1 volume +1db' } }),
  master_dn   = resolve('Nudge master -1 dB', { { 'nudge master output 1 volume -1db' } }),
  master_0    = resolve('Master to 0 dB', { { 'set master output 1 volume to 0db' } }),
  -- EDIT: transient nav, 2D item walk, item pitch, grid snap, razor, groove
  trans_next    = resolve('Cursor to next transient', { { 'item navigation: move cursor to next transient in items' }, { 'move cursor to next transient' } }),
  trans_prev    = resolve('Cursor to previous transient', { { 'item navigation: move cursor to previous transient in items' }, { 'move cursor to previous transient' } }),
  item_trk_next = resolve('Select & move to item in next track', { { 'item navigation: select and move to item in next track' } }),
  item_trk_prev = resolve('Select & move to item in previous track', { { 'item navigation: select and move to item in previous track' } }),
  pitch_up      = resolve('Pitch item +1 semitone', { { 'item properties: pitch item up one semitone' } }),
  pitch_dn      = resolve('Pitch item -1 semitone', { { 'item properties: pitch item down one semitone' } }),
  pitch_up_c    = resolve('Pitch item +1 cent', { { 'item properties: pitch item up one cent' } }),
  pitch_dn_c    = resolve('Pitch item -1 cent', { { 'item properties: pitch item down one cent' } }),
  snap_items    = resolve("Quantize item start to grid (keep length)", { { "quantize item's start to grid (keep length)" } }),
  split_sm      = resolve('Split items at stretch markers', { { 'split selected items at stretch markers' } }),
  razor_enc     = resolve('Razor: enclose media items', { { 'razor edit: enclose media items' } }),
  razor_clr     = resolve('Razor: clear all areas', { { 'razor edit: clear all areas' } }),
  razor_up      = resolve('Razor: move areas up', { { 'razor edit: move areas up without contents' } }),
  razor_dn      = resolve('Razor: move areas down', { { 'razor edit: move areas down without contents' } }),
  groove_get    = resolve('FNG: get groove from items', { { 'get groove from selected media items' } }),
  groove_apply  = resolve('FNG: apply groove to items (16th)', { { 'apply groove to selected media items (within 16th)' } }),
  -- REC: fixed-lane comping without the mouse
  comp_up    = resolve('Comp area up (selected items)', { { 'fixed lane comp area: move comp area up for selected items' } }),
  comp_dn    = resolve('Comp area down (selected items)', { { 'fixed lane comp area: move comp area down for selected items' } }),
  comp_split = resolve('Split comp area at edit cursor', { { 'fixed lane comp area: split comp area at edit cursor' } }),
  comp_top   = resolve('Move active comp to top lane', { { 'comp takes: move active comp to top lane' } }),
  comp_loop  = resolve('Loop points to comp area', { { 'fixed lane comp area: set loop points to comp area' } }),
  -- AUTO: automation-rectangle workflow + typed point values
  env_rect  = resolve('Insert 4 envelope points at time selection', { { 'envelope: insert 4 envelope points at time selection' } }),
  env_value = resolve('Add/edit envelope point value at cursor', { { 'envelope: add/edit envelope point value at cursor' } }),
  env_pull  = resolve('Move closest envelope point to edit cursor', { { 'move closest envelope point to edit cursor' } }),
  -- mode switches
  alt1    = resolve('Toggle override to alt-1', { { 'main action section', 'alt-1' } }, 'toggle'),
  alt2    = resolve('Toggle override to alt-2', { { 'main action section', 'alt-2' } }, 'toggle'),
  alt3    = resolve('Toggle override to alt-3', { { 'main action section', 'alt-3' } }, 'toggle'),
  alt4    = resolve('Toggle override to alt-4', { { 'main action section', 'alt-4' } }, 'toggle'),
  alt_off = resolve('Override back to default', { { 'main action section', 'default' }, { 'main action section', 'remove' }, { 'main action section', 'clear' } }),
}

-- MIDI editor section actions
local M = {
  quant_last = resolve('MIDI: quantize using last settings', { { 'quantize events using last quantize dialog settings' } }, nil, midiacts),
  quant_dlg  = resolve('MIDI: quantize dialog', { { 'quantize events...' }, { 'quantize notes...' } }, nil, midiacts),
  humanize   = resolve('MIDI: humanize notes', { { 'humanize notes' } }, nil, midiacts),
  vel_up10   = resolve('MIDI: velocity +10', { { 'note velocity +10' } }, nil, midiacts),
  vel_dn10   = resolve('MIDI: velocity -10', { { 'note velocity -10' } }, nil, midiacts),
  vel_up1    = resolve('MIDI: velocity +1', { { 'note velocity +01' }, { 'note velocity +1' } }, nil, midiacts),
  vel_dn1    = resolve('MIDI: velocity -1', { { 'note velocity -01' }, { 'note velocity -1' } }, nil, midiacts),
  g4   = resolve('MIDI grid 1/4', { { 'grid: set to 1/4' } }, nil, midiacts),
  g8   = resolve('MIDI grid 1/8', { { 'grid: set to 1/8' } }, nil, midiacts),
  g16  = resolve('MIDI grid 1/16', { { 'grid: set to 1/16' } }, nil, midiacts),
  g32  = resolve('MIDI grid 1/32', { { 'grid: set to 1/32' } }, nil, midiacts),
  g8t  = resolve('MIDI grid 1/8T', { { 'grid: set to 1/12' }, { 'grid', '1/8 triplet' } }, nil, midiacts),
  g16t = resolve('MIDI grid 1/16T', { { 'grid: set to 1/24' }, { 'grid', '1/16 triplet' } }, nil, midiacts),
  -- v0.5 additions
  legato = resolve('MIDI: make notes legato (keep starts)', { { 'edit: make notes legato, preserving note start times' } }, nil, midiacts),
  groove = resolve('MIDI: apply groove (16th)', { { 'apply groove to selected midi notes (within 16th)' } }, nil, midiacts),
  -- v0.6: complete the numpad grid set (Num +/-/* already bound by hand)
  grid_third = resolve('MIDI: grid /3', { { 'multiply grid size by 1/3' }, { 'grid', 'adjust by 1/3' } }, nil, midiacts),
}

-- register a ReaScript (by path under Scripts/) and return its keymap token
local function scriptToken(rel)
  local path = r.GetResourcePath() .. '/Scripts/' .. rel
  local f = io.open(path, 'rb')
  if not f then
    unresolved[#unresolved + 1] = rel
    return nil
  end
  f:close()
  local cmd = r.AddRemoveReaScript(true, 0, path, true)
  if cmd and cmd ~= 0 then
    local named = r.ReverseNamedCommandLookup(cmd)
    if named then return '_' .. named end
  end
  unresolved[#unresolved + 1] = rel
  return nil
end

local pq_token = scriptToken('PietosiQuantize/PietosiQuantize.lua')
local sc_token = scriptToken('PietosiKeys/PietosiKeys_Sidechain.lua')
local sd_next  = scriptToken('PietosiKeys/PietosiKeys_SendDestNext.lua')
local sd_prev  = scriptToken('PietosiKeys/PietosiKeys_SendDestPrev.lua')

-- glitch one-keys (auto-registered)
local G = {
  shuffle  = scriptToken('PietosiGlitch/PietosiGlitch_ShuffleSlices.lua'),
  reverse  = scriptToken('PietosiGlitch/PietosiGlitch_ReverseEveryOther.lua'),
  tapestop = scriptToken('PietosiGlitch/PietosiGlitch_TapeStopTail.lua'),
  buildup  = scriptToken('PietosiGlitch/PietosiGlitch_BuildupMachine.lua'),
  halftime = scriptToken('PietosiGlitch/PietosiGlitch_HalfTimeFlip.lua'),
  vocal    = scriptToken('PietosiGlitch/PietosiGlitch_VocalChopGen.lua'),
  wsplit   = scriptToken('PietosiUtils/PietosiWheelSplit.lua'),
  shotswap = scriptToken('PietosiUtils/PietosiShotSwap.lua'),
}

-- MIX palette: select track 1-8 directly
local selTrack = {}
for n = 1, 8 do
  selTrack[n] = resolve(('Select track %02d'):format(n),
    { { ('track: select track %02d'):format(n) } })
end

------------------------------------------------------------- keymap output

local DEFAULT, ALT1, ALT2, ALT3, ALT4 = 0, 1, 2, 3, 4
-- modifier byte: base 1, +4 shift, +8 ctrl, +16 alt (verified via kb.ini comments)
local NONE, SHIFT, CTRL, ALT, ALTSHIFT = 1, 5, 9, 17, 21
local CTRLSHIFT = 13
local VK = {
  space = 32, enter = 13, esc = 27, tab = 9, grave = 192,
  -- real (extended) navigation keys are VK+32768 in keymap files; plain
  -- 37..40 would bind the NUMPAD arrows (verified against reaper-kb.ini)
  left = 32768 + 37, up = 32768 + 38, right = 32768 + 39, down = 32768 + 40,
  del = 32768 + 46,
  comma = 188, period = 190, lbracket = 219, rbracket = 221, apostrophe = 222,
  numplus = 107, numminus = 109, nummul = 106, numdiv = 111,
}
for c in ('ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789'):gmatch('.') do
  VK[c] = string.byte(c)
end

local out = {}
local report = {}

local function act(id, name, tokens)
  local ok = {}
  for _, t in ipairs(tokens) do
    if t then ok[#ok + 1] = t end
  end
  if #ok < #tokens then return nil end -- a component is missing; skip macro
  out[#out + 1] = ('ACT 3 0 "%s" "Custom: %s" %s'):format(id, name, table.concat(ok, ' '))
  return '_' .. id
end

local function key(mod, vk, tok, section, desc)
  if not tok then
    report[#report + 1] = ('  SKIPPED  %s (action not found)'):format(desc)
    return
  end
  out[#out + 1] = ('KEY %d %d %s %d'):format(mod, vk, tok, section)
  report[#report + 1] = ('  %s'):format(desc)
end

-- custom actions -----------------------------------------------------------
local onecur = act('PietosiOneCursor', 'Pietosi play/stop (one cursor)',
  { token(A.edit_to_play), token(A.play_stop) })
local quant = pq_token and act('PietosiQuantTrack', 'Pietosi quantize selected track items',
  { token(A.unsel_items), token(A.sel_items_trk), pq_token }) or nil
local recarm = act('PietosiRecordArm', 'Pietosi record (auto-arm selected track)',
  { token(A.arm_on) or token(A.arm_toggle), token(A.record) })

-- default section: minimal, stock keymap otherwise untouched ---------------
report[#report + 1] = 'DEFAULT section:'
key(NONE, VK.space, onecur or token(A.play_stop), DEFAULT, 'Space        one-cursor play/stop')
key(NONE, VK.grave, token(A.alt1), DEFAULT, '` (grave)    enter MIX mode (alt-1)')

-- wheel gadgets, bound in the main section so they work in every mode
-- (gesture encodings verified against this machine's reaper-kb.ini)
local WHEEL = 255
local wstut   = scriptToken('PietosiGlitch/PietosiGlitch_WheelStutter.lua')
local wladder = scriptToken('PietosiGlitch/PietosiGlitch_WheelPitchLadder.lua')
local wgate   = scriptToken('PietosiGlitch/PietosiGlitch_WheelGateChop.lua')
key(WHEEL, 249, wstut, DEFAULT, 'Ctrl+Wheel   WheelStutter')
key(WHEEL, 250, wladder, DEFAULT, 'Alt+Wheel    WheelPitchLadder')
key(WHEEL, 2044, wgate, DEFAULT, 'Shift+Wheel  WheelGateChop')

-- unified shared block: emitted IDENTICALLY into all four mode sections -----
-- skip.X: REC re-skins X as comp-split; skip.I: AUTO re-skins I as env point;
-- skip.C: REC re-skins C as crop-to-take
local function shared(sec, skip)
  skip = skip or {}
  -- navigation (Left/Right stay unbound on purpose -> native scrub)
  key(NONE, VK.up, token(A.prev_track), sec, 'Up           previous track')
  key(NONE, VK.down, token(A.next_track), sec, 'Down         next track')
  key(CTRL, VK.left, token(A.item_prev), sec, 'Ctrl+Left    select & move to previous item')
  key(CTRL, VK.right, token(A.item_next), sec, 'Ctrl+Right   select & move to next item')
  key(CTRL, VK.up, token(A.item_trk_prev), sec, 'Ctrl+Up      item in previous track')
  key(CTRL, VK.down, token(A.item_trk_next), sec, 'Ctrl+Down    item in next track')
  key(ALT, VK.left, token(A.trans_prev), sec, 'Alt+Left     previous transient')
  key(ALT, VK.right, token(A.trans_next), sec, 'Alt+Right    next transient')
  -- shared verbs
  key(SHIFT, VK.up, token(A.vol_up), sec, 'Shift+Up     track volume up')
  key(SHIFT, VK.down, token(A.vol_down), sec, 'Shift+Down   track volume down')
  key(SHIFT, VK.left, token(A.pan_left), sec, 'Shift+Left   pan left')
  key(SHIFT, VK.right, token(A.pan_right), sec, 'Shift+Right  pan right')
  key(ALT, VK.up, token(A.pitch_up), sec, 'Alt+Up       pitch item +1 semitone')
  key(ALT, VK.down, token(A.pitch_dn), sec, 'Alt+Down     pitch item -1 semitone')
  key(CTRLSHIFT, VK.up, token(A.pitch_up_c), sec, 'Ctrl+Shift+Up   pitch item +1 cent')
  key(CTRLSHIFT, VK.down, token(A.pitch_dn_c), sec, 'Ctrl+Shift+Down pitch item -1 cent')
  key(NONE, VK.M, token(A.mute), sec, 'M            toggle mute')
  key(NONE, VK.S, token(A.solo), sec, 'S            toggle solo')
  key(NONE, VK.R, recarm, sec, 'R            record (auto-arms selected track)')
  key(SHIFT, VK.R, token(A.arm_toggle), sec, 'Shift+R      toggle record arm')
  key(SHIFT, VK.M, token(A.monitor), sec, 'Shift+M      toggle input monitoring')
  key(NONE, VK.G, token(A.grab), sec, 'G            grab item(s) under cursor')
  if not skip.X then
    key(NONE, VK.X, token(A.split), sec, 'X            split at cursor')
    key(SHIFT, VK.X, token(A.split_sm), sec, 'Shift+X      split items at stretch markers')
  end
  key(NONE, VK.D, token(A.duplicate), sec, 'D            duplicate items')
  key(NONE, VK.Z, token(A.razor_enc), sec, 'Z            razor area around selected items')
  key(SHIFT, VK.Z, token(A.razor_clr), sec, 'Shift+Z      clear all razor areas')
  key(ALTSHIFT, VK.up, token(A.razor_up), sec, 'Alt+Shift+Up   move razor areas up')
  key(ALTSHIFT, VK.down, token(A.razor_dn), sec, 'Alt+Shift+Down move razor areas down')
  key(NONE, VK.Q, quant, sec, 'Q            quantize track items (PietosiQuantize)')
  key(SHIFT, VK.Q, token(A.snap_items), sec, 'Shift+Q      snap item starts to grid (keep length)')
  key(NONE, VK.F, token(A.fx_chain), sec, 'F            FX chain window')
  key(NONE, VK.tab, token(A.fx_chain), sec, 'Tab          FX chain window')
  if not skip.I then
    key(NONE, VK.I, token(A.routing), sec, 'I            routing window')
  end
  if not skip.C then
    key(NONE, VK.C, sc_token, sec, 'C            sidechain picker')
  end
  key(NONE, VK['0'], token(A.vol_reset), sec, '0            reset track volume to 0 dB')
  key(SHIFT, VK['0'], token(A.master_0), sec, 'Shift+0      master volume to 0 dB')
  key(SHIFT, VK['1'], token(A.g4), sec, 'Shift+1      grid 1/4')
  key(SHIFT, VK['2'], token(A.g8), sec, 'Shift+2      grid 1/8')
  key(SHIFT, VK['3'], token(A.g16), sec, 'Shift+3      grid 1/16')
  key(SHIFT, VK['4'], token(A.g32), sec, 'Shift+4      grid 1/32')
  key(SHIFT, VK['5'], token(A.g8t), sec, 'Shift+5      grid 1/8 triplet')
  key(SHIFT, VK['6'], token(A.g16t), sec, 'Shift+6      grid 1/16 triplet')
  key(NONE, VK.numplus, token(A.grid_x2), sec, 'Num +        grid size x2')
  key(NONE, VK.numminus, token(A.grid_half), sec, 'Num -        grid size /2')
  key(NONE, VK.nummul, token(A.grid_x3), sec, 'Num *        grid size x3')
  key(NONE, VK.numdiv, token(A.grid_third), sec, 'Num /        grid size /3')
  -- mode switching, same from everywhere; Esc backs out one level
  if sec ~= ALT2 then
    key(NONE, VK.enter, token(A.alt2), sec, 'Enter        -> EDIT mode')
  end
  if sec ~= ALT3 then
    key(NONE, VK.W, token(A.alt3), sec, 'W            -> REC mode')
  end
  if sec ~= ALT4 then
    key(NONE, VK.A, token(A.alt4), sec, 'A            -> AUTOMATION mode')
  end
  if sec == ALT1 then
    key(NONE, VK.esc, token(A.alt_off), sec, 'Esc          -> stock keymap')
  else
    key(NONE, VK.esc, token(A.alt1), sec, 'Esc          -> back to MIX mode')
  end
end

-- MIX mode (alt-1): palette = select track 1-8 --------------------------------
report[#report + 1] = 'MIX mode (Main alt-1) = shared block plus:'
shared(ALT1)
for n = 1, 8 do
  key(NONE, VK[tostring(n)], token(selTrack[n]), ALT1,
    ('%d            select track %d'):format(n, n))
end
key(NONE, VK.V, token(A.console_vol), ALT1, 'V            type track volume (ReaConsole)')
key(NONE, VK.P, token(A.console_pan), ALT1, 'P            type track pan (ReaConsole)')
key(NONE, VK.rbracket, sd_next, ALT1, ']            last send dest chans up (1/2 -> 3/4 ...)')
key(NONE, VK.lbracket, sd_prev, ALT1, '[            last send dest chans down')

-- EDIT mode (alt-2): palette = glitch one-keys --------------------------------
report[#report + 1] = 'EDIT mode (Main alt-2) = shared block plus:'
shared(ALT2)
key(NONE, VK['1'], G.shuffle, ALT2, '1            glitch: shuffle slices')
key(NONE, VK['2'], G.reverse, ALT2, '2            glitch: reverse every other slice')
key(NONE, VK['3'], G.tapestop, ALT2, '3            glitch: tape stop tail')
key(NONE, VK['4'], G.buildup, ALT2, '4            glitch: buildup machine')
key(NONE, VK['5'], G.halftime, ALT2, '5            glitch: half-time flip')
key(NONE, VK['6'], G.vocal, ALT2, '6            glitch: vocal chop gen')
key(NONE, VK['7'], G.wsplit, ALT2, '7            glitch: wheel split (one more slice)')
key(SHIFT, VK.apostrophe, G.shotswap, ALT2, "Shift+'      ShotSwap (random one-shots from DB)")
key(NONE, VK.enter, token(A.item_start), ALT2, 'Enter        cursor to start of selected item')
key(NONE, VK.comma, token(A.nudge_left), ALT2, ',            nudge items left by grid')
key(NONE, VK.period, token(A.nudge_right), ALT2, '.            nudge items right by grid')
key(NONE, VK.E, token(A.midi_editor), ALT2, 'E            open in MIDI editor')
key(NONE, VK.V, token(A.groove_get), ALT2, 'V            get groove from selected items')
key(SHIFT, VK.V, token(A.groove_apply), ALT2, 'Shift+V      apply groove to selected items (16th)')

-- REC mode (alt-3): palette = record modes ------------------------------------
report[#report + 1] = 'REC mode (Main alt-3) = shared block plus:'
shared(ALT3, { X = true, C = true })
key(NONE, VK['1'], token(A.rec_normal), ALT3, '1            record mode: normal (loop = takes)')
key(NONE, VK['2'], token(A.rec_punch), ALT3, '2            record mode: auto-punch time selection')
key(NONE, VK['3'], token(A.rec_punch_items), ALT3, '3            record mode: auto-punch selected items')
key(NONE, VK.P, token(A.preroll), ALT3, 'P            toggle pre-roll on record')
key(NONE, VK.O, token(A.repeat_tgl), ALT3, 'O            toggle repeat/loop')
key(NONE, VK.lbracket, token(A.tsel_start), ALT3, '[            time selection start (punch-in)')
key(NONE, VK.rbracket, token(A.tsel_end), ALT3, ']            time selection end (punch-out)')
key(NONE, VK.comma, token(A.take_prev), ALT3, ',            previous take')
key(NONE, VK.period, token(A.take_next), ALT3, '.            next take')
key(NONE, VK.L, token(A.lanes), ALT3, 'L            toggle fixed item lanes (comping)')
key(SHIFT, VK.L, token(A.comp_loop), ALT3, 'Shift+L      loop points to comp area')
key(NONE, VK.C, token(A.crop_take), ALT3, 'C            crop to active take')
key(NONE, VK.X, token(A.comp_split), ALT3, 'X            split comp area at edit cursor')
key(NONE, VK.T, token(A.comp_top), ALT3, 'T            move active comp to top lane')
key(SHIFT, VK.T, token(A.comp_up), ALT3, 'Shift+T      move comp area up (selected items)')
key(CTRLSHIFT, VK.T, token(A.comp_dn), ALT3, 'Ctrl+Shift+T move comp area down (selected items)')

-- AUTOMATION mode (alt-4): palette = automation modes -------------------------
report[#report + 1] = 'AUTOMATION mode (Main alt-4) = shared block plus:'
shared(ALT4, { I = true })
key(NONE, VK['1'], token(A.am_trim), ALT4, '1            automation: trim/read')
key(NONE, VK['2'], token(A.am_read), ALT4, '2            automation: read')
key(NONE, VK['3'], token(A.am_touch), ALT4, '3            automation: touch')
key(NONE, VK['4'], token(A.am_write), ALT4, '4            automation: write')
key(NONE, VK['5'], token(A.am_latch), ALT4, '5            automation: latch')
key(NONE, VK.V, token(A.env_vol), ALT4, 'V            toggle volume envelope visible')
key(NONE, VK.P, token(A.env_pan), ALT4, 'P            toggle pan envelope visible')
key(NONE, VK.I, token(A.env_pt), ALT4, 'I            insert envelope point at cursor')
key(SHIFT, VK.I, token(A.env_rect), ALT4, 'Shift+I      insert 4 points at time selection (rectangle)')
key(NONE, VK.E, token(A.env_value), ALT4, 'E            type envelope point value at cursor')
key(NONE, VK.N, token(A.env_pull), ALT4, 'N            pull nearest envelope point to cursor')
key(NONE, VK.lbracket, token(A.tsel_start), ALT4, '[            time selection start')
key(NONE, VK.rbracket, token(A.tsel_end), ALT4, ']            time selection end')
key(NONE, VK.comma, token(A.env_prev), ALT4, ',            previous envelope point')
key(NONE, VK.period, token(A.env_next), ALT4, '.            next envelope point')

-- MIDI editor section -------------------------------------------------------
report[#report + 1] = 'MIDI editor section:'
key(NONE, VK.Q, token(M.quant_last), MIDI_SEC, 'Q            quantize (last settings)')
key(SHIFT, VK.Q, token(M.quant_dlg), MIDI_SEC, 'Shift+Q      quantize dialog')
key(NONE, VK.H, token(M.humanize), MIDI_SEC, 'H            humanize notes')
key(ALT, VK.up, token(M.vel_up10), MIDI_SEC, 'Alt+Up       velocity +10')
key(ALT, VK.down, token(M.vel_dn10), MIDI_SEC, 'Alt+Down     velocity -10')
key(ALTSHIFT, VK.up, token(M.vel_up1), MIDI_SEC, 'Alt+Shift+Up velocity +1')
key(ALTSHIFT, VK.down, token(M.vel_dn1), MIDI_SEC, 'Alt+Shift+Dn velocity -1')
key(NONE, VK['1'], token(M.g4), MIDI_SEC, '1            grid 1/4')
key(NONE, VK['2'], token(M.g8), MIDI_SEC, '2            grid 1/8')
key(NONE, VK['3'], token(M.g16), MIDI_SEC, '3            grid 1/16')
key(NONE, VK['4'], token(M.g32), MIDI_SEC, '4            grid 1/32')
key(NONE, VK['5'], token(M.g8t), MIDI_SEC, '5            grid 1/8 triplet')
key(NONE, VK['6'], token(M.g16t), MIDI_SEC, '6            grid 1/16 triplet')
key(NONE, VK.L, token(M.legato), MIDI_SEC, 'L            make notes legato (keep starts, 808 glide prep)')
key(NONE, VK.G, token(M.groove), MIDI_SEC, 'G            apply FNG groove to selected notes (16th)')
key(NONE, VK.numdiv, token(M.grid_third), MIDI_SEC, 'Num /        grid size /3')

------------------------------------------------------------------ write out

local dir = r.GetResourcePath() .. '/KeyMaps'
r.RecursiveCreateDirectory(dir, 0)
local path = dir .. '/PietosiKeys.ReaperKeyMap'
local fh = io.open(path, 'wb')
if not fh then
  r.MB('Could not write ' .. path, 'PietosiKeys', 0)
  return
end
fh:write(table.concat(out, '\n') .. '\n')
fh:close()

log('')
for _, line in ipairs(report) do log(line) end
log('')
if #unresolved > 0 then
  log('NOT FOUND on this machine (bindings skipped):')
  for _, u in ipairs(unresolved) do log('  - ' .. u) end
  log('')
end
log('Wrote: ' .. path)
log('')
log('TO INSTALL:')
log('  1. (Optional, recommended) Actions window > Key map... > Export all,')
log('     to keep a restore point of your current bindings.')
log('  2. Actions window > Key map... > Import... > PietosiKeys.ReaperKeyMap')
log('  3. ` (grave) = MIX. Enter = EDIT, W = REC, A = AUTOMATION - from ANY mode.')
log('     Esc always backs out one level. MIDI editor keys work when it is open.')
log('')
log('v0.6 UNIFIED: navigation + shared verbs are the same keys in every mode;')
log('only the number row (the palette) and a few mode letters change.')
