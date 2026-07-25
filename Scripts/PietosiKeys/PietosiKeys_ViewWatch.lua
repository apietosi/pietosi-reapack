-- @description PietosiKeys ViewWatch - per-mode track view (vertical mixer / lean playlist)
-- @version 0.3.0
-- @author pie
-- @provides [main=main] .
-- @about
--   Background watcher pairing the track view with the PietosiKeys modes:
--   MIX  (alt-1): every track is at least MIX_MIN_H px tall, so the TCP shows
--                 fader/meter on each strip - the panel becomes a vertical
--                 mixer, with each strip on the same row as its own lane.
--   EDIT (alt-2): tracks with no items are minimized (or hidden, see
--                 EMPTY_MODE), so the playlist only shows editable lanes.
--   Leaving a mode restores every track exactly as it was. Rescans every
--   1.5 s, so tracks pop back the moment they gain items. State lives in
--   track P_EXT (survives project save/reload). If MIX_LAYOUT/EDIT_LAYOUT
--   name TCP layouts of the current theme, they're applied per mode too.
--   Auto-started from __startup.lua.

local r = reaper

if not r.APIExists('CF_EnumerateActions') then return end

local EMPTY_MODE = 'min' -- 'min' squashes empty tracks; 'hide' removes them from arrange
local MIX_MIN_H  = 64    -- px: minimum strip height in MIX mode (fader visible)
-- TCP layouts applied per mode (defined by the PietosiTheme; harmless no-op
-- fallback to the default layout when another theme is active)
local MIX_LAYOUT  = 'PietosiMix'
local EDIT_LAYOUT = 'PietosiEdit'
local RESCAN_SEC = 1.5

-- whole-window transformation: load a saved screenset (window set) per mode.
-- Save them once in REAPER: arrange the windows how a mode should look, then
-- run "Screenset: Save window set #N". 0 = don't touch windows for that mode.
local SCREENSETS = { mix = 1, edit = 2, rec = 3, auto = 4, stock = 0 }

-- resolve the mode-toggle actions and screenset loaders by name
local mode_cmds = {} -- { mix=cmd, edit=cmd, rec=cmd, auto=cmd }
local ss_load = {}   -- [1..4] = load-window-set command
for i = 0, 200000 do
  local cmd, name = r.CF_EnumerateActions(0, i, '')
  if not cmd or cmd <= 0 then break end
  local l = (name or ''):lower()
  if l:find('main action section', 1, true) and l:find('toggle', 1, true) then
    if l:find('alt-1', 1, true) then mode_cmds.mix = cmd end
    if l:find('alt-2', 1, true) then mode_cmds.edit = cmd end
    if l:find('alt-3', 1, true) then mode_cmds.rec = cmd end
    if l:find('alt-4', 1, true) then mode_cmds.auto = cmd end
  elseif l:find('screenset', 1, true) and l:find('load window set', 1, true) then
    for n = 1, 4 do
      if l:find('#0' .. n, 1, true) or l:find('#' .. n, 1, true) then
        ss_load[n] = ss_load[n] or cmd
      end
    end
  end
end
if not (mode_cmds.mix and mode_cmds.edit) then return end

local K_EDIT, K_MIX, K_LAY = 'P_EXT:PKVIEW', 'P_EXT:PKMIX', 'P_EXT:PKLAY'

local function getExt(tr, key)
  local _, v = r.GetSetMediaTrackInfo_String(tr, key, '', false)
  return v
end
local function setExt(tr, key, v)
  r.GetSetMediaTrackInfo_String(tr, key, v, true)
end

------------------------------------------------- EDIT: minimize empty tracks

local function shrinkEmpty(tr)
  if getExt(tr, K_EDIT) ~= '' then return false end
  if EMPTY_MODE == 'hide' then
    setExt(tr, K_EDIT, 'v' .. math.floor(r.GetMediaTrackInfo_Value(tr, 'B_SHOWINTCP')))
    r.SetMediaTrackInfo_Value(tr, 'B_SHOWINTCP', 0)
  else
    setExt(tr, K_EDIT, 'h' .. math.floor(r.GetMediaTrackInfo_Value(tr, 'I_HEIGHTOVERRIDE')))
    r.SetMediaTrackInfo_Value(tr, 'I_HEIGHTOVERRIDE', 1)
  end
  return true
end

local function unshrink(tr)
  local saved = getExt(tr, K_EDIT)
  if saved == '' then return false end
  local kind, val = saved:sub(1, 1), tonumber(saved:sub(2)) or 0
  if kind == 'v' then
    r.SetMediaTrackInfo_Value(tr, 'B_SHOWINTCP', val)
  else
    r.SetMediaTrackInfo_Value(tr, 'I_HEIGHTOVERRIDE', val)
  end
  setExt(tr, K_EDIT, '')
  return true
end

--------------------------------------------- MIX: guarantee mixer-height TCP

local function mixify(tr)
  if getExt(tr, K_MIX) ~= '' then return false end
  if r.GetMediaTrackInfo_Value(tr, 'I_TCPH') >= MIX_MIN_H then return false end
  setExt(tr, K_MIX, tostring(math.floor(r.GetMediaTrackInfo_Value(tr, 'I_HEIGHTOVERRIDE'))))
  r.SetMediaTrackInfo_Value(tr, 'I_HEIGHTOVERRIDE', MIX_MIN_H)
  return true
end

local function unmixify(tr)
  local saved = getExt(tr, K_MIX)
  if saved == '' then return false end
  r.SetMediaTrackInfo_Value(tr, 'I_HEIGHTOVERRIDE', tonumber(saved) or 0)
  setExt(tr, K_MIX, '')
  return true
end

-------------------------------------------------- optional theme TCP layouts

local function stampLayout(tr, want)
  local cur = ({ r.GetSetMediaTrackInfo_String(tr, 'P_TCP_LAYOUT', '', false) })[2]
  if want ~= '' then
    if cur ~= want then
      if getExt(tr, K_LAY) == '' then setExt(tr, K_LAY, '=' .. cur) end
      r.GetSetMediaTrackInfo_String(tr, 'P_TCP_LAYOUT', want, true)
      return true
    end
  else
    local saved = getExt(tr, K_LAY)
    if saved ~= '' then
      r.GetSetMediaTrackInfo_String(tr, 'P_TCP_LAYOUT', saved:sub(2), true)
      setExt(tr, K_LAY, '')
      return true
    end
  end
  return false
end

--------------------------------------------------------------------- watcher

local function applyMode(mode)
  local changed = false
  for i = 0, r.CountTracks(0) - 1 do
    local tr = r.GetTrack(0, i)
    if mode == 'edit' then
      changed = unmixify(tr) or changed
      if r.CountTrackMediaItems(tr) == 0 then
        changed = shrinkEmpty(tr) or changed
      else
        changed = unshrink(tr) or changed
      end
      changed = stampLayout(tr, EDIT_LAYOUT) or changed
    elseif mode == 'mix' then
      changed = unshrink(tr) or changed
      changed = mixify(tr) or changed
      changed = stampLayout(tr, MIX_LAYOUT) or changed
    else
      changed = unshrink(tr) or changed
      changed = unmixify(tr) or changed
      changed = stampLayout(tr, '') or changed
    end
  end
  return changed
end

local cur_mode = nil
local next_scan = 0
local first_seen = true

local function loop()
  local now = os.clock()
  local mode
  if r.GetToggleCommandState(mode_cmds.edit) == 1 then mode = 'edit'
  elseif r.GetToggleCommandState(mode_cmds.mix) == 1 then mode = 'mix'
  elseif mode_cmds.rec and r.GetToggleCommandState(mode_cmds.rec) == 1 then mode = 'rec'
  elseif mode_cmds.auto and r.GetToggleCommandState(mode_cmds.auto) == 1 then mode = 'auto' end

  if mode ~= cur_mode then
    cur_mode = mode
    next_scan = 0
    -- whole-window switch: load the mode's saved screenset (skip the very
    -- first evaluation so starting REAPER doesn't rearrange windows)
    if not first_seen then
      local n = SCREENSETS[mode or 'stock'] or 0
      if n > 0 and ss_load[n] then r.Main_OnCommand(ss_load[n], 0) end
    end
    first_seen = false
  end

  if now >= next_scan then
    next_scan = now + RESCAN_SEC
    if applyMode(cur_mode) then
      r.TrackList_AdjustWindows(true)
      r.UpdateArrange()
    end
  end

  r.defer(loop)
end

r.defer(loop)
