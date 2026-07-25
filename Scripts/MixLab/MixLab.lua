-- @description MixLab - unified vertical arranger + mixer (Bitwig-style deck)
-- @version 0.10.1
-- @author pie
-- @provides [main=main] .
-- @about
--   One column per track: a vertical timeline lane on top (time flows downward)
--   and a mixer strip directly beneath it. Audio items render vertical waveforms
--   (stereo left/right split), MIDI items render as player-piano note punches.
--   Scroll time with the wheel, zoom with ctrl+wheel, pan columns with
--   shift+wheel. Click a lane to seek, click an item to select it, drag an item
--   vertically to move it in time, double-click a MIDI item to open it in the
--   MIDI editor. Keyboard: arrows switch tracks / trim volume, alt+arrows pan,
--   M/S/R/F mute/solo/arm/fx, Q quantize (PietosiQuantize), 0 resets volume,
--   Home rewinds, Space plays. Tab flips to the FX view: a full-window,
--   keyboard-navigable FX chain + routing editor for the selected track.
--   Dock it at the bottom of REAPER and it replaces mixer + playlist.

local r = reaper

if not r.ImGui_CreateContext then
  r.MB('MixLab needs the ReaImGui extension.\n\nInstall via ReaPack: Extensions > ReaPack > Browse packages > "ReaImGui".', 'MixLab', 0)
  return
end

------------------------------------------------------------------- settings

local function numSetting(key, def)
  return tonumber(r.GetExtState('MixLab', key)) or def
end

local pps    = numSetting('pps', 24)   -- vertical zoom: pixels per second
local colw   = numSetting('colw', 96)  -- column width
local follow = r.GetExtState('MixLab', 'follow') ~= '0'
local scrub_speed = numSetting('scrubspd', 0.5)         -- hold-arrow crawl rate (x realtime)
local one_cursor = r.GetExtState('MixLab', 'onecur') ~= '0' -- edit cursor lands where playback stops

local scroll_t     = 0     -- project time at the top of the lanes
local follow_hold  = false -- manual scroll during playback pauses follow until stop
local drag         = nil   -- { item, t0, my0, undo }
local pending_dock = nil
local scroll_to_track = nil

local scrub = nil          -- hold-arrow scrub state { pos, acc, dir }
local was_playing = false  -- transport state last frame (one-cursor watcher)
local last_play = 0        -- last observed play position

local view_mode = 'deck'   -- 'deck' (mix) | 'edit' (playlist) | 'fx'
local prev_view = 'deck'   -- where Tab left from, to return there
local fx_sel = 1           -- selected row in the FX view
local fx_nav = false       -- keyboard nav happened; keep selection scrolled into view
local fx_param_sel = 0     -- selected parameter in the FX view params pane
local fx_pnav = false      -- keyboard param nav; scroll param into view
local fx_pick = nil        -- routing picker { mode='send'|'recv'|'sc', filter, sel, fxidx }
local fx_pick_new = false  -- picker was just requested; open the popup
local fx_msg, fx_msg_t = nil, 0 -- transient status line in the FX view
local pq_cmd = nil         -- cached PietosiQuantize command id

local sep = package.config:sub(1, 1)
local resource = r.GetResourcePath()

local peakcache, pc_count = {}, 0 -- per-item vertical waveform peaks
local midicache, mc_count = {}, 0 -- per-take note rolls
local PEAK_STEP = 2               -- px per peak sample at current zoom

local RULER_W     = 44
local STRIP_H_MAX = 208
local MIN_COLW, MAX_COLW = 56, 220
local MIN_PPS, MAX_PPS   = 2, 600

local COL_MEASURE  = 0xFFFFFF26
local COL_BEAT     = 0xFFFFFF10
local COL_GRID     = 0x00F6FFE6 -- neon core: the project grid division
local COL_GRID_RIM = 0x002A33C8 -- dark rim under the neon line so it pops anywhere
local COL_SEP      = 0xFFFFFF14
local COL_ALTCOL   = 0xFFFFFF06
local COL_SELCOL   = 0xFFFFFF12
local COL_LOOP     = 0x3A86FF24
local COL_PLAY     = 0x53E06AFF
local COL_EDIT     = 0xFF9E3DFF
local COL_STRIPBG  = 0x22262BFF
local COL_TXT_DIM  = 0xFFFFFF88

local function save()
  r.SetExtState('MixLab', 'pps', tostring(pps), true)
  r.SetExtState('MixLab', 'colw', tostring(colw), true)
  r.SetExtState('MixLab', 'follow', follow and '1' or '0', true)
  r.SetExtState('MixLab', 'scrubspd', tostring(scrub_speed), true)
  r.SetExtState('MixLab', 'onecur', one_cursor and '1' or '0', true)
end

-------------------------------------------------------------------- helpers

local function clamp(v, lo, hi)
  if v < lo then return lo elseif v > hi then return hi else return v end
end

local function val2db(v)
  if v <= 0.0000001 then return -150 end
  return 20 * math.log(v, 10)
end

local function dbstr(v)
  local db = val2db(v)
  if db <= -149 then return '-inf' end
  return string.format('%+.1f', db)
end

local function maybeSnap(t)
  if r.GetToggleCommandState(1157) == 1 then return r.SnapToGrid(0, t) end
  return t
end

local function trackRGB(tr)
  local c = r.GetTrackColor(tr)
  if c == 0 then return 0x5A, 0x81, 0xAD end
  return r.ColorFromNative(c)
end

local function rgba(rr, gg, bb, aa)
  return (rr << 24) | (gg << 16) | (bb << 8) | aa
end

local function itemColor(it, tr)
  local c = r.GetDisplayedMediaItemColor(it) & 0xFFFFFF
  local rr, gg, bb
  if c == 0 then rr, gg, bb = trackRGB(tr) else rr, gg, bb = r.ColorFromNative(c) end
  return rr, gg, bb
end

-- iterate measures whose start lies in [t_top, t_bot]
local function eachMeasure(t_top, t_bot, fn)
  local _, m0 = r.TimeMap2_timeToBeats(0, math.max(0, t_top))
  for i = 0, 512 do
    local mt, qs, qe, tsnum = r.TimeMap_GetMeasureInfo(0, m0 + i)
    if mt > t_bot then break end
    fn(m0 + i, mt, qs, qe, tsnum)
  end
end

--------------------------------------------------------------------- ImGui

local ctx = r.ImGui_CreateContext('MixLab', r.ImGui_ConfigFlags_DockingEnable())

-- kill ImGui's own keyboard navigation (on by default in ReaImGui): arrows must
-- switch tracks, not walk an invisible focus ring across the strip buttons
r.ImGui_SetConfigVar(ctx, r.ImGui_ConfigVar_Flags(), r.ImGui_ConfigFlags_DockingEnable())

-- drag-only sliders: no ctrl/double-click text-edit mode, which would swallow
-- every hotkey (Tab/Space included) until the hidden input box is dismissed
local NOINPUT = r.ImGui_SliderFlags_NoInput()

local playing, playpos, editpos = false, 0, 0
local lane_h, strip_h = 100, STRIP_H_MAX

-- wheel over a lane area: scroll time / zoom / horizontal (returns true if used)
local function laneWheel(laneY0, canScrollX)
  local wv = r.ImGui_GetMouseWheel(ctx)
  if wv == 0 then return end
  local mods = r.ImGui_GetKeyMods(ctx)
  local ctrl  = (mods & r.ImGui_Mod_Ctrl())  ~= 0
  local shift = (mods & r.ImGui_Mod_Shift()) ~= 0
  local _, my = r.ImGui_GetMousePos(ctx)
  if ctrl then
    local t_anchor = scroll_t + (my - laneY0) / pps
    pps = clamp(pps * (1.15 ^ wv), MIN_PPS, MAX_PPS)
    scroll_t = math.max(0, t_anchor - (my - laneY0) / pps)
    save()
  elseif shift and canScrollX then
    r.ImGui_SetScrollX(ctx, r.ImGui_GetScrollX(ctx) - wv * 60)
  else
    scroll_t = clamp(scroll_t - wv * 60 / pps, 0, r.GetProjectLength(0) + 300)
    if playing then follow_hold = true end
  end
end

------------------------------------------------------------------- quantize

-- select the track + all its items and launch PietosiQuantize on them
local function quantizeTrack(tr)
  r.SetOnlyTrackSelected(tr)
  r.Main_OnCommand(40289, 0) -- unselect all items
  local n = r.CountTrackMediaItems(tr)
  if n == 0 then return end
  for j = 0, n - 1 do
    r.SetMediaItemSelected(r.GetTrackMediaItem(tr, j), true)
  end
  r.UpdateArrange()
  if not pq_cmd then
    local path = resource .. sep .. 'Scripts' .. sep .. 'PietosiQuantize' .. sep .. 'PietosiQuantize.lua'
    local f = io.open(path, 'rb')
    if not f then
      r.MB('PietosiQuantize.lua not found in Scripts\\PietosiQuantize.', 'MixLab', 0)
      return
    end
    f:close()
    pq_cmd = r.AddRemoveReaScript(true, 0, path, true)
  end
  if pq_cmd and pq_cmd ~= 0 then r.Main_OnCommand(pq_cmd, 0) end
end

------------------------------------------------------------------ mixer strip

-- idx == 0 -> master track
local function drawStrip(tr, idx)
  local dl = r.ImGui_GetWindowDrawList(ctx)
  local wx, wy = r.ImGui_GetWindowPos(ctx)
  local ww, wh = r.ImGui_GetWindowSize(ctx)

  local cr, cg, cb = trackRGB(tr)
  r.ImGui_DrawList_AddRectFilled(dl, wx, wy, wx + ww, wy + 3, rgba(cr, cg, cb, 0xFF))
  r.ImGui_Dummy(ctx, 1, 4)

  -- name (click selects the track in REAPER)
  local label
  if idx == 0 then
    label = 'MASTER'
  else
    local _, nm = r.GetTrackName(tr)
    label = string.format('%d %s', idx, nm)
  end
  local selected = idx > 0 and r.IsTrackSelected(tr)
  if r.ImGui_Selectable(ctx, label .. '###nm', selected) and idx > 0 then
    r.SetOnlyTrackSelected(tr)
    r.UpdateArrange()
  end

  -- pan
  local pan = r.GetMediaTrackInfo_Value(tr, 'D_PAN')
  local pfmt
  if math.abs(pan) < 0.005 then pfmt = 'C'
  elseif pan < 0 then pfmt = 'L' .. math.floor(-pan * 100 + 0.5)
  else pfmt = 'R' .. math.floor(pan * 100 + 0.5) end
  r.ImGui_SetNextItemWidth(ctx, -1)
  local pch, npan = r.ImGui_SliderDouble(ctx, '##pan', pan, -1, 1, pfmt, NOINPUT)
  if pch then r.SetMediaTrackInfo_Value(tr, 'D_PAN', npan) end
  if r.ImGui_IsItemHovered(ctx) and r.ImGui_IsMouseDoubleClicked(ctx, 0) then
    r.SetMediaTrackInfo_Value(tr, 'D_PAN', 0)
  end

  -- mute / solo / arm / fx / quantize
  local nbtn = idx == 0 and 2 or 5
  local bw = (ww - 6 - (nbtn - 1) * 2) / nbtn
  local function stateButton(lbl, on, oncol, fn)
    if on then
      r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Button(), oncol)
      r.ImGui_PushStyleColor(ctx, r.ImGui_Col_ButtonHovered(), oncol)
    end
    if r.ImGui_Button(ctx, lbl, bw, 0) then fn() end
    if on then r.ImGui_PopStyleColor(ctx, 2) end
  end

  local mute = r.GetMediaTrackInfo_Value(tr, 'B_MUTE') > 0
  stateButton('M', mute, 0xC03535FF, function()
    r.SetMediaTrackInfo_Value(tr, 'B_MUTE', mute and 0 or 1)
  end)
  if idx > 0 then
    r.ImGui_SameLine(ctx, 0, 2)
    local solo = r.GetMediaTrackInfo_Value(tr, 'I_SOLO') > 0
    stateButton('S', solo, 0xC0A020FF, function()
      r.SetMediaTrackInfo_Value(tr, 'I_SOLO', solo and 0 or 2)
    end)
    r.ImGui_SameLine(ctx, 0, 2)
    local arm = r.GetMediaTrackInfo_Value(tr, 'I_RECARM') > 0
    stateButton('*', arm, 0xD02020FF, function()
      r.SetMediaTrackInfo_Value(tr, 'I_RECARM', arm and 0 or 1)
    end)
  end
  r.ImGui_SameLine(ctx, 0, 2)
  local fxvis = r.TrackFX_GetChainVisible(tr) ~= -1
  stateButton('FX', fxvis, 0x3A86FFFF, function()
    r.TrackFX_Show(tr, 0, fxvis and 0 or 1)
  end)
  if idx > 0 then
    r.ImGui_SameLine(ctx, 0, 2)
    stateButton('Q', false, 0, function() quantizeTrack(tr) end)
  end

  -- fader + meters
  local vol = r.GetMediaTrackInfo_Value(tr, 'D_VOL')
  local _, availY = r.ImGui_GetContentRegionAvail(ctx)
  local fh = math.max(30, availY - 18)
  r.ImGui_SetCursorPosX(ctx, 6)
  local fch, ns = r.ImGui_VSliderDouble(ctx, '##vol', 22, fh, vol ^ 0.25, 0, 1.42, '', NOINPUT)
  if fch then r.SetMediaTrackInfo_Value(tr, 'D_VOL', ns ^ 4) end
  if r.ImGui_IsItemHovered(ctx) and r.ImGui_IsMouseDoubleClicked(ctx, 0) then
    r.SetMediaTrackInfo_Value(tr, 'D_VOL', 1)
  end
  if r.ImGui_IsItemActive(ctx) then
    r.ImGui_SetTooltip(ctx, dbstr(r.GetMediaTrackInfo_Value(tr, 'D_VOL')) .. ' dB')
  end

  local fx1, fy1 = r.ImGui_GetItemRectMin(ctx)
  local fx2, fy2 = r.ImGui_GetItemRectMax(ctx)
  local function ndb(db) return clamp((db + 60) / 66, 0, 1) end
  for chn = 0, 1 do
    local mx1 = fx2 + 5 + chn * 7
    if mx1 + 5 < wx + ww then
      r.ImGui_DrawList_AddRectFilled(dl, mx1, fy1, mx1 + 5, fy2, 0x000000AA)
      local lvl = ndb(val2db(r.Track_GetPeakInfo(tr, chn)))
      if lvl > 0 then
        local seg = { { 0, ndb(-12), 0x2FA84FFF }, { ndb(-12), ndb(0), 0xC8B830FF }, { ndb(0), 1, 0xD03030FF } }
        for _, s in ipairs(seg) do
          local lo, hi = s[1], math.min(lvl, s[2])
          if hi > lo then
            r.ImGui_DrawList_AddRectFilled(dl, mx1, fy2 - hi * (fy2 - fy1), mx1 + 5, fy2 - lo * (fy2 - fy1), s[3])
          end
        end
      end
    end
  end

  local ds = dbstr(r.GetMediaTrackInfo_Value(tr, 'D_VOL'))
  local tw = r.ImGui_CalcTextSize(ctx, ds)
  r.ImGui_SetCursorPosX(ctx, math.max(0, (ww - tw) / 2))
  r.ImGui_TextColored(ctx, COL_TXT_DIM, ds)
end

local function beginStripChild(id)
  r.ImGui_PushStyleColor(ctx, r.ImGui_Col_ChildBg(), COL_STRIPBG)
  r.ImGui_PushStyleVar(ctx, r.ImGui_StyleVar_ItemSpacing(), 2, 2)
  local vis = r.ImGui_BeginChild(ctx, id, colw - 4, strip_h - 4, 0, r.ImGui_WindowFlags_NoScrollbar())
  return vis
end

local function endStripChild(visible)
  if visible then r.ImGui_EndChild(ctx) end
  r.ImGui_PopStyleVar(ctx)
  r.ImGui_PopStyleColor(ctx)
end

----------------------------------------------------------------------- lanes

-- neon lines at the project grid division (the grid selected in REAPER's main
-- window) so snap/nudge targets are obvious. Coarsens by powers of 2 when
-- zoomed out so it never turns into a solid wall.
local function drawProjectGrid(dl, x0, x1, y0, y1, t_top, t_bot)
  local _, div = r.GetSetProjectGrid(0, false)
  if not div or div <= 0 then return end
  local div_qn = div * 4
  local qn_top = r.TimeMap2_timeToQN(0, math.max(0, t_top))
  local spacing = (r.TimeMap2_QNToTime(0, qn_top + div_qn) - r.TimeMap2_QNToTime(0, qn_top)) * pps
  while spacing < 7 and spacing > 0 do
    div_qn, spacing = div_qn * 2, spacing * 2
  end
  local qn = math.floor(qn_top / div_qn) * div_qn
  for _ = 1, 1024 do
    local t = r.TimeMap2_QNToTime(0, qn)
    if t > t_bot then break end
    if t >= 0 then
      local y = y0 + (t - scroll_t) * pps
      r.ImGui_DrawList_AddLine(dl, x0, y, x1, y, COL_GRID_RIM, 3)
      r.ImGui_DrawList_AddLine(dl, x0, y, x1, y, COL_GRID, 1)
    end
    qn = qn + div_qn
  end
end

local function drawGrid(dl, x0, x1, y0, y1)
  local t_top, t_bot = scroll_t, scroll_t + (y1 - y0) / pps
  r.ImGui_DrawList_PushClipRect(dl, x0, y0, x1, y1, true)

  local ls, le = r.GetSet_LoopTimeRange2(0, false, true, 0, 0, false)
  if le > ls then
    local ly1 = y0 + (ls - scroll_t) * pps
    local ly2 = y0 + (le - scroll_t) * pps
    r.ImGui_DrawList_AddRectFilled(dl, x0, ly1, x1, ly2, COL_LOOP)
  end

  eachMeasure(t_top, t_bot, function(m, mt, qs, qe, tsnum)
    local y = y0 + (mt - scroll_t) * pps
    r.ImGui_DrawList_AddLine(dl, x0, y, x1, y, COL_MEASURE, 1)
    if pps >= 40 and tsnum > 1 then
      for b = 1, tsnum - 1 do
        local bt = r.TimeMap2_QNToTime(0, qs + (qe - qs) * b / tsnum)
        local by = y0 + (bt - scroll_t) * pps
        if by > y0 and by < y1 then
          r.ImGui_DrawList_AddLine(dl, x0, by, x1, by, COL_BEAT, 1)
        end
      end
    end
  end)

  drawProjectGrid(dl, x0, x1, y0, y1, t_top, t_bot)

  r.ImGui_DrawList_PopClipRect(dl)
end

local function drawCursors(dl, x0, x1, y0, y1)
  r.ImGui_DrawList_PushClipRect(dl, x0, y0, x1, y1 + 1, true)
  local ey = y0 + (editpos - scroll_t) * pps
  r.ImGui_DrawList_AddLine(dl, x0, ey, x1, ey, COL_EDIT, 1)
  if playing then
    local py = y0 + (playpos - scroll_t) * pps
    r.ImGui_DrawList_AddLine(dl, x0, py, x1, py, COL_PLAY, 2)
  end
  r.ImGui_DrawList_PopClipRect(dl)
end

local function laneInteraction(tr, laneY0)
  if not r.ImGui_IsItemActivated(ctx) then return end
  local mx, my = r.ImGui_GetMousePos(ctx)
  local t = scroll_t + (my - laneY0) / pps
  local hit
  for j = 0, r.CountTrackMediaItems(tr) - 1 do
    local it = r.GetTrackMediaItem(tr, j)
    local p = r.GetMediaItemInfo_Value(it, 'D_POSITION')
    local l = r.GetMediaItemInfo_Value(it, 'D_LENGTH')
    if t >= p and t <= p + l then hit = it end
  end
  r.SetOnlyTrackSelected(tr)
  if hit then
    r.Main_OnCommand(40289, 0) -- unselect all items
    r.SetMediaItemSelected(hit, true)
    r.UpdateArrange()
    if r.ImGui_IsMouseDoubleClicked(ctx, 0) then
      local tk = r.GetActiveTake(hit)
      if tk and r.TakeIsMIDI(tk) then r.Main_OnCommand(40153, 0) end
    else
      drag = { item = hit, t0 = r.GetMediaItemInfo_Value(hit, 'D_POSITION'), my0 = my, undo = false }
    end
  else
    r.SetEditCurPos(maybeSnap(t), false, true)
  end
end

-- vertical waveform peaks for an audio take, cached per item at current zoom
local function getPeaks(it, tk, len)
  local key = tostring(it)
  local rate = r.GetMediaItemTakeInfo_Value(tk, 'D_PLAYRATE')
  local offs = r.GetMediaItemTakeInfo_Value(tk, 'D_STARTOFFS')
  local c = peakcache[key]
  if c and c.pps == pps and c.len == len and c.offs == offs and c.rate == rate then return c end

  local src = r.GetMediaItemTake_Source(tk)
  if not src then return end
  local nch = math.min(2, r.GetMediaSourceNumChannels(src))
  if nch < 1 then return end
  local step = PEAK_STEP
  local n = math.floor(len * pps / step)
  while n > 4000 do step = step * 2; n = math.floor(len * pps / step) end
  c = { pps = pps, len = len, offs = offs, rate = rate, n = 0, nch = nch, step = step }
  if n >= 2 then
    local buf = r.new_array(n * nch * 2)
    buf.clear()
    local pos = r.GetMediaItemInfo_Value(it, 'D_POSITION')
    local rv = r.GetMediaItemTake_Peaks(tk, pps / step, pos, nch, n, 0, buf)
    c.n = math.min(rv & 0xfffff, n)
    c.nreq = n
    c.smp = buf.table()
  end
  peakcache[key] = c
  pc_count = pc_count + 1
  if pc_count > 600 then peakcache = { [key] = c }; pc_count = 1 end
  return c
end

local function drawWave(dl, c, x1, x2, yTop, laneY0, laneY1, col)
  local nch, step = c.nch, c.step
  local w, minoff = x2 - x1, c.nreq * nch
  local i0 = math.max(0, math.floor((laneY0 - yTop) / step) - 1)
  local i1 = math.min(c.n - 1, math.ceil((laneY1 - yTop) / step) + 1)
  for ch = 0, nch - 1 do
    local cx = nch == 2 and (x1 + w * (0.25 + ch * 0.5)) or (x1 + w * 0.5)
    local hw = nch == 2 and w * 0.22 or w * 0.45
    for i = i0, i1 do
      local y = yTop + (i + 0.5) * step
      local a = clamp(c.smp[i * nch + ch + 1] or 0, -1, 1)
      local b = clamp(c.smp[minoff + i * nch + ch + 1] or 0, -1, 1)
      if a - b < 0.02 then a, b = a + 0.01, b - 0.01 end
      r.ImGui_DrawList_AddLine(dl, cx + b * hw, y, cx + a * hw, y, col, step)
    end
  end
end

-- player-piano note roll for a MIDI take; note times cached relative to item start
local function getMidiNotes(tk, itemPos)
  local key = tostring(tk)
  local ok, hash = r.MIDI_GetHash(tk, true, '')
  if not ok then return end
  local c = midicache[key]
  if c and c.hash == hash and c.pos == itemPos then return c end
  local _, ncnt = r.MIDI_CountEvts(tk)
  local notes, lo, hi = {}, 127, 0
  for i = 0, ncnt - 1 do
    local _, _, _, sppq, eppq, _, pitch, vel = r.MIDI_GetNote(tk, i)
    notes[#notes + 1] = {
      r.MIDI_GetProjTimeFromPPQPos(tk, sppq) - itemPos,
      r.MIDI_GetProjTimeFromPPQPos(tk, eppq) - itemPos,
      pitch, vel,
    }
    if pitch < lo then lo = pitch end
    if pitch > hi then hi = pitch end
  end
  c = { hash = hash, pos = itemPos, notes = notes, lo = lo, hi = hi }
  midicache[key] = c
  mc_count = mc_count + 1
  if mc_count > 400 then midicache = { [key] = c }; mc_count = 1 end
  return c
end

local function drawMidiRoll(dl, tk, x1, x2, yTop, itemPos, laneY0, laneY1, col)
  local c = getMidiNotes(tk, itemPos)
  if not c or #c.notes == 0 then return end
  local lo, hi = c.lo, c.hi
  if hi - lo < 11 then -- keep sparse parts from turning into giant blobs
    local mid = (hi + lo) // 2
    lo, hi = mid - 5, mid + 6
  end
  local semiw = (x2 - x1 - 4) / (hi - lo + 1)
  local nw = math.max(2, semiw * 0.8)
  for _, nt in ipairs(c.notes) do
    local ny1 = yTop + nt[1] * pps
    local ny2 = math.max(ny1 + 2, yTop + nt[2] * pps)
    if ny2 >= laneY0 and ny1 <= laneY1 then
      local nx = x1 + 2 + (nt[3] - lo) * semiw
      local alpha = math.floor(clamp(0x50 + nt[4] * 1.4, 0x50, 0xE6))
      r.ImGui_DrawList_AddRectFilled(dl, nx, ny1, nx + nw, ny2, (col & ~0xFF) | alpha, 2)
    end
  end
end

local function drawLaneItems(dl, tr, bx, laneY0, laneY1)
  r.ImGui_DrawList_PushClipRect(dl, bx + 1, laneY0, bx + colw - 1, laneY1, true)
  for j = 0, r.CountTrackMediaItems(tr) - 1 do
    local it = r.GetTrackMediaItem(tr, j)
    local p = r.GetMediaItemInfo_Value(it, 'D_POSITION')
    local l = r.GetMediaItemInfo_Value(it, 'D_LENGTH')
    local y1 = laneY0 + (p - scroll_t) * pps
    local y2 = math.max(y1 + 3, y1 + l * pps)
    if y2 >= laneY0 and y1 <= laneY1 then
      local rr, gg, bb = itemColor(it, tr)
      local muted = r.GetMediaItemInfo_Value(it, 'B_MUTE') > 0
      local sel = r.GetMediaItemInfo_Value(it, 'B_UISEL') > 0
      local lum = 0.299 * rr + 0.587 * gg + 0.114 * bb
      local fgcol = lum > 140 and 0x141414C0 or 0xF5F5F5C8
      r.ImGui_DrawList_AddRectFilled(dl, bx + 2, y1, bx + colw - 2, y2, rgba(rr, gg, bb, muted and 0x50 or 0xD8), 3)

      -- item content: vertical waveform (audio) or player-piano roll (MIDI)
      local tk = r.GetActiveTake(it)
      if tk and colw >= 30 and y2 - y1 >= 10 then
        if r.TakeIsMIDI(tk) then
          drawMidiRoll(dl, tk, bx + 2, bx + colw - 2, y1, p, laneY0, laneY1, fgcol)
        else
          local pk = getPeaks(it, tk, l)
          if pk and pk.n > 0 then
            drawWave(dl, pk, bx + 4, bx + colw - 4, y1, laneY0, laneY1, fgcol)
          end
        end
      end

      r.ImGui_DrawList_AddRect(dl, bx + 2, y1, bx + colw - 2, y2, sel and 0xFFFFFFFF or 0x00000060, 3, 0, sel and 2 or 1)
      if y2 - y1 > 13 then
        local nm = tk and r.GetTakeName(tk) or ''
        if nm ~= '' then
          local tcol = lum > 140 and 0x000000E0 or 0xFFFFFFE0
          r.ImGui_DrawList_PushClipRect(dl, bx + 4, math.max(y1, laneY0), bx + colw - 4, math.min(y2, laneY1), true)
          r.ImGui_DrawList_AddText(dl, bx + 5, y1 + 2, tcol, nm)
          r.ImGui_DrawList_PopClipRect(dl)
        end
      end
    end
  end
  r.ImGui_DrawList_PopClipRect(dl)
end

local function processDrag()
  if not drag then return end
  if not r.ValidatePtr2(0, drag.item, 'MediaItem*') then drag = nil return end
  if r.ImGui_IsMouseDown(ctx, 0) then
    local _, my = r.ImGui_GetMousePos(ctx)
    if drag.undo or math.abs(my - drag.my0) > 3 then
      if not drag.undo then r.Undo_BeginBlock2(0); drag.undo = true end
      local np = maybeSnap(math.max(0, drag.t0 + (my - drag.my0) / pps))
      r.SetMediaItemInfo_Value(drag.item, 'D_POSITION', np)
      r.UpdateArrange()
    end
  else
    if drag.undo then r.Undo_EndBlock2(0, 'MixLab: move item', -1) end
    drag = nil
  end
end

--------------------------------------------------------------------- hotkeys

local function selTrackIndex()
  for i = 0, r.CountTracks(0) - 1 do
    if r.IsTrackSelected(r.GetTrack(0, i)) then return i end
  end
end

-- select the item under time t on the selected track (scrub release lands here)
local function selectItemUnderCursor(t)
  local idx = selTrackIndex()
  if not idx then return end
  local tr = r.GetTrack(0, idx)
  r.Main_OnCommand(40289, 0) -- unselect all items
  for j = 0, r.CountTrackMediaItems(tr) - 1 do
    local it = r.GetTrackMediaItem(tr, j)
    local p = r.GetMediaItemInfo_Value(it, 'D_POSITION')
    local l = r.GetMediaItemInfo_Value(it, 'D_LENGTH')
    if t >= p and t <= p + l then
      r.SetMediaItemSelected(it, true)
      break
    end
  end
  r.UpdateArrange()
end

-- move all selected items by one grid division (tempo-map aware)
local function nudgeSelectedItems(dir)
  local n = r.CountSelectedMediaItems(0)
  if n == 0 then return end
  local _, division = r.GetSetProjectGrid(0, false)
  local div_qn = division * 4
  if div_qn <= 0 then div_qn = 1 end
  r.Undo_BeginBlock2(0)
  for i = 0, n - 1 do
    local it = r.GetSelectedMediaItem(0, i)
    local p = r.GetMediaItemInfo_Value(it, 'D_POSITION')
    local qn = r.TimeMap2_timeToQN(0, p) + dir * div_qn
    r.SetMediaItemInfo_Value(it, 'D_POSITION', math.max(0, r.TimeMap2_QNToTime(0, qn)))
  end
  r.Undo_EndBlock2(0, 'MixLab: nudge items', -1)
  r.UpdateArrange()
end

-- EDIT mode: hold up/down = scrub (down = forward, matching the lanes' downward
-- time flow); releasing pauses there and selects the item under the cursor.
-- Audio comes from REAPER's own jog engine: the native "move cursor one pixel"
-- actions scrub (both directions!) when the scrub/jog preference is on — same
-- as holding the arrow keys in the arrange view. We force that pref on for the
-- hold. Space is a plain play/stop tap in every mode.

-- resolve the jog actions by NAME (ids differ from what docs suggest); cached.
-- false = unavailable, table = { left = cmd, right = cmd }
local jog_cmds = nil

local function resolveJogCmds()
  if jog_cmds ~= nil then return jog_cmds end
  jog_cmds = false
  if r.APIExists('CF_EnumerateActions') then
    local left, right
    for i = 0, 65535 do
      local cmd, name = r.CF_EnumerateActions(0, i, '')
      if not cmd or cmd <= 0 then break end
      local n = (name or ''):lower()
      if n == 'view: move cursor left one pixel' then left = cmd
      elseif n == 'view: move cursor right one pixel' then right = cmd end
      if left and right then break end
    end
    if left and right then jog_cmds = { left = left, right = right } end
  end
  return jog_cmds
end

local function startScrub()
  if playing then r.OnStopButton() end
  scrub = { pos = playing and playpos or editpos, acc = 0 }
  r.SetEditCurPos(scrub.pos, false, false)
  if r.APIExists('SNM_GetIntConfigVar') then
    local m = r.SNM_GetIntConfigVar('scrubmode', -999)
    if m ~= -999 then
      scrub.saved_mode = m
      if m & 1 == 0 then r.SNM_SetIntConfigVar('scrubmode', m | 1) end
    end
  end
end

local function endScrub(selectitem)
  if not scrub then return end
  if scrub.saved_mode and r.APIExists('SNM_SetIntConfigVar') then
    r.SNM_SetIntConfigVar('scrubmode', scrub.saved_mode)
  end
  if selectitem then selectItemUnderCursor(scrub.pos) end
  scrub = nil
end

local function handleTransport()
  local focused = r.ImGui_IsWindowFocused(ctx, r.ImGui_FocusedFlags_RootAndChildWindows())
  local free = focused and not r.ImGui_IsAnyItemActive(ctx) and not fx_pick

  if free and r.ImGui_IsKeyPressed(ctx, r.ImGui_Key_Space(), false) then
    r.Main_OnCommand(40044, 0) -- play/stop
  end

  local dir = 0
  if free and view_mode == 'edit' then
    if r.ImGui_IsKeyDown(ctx, r.ImGui_Key_DownArrow()) then dir = 1 end
    if r.ImGui_IsKeyDown(ctx, r.ImGui_Key_UpArrow()) then dir = -1 end
  end

  if dir == 0 then
    if scrub then endScrub(true) end
    return
  end
  if not scrub then startScrub() end
  scrub.dir = dir

  local mods = r.ImGui_GetKeyMods(ctx)
  local shift = (mods & r.ImGui_Mod_Shift()) ~= 0
  local alt = (mods & r.ImGui_Mod_Alt()) ~= 0
  local mult = scrub_speed * (shift and 6 or 1) * (alt and 0.2 or 1)
  local dt = r.ImGui_GetDeltaTime(ctx)
  local cmds = not scrub.fallback and resolveJogCmds()

  if cmds then
    -- convert wanted crawl rate (x realtime) into arrange pixels this frame,
    -- then jog with the native one-pixel actions so REAPER scrubs audibly
    local pxsec = math.max(1, r.GetHZoomLevel())
    scrub.acc = scrub.acc + mult * dt * pxsec
    local n = math.floor(scrub.acc)
    scrub.acc = scrub.acc - n
    if n > 400 then n = 400 end
    if n > 0 then
      local before = r.GetCursorPosition()
      local cmd = dir < 0 and cmds.left or cmds.right
      for _ = 1, n do r.Main_OnCommand(cmd, 0) end
      local after = r.GetCursorPosition()
      if math.abs(after - before) < 1e-9 then
        scrub.fallback = true -- jog actions inert here: keep moving, silently
      else
        scrub.pos = after
      end
    end
  end
  if not cmds or scrub.fallback then
    -- guaranteed movement even without jog actions (no audio)
    scrub.pos = math.max(0, scrub.pos + dir * mult * dt)
    r.SetEditCurPos(scrub.pos, false, false)
  end
  if view_mode ~= 'fx' then -- keep the crawl in view
    local y = (scrub.pos - scroll_t) * pps
    if y < 0 or y > lane_h * 0.85 then
      scroll_t = math.max(0, scrub.pos - lane_h * 0.4 / pps)
    end
  end
end

local function nudgeVol(tr, delta)
  local db = val2db(r.GetMediaTrackInfo_Value(tr, 'D_VOL'))
  db = clamp((db < -90 and -90 or db) + delta, -90, 12)
  r.SetMediaTrackInfo_Value(tr, 'D_VOL', db <= -90 and 0 or 10 ^ (db / 20))
end

local function handleKeys()
  if not r.ImGui_IsWindowFocused(ctx, r.ImGui_FocusedFlags_RootAndChildWindows()) then return end
  if r.ImGui_IsAnyItemActive(ctx) then return end -- don't steal keys from widgets
  if fx_pick then return end -- routing picker popup owns the keyboard
  local function pressed(key, rep)
    return r.ImGui_IsKeyPressed(ctx, key, rep or false)
  end

  if pressed(r.ImGui_Key_Tab()) then
    if view_mode == 'fx' then
      view_mode = prev_view
    else
      prev_view = view_mode
      view_mode = 'fx'
      fx_sel = 1
    end
  end
  if pressed(r.ImGui_Key_Escape()) then
    if view_mode == 'edit' then
      view_mode = 'deck'
    elseif view_mode == 'fx' then
      view_mode = prev_view
    end
  end
  if view_mode == 'fx' then return end -- the FX view handles its own keys

  if pressed(r.ImGui_Key_Home()) then
    scroll_t = 0
    if playing then follow_hold = true end
  end
  if pressed(r.ImGui_Key_Minus(), true) then scrub_speed = clamp(scrub_speed / 1.25, 0.05, 8); save() end
  if pressed(r.ImGui_Key_Equal(), true) then scrub_speed = clamp(scrub_speed * 1.25, 0.05, 8); save() end

  local n = r.CountTracks(0)
  if n == 0 then return end
  local mods = r.ImGui_GetKeyMods(ctx)
  local shift = (mods & r.ImGui_Mod_Shift()) ~= 0
  local alt   = (mods & r.ImGui_Mod_Alt())   ~= 0

  local move = 0
  if pressed(r.ImGui_Key_LeftArrow(), true) then move = -1 end
  if pressed(r.ImGui_Key_RightArrow(), true) then move = 1 end

  local idx = selTrackIndex()
  if move ~= 0 and not alt then -- switch selected track, keep it in view
    idx = clamp((idx or (move > 0 and -1 or n)) + move, 0, n - 1)
    r.SetOnlyTrackSelected(r.GetTrack(0, idx))
    r.UpdateArrange()
    scroll_to_track = idx
    return
  end

  local tr = idx and r.GetTrack(0, idx)
  if not tr then return end
  if pressed(r.ImGui_Key_Q()) then quantizeTrack(tr) end

  if view_mode == 'deck' then
    ------------------------------------------------------- MIX mode keys
    local vstep = shift and 0.25 or 1
    if pressed(r.ImGui_Key_UpArrow(), true) then nudgeVol(tr, vstep) end
    if pressed(r.ImGui_Key_DownArrow(), true) then nudgeVol(tr, -vstep) end
    if alt and move ~= 0 then
      local pan = r.GetMediaTrackInfo_Value(tr, 'D_PAN')
      r.SetMediaTrackInfo_Value(tr, 'D_PAN', clamp(pan + move * (shift and 0.01 or 0.05), -1, 1))
    end
    if pressed(r.ImGui_Key_M()) then
      r.SetMediaTrackInfo_Value(tr, 'B_MUTE', r.GetMediaTrackInfo_Value(tr, 'B_MUTE') > 0 and 0 or 1)
    end
    if pressed(r.ImGui_Key_S()) then
      r.SetMediaTrackInfo_Value(tr, 'I_SOLO', r.GetMediaTrackInfo_Value(tr, 'I_SOLO') > 0 and 0 or 2)
    end
    if pressed(r.ImGui_Key_R()) then
      r.SetMediaTrackInfo_Value(tr, 'I_RECARM', r.GetMediaTrackInfo_Value(tr, 'I_RECARM') > 0 and 0 or 1)
    end
    if pressed(r.ImGui_Key_F()) then
      local vis = r.TrackFX_GetChainVisible(tr) ~= -1
      r.TrackFX_Show(tr, 0, vis and 0 or 1)
    end
    if pressed(r.ImGui_Key_0()) then r.SetMediaTrackInfo_Value(tr, 'D_VOL', 1) end
    if pressed(r.ImGui_Key_Enter()) or pressed(r.ImGui_Key_KeypadEnter()) then
      view_mode = 'edit' -- into the playlist editor
    end
  else
    ------------------------------------------------------ EDIT mode keys
    local selit = r.GetSelectedMediaItem(0, 0)
    if pressed(r.ImGui_Key_Enter()) or pressed(r.ImGui_Key_KeypadEnter()) then
      -- MIDI item under the cursor: straight into the MIDI editor.
      -- Otherwise Enter still snaps the cursor to the selected item's start.
      local hit
      for j = 0, r.CountTrackMediaItems(tr) - 1 do
        local it = r.GetTrackMediaItem(tr, j)
        local p = r.GetMediaItemInfo_Value(it, 'D_POSITION')
        local l = r.GetMediaItemInfo_Value(it, 'D_LENGTH')
        if editpos >= p and editpos <= p + l then hit = it end
      end
      local tk = hit and r.GetActiveTake(hit)
      if tk and r.TakeIsMIDI(tk) then
        r.Main_OnCommand(40289, 0) -- unselect all items
        r.SetMediaItemSelected(hit, true)
        r.UpdateArrange()
        r.Main_OnCommand(40153, 0) -- open in built-in MIDI editor
      elseif selit then
        local p = r.GetMediaItemInfo_Value(selit, 'D_POSITION')
        r.SetEditCurPos(p, false, true)
        scroll_t = math.max(0, p - lane_h * 0.2 / pps)
      end
    end
    if selit then
      if pressed(r.ImGui_Key_E()) then
        local tk = r.GetActiveTake(selit)
        if tk and r.TakeIsMIDI(tk) then r.Main_OnCommand(40153, 0) end
      end
      if pressed(r.ImGui_Key_X()) then r.Main_OnCommand(40012, 0) end      -- split at cursor
      if pressed(r.ImGui_Key_D()) then r.Main_OnCommand(41295, 0) end      -- duplicate
      if pressed(r.ImGui_Key_Delete()) then r.Main_OnCommand(40006, 0) end -- remove
      if pressed(r.ImGui_Key_Comma(), true) then nudgeSelectedItems(-1) end
      if pressed(r.ImGui_Key_Period(), true) then nudgeSelectedItems(1) end
    end
    if pressed(r.ImGui_Key_R()) then -- record (arms the selected track first)
      if (r.GetPlayState() & 4) == 0 and r.GetMediaTrackInfo_Value(tr, 'I_RECARM') == 0 then
        r.SetMediaTrackInfo_Value(tr, 'I_RECARM', 1)
      end
      r.Main_OnCommand(1013, 0)
    end
  end
end

-------------------------------------------------------------------- FX view

local FXROW_KINDS = { fx = 'FX CHAIN', send = 'SENDS', recv = 'RECEIVES', hw = 'HARDWARE OUTS' }

local function fxFloatToggle(tr, i)
  if r.TrackFX_GetFloatingWindow(tr, i) then
    r.TrackFX_Show(tr, i, 2)
  else
    r.TrackFX_Show(tr, i, 3)
  end
end

local function sendNudge(tr, cat, i, delta)
  local db = val2db(r.GetTrackSendInfo_Value(tr, cat, i, 'D_VOL'))
  db = clamp((db < -90 and -90 or db) + delta, -90, 12)
  r.SetTrackSendInfo_Value(tr, cat, i, 'D_VOL', db <= -90 and 0 or 10 ^ (db / 20))
end

local function fxNote(s)
  fx_msg, fx_msg_t = s, os.clock()
end

local function chanPairLabel(v)
  if v < 0 then return 'None' end
  if v >= 1024 then return 'M' .. math.floor(v - 1024 + 1) end
  return string.format('%d-%d', v + 1, v + 2)
end

-- source / destination tracks of a send (needs SWS for the far end; nil if unknown)
local function sendEndpoints(tr, cat, i)
  local br = r.APIExists('BR_GetMediaTrackSendInfo_Track')
  if cat == 0 then
    return tr, br and r.BR_GetMediaTrackSendInfo_Track(tr, 0, i, 1) or nil
  elseif cat == -1 then
    return br and r.BR_GetMediaTrackSendInfo_Track(tr, -1, i, 0) or nil, tr
  end
  return tr, nil
end

local function cycleSendChan(tr, cat, i, isdst, dir)
  local srctr, dsttr = sendEndpoints(tr, cat, i)
  if not isdst then
    local n = srctr and r.GetMediaTrackInfo_Value(srctr, 'I_NCHAN') or 8
    local cur = r.GetTrackSendInfo_Value(tr, cat, i, 'I_SRCCHAN')
    local opts = { -1 } -- audio off (MIDI-only send)
    for c = 0, n - 2, 2 do opts[#opts + 1] = c end
    local idx = 1
    for k, v in ipairs(opts) do if v == cur then idx = k break end end
    idx = clamp(idx + dir, 1, #opts)
    r.SetTrackSendInfo_Value(tr, cat, i, 'I_SRCCHAN', opts[idx])
  else
    local maxpair = cat == 1 and math.max(0, r.GetNumAudioOutputs() - 2) or 14
    local cur = r.GetTrackSendInfo_Value(tr, cat, i, 'I_DSTCHAN')
    if cur < 0 then cur = 0 end
    local new = clamp(cur + dir * 2, 0, maxpair)
    if cat ~= 1 then
      if dsttr then -- widen the destination track to fit the chosen pair
        if r.GetMediaTrackInfo_Value(dsttr, 'I_NCHAN') < new + 2 then
          r.SetMediaTrackInfo_Value(dsttr, 'I_NCHAN', new + 2)
        end
      else
        new = math.min(new, 6) -- destination width unknown without SWS
      end
    end
    r.SetTrackSendInfo_Value(tr, cat, i, 'I_DSTCHAN', new)
  end
end

-- create a sidechain feed: srctr 1/2 -> tr 3/4, then point the FX's aux input
-- pins (3rd/4th input) at channels 3/4
local function applySidechain(tr, srctr, fxidx)
  if r.GetMediaTrackInfo_Value(tr, 'I_NCHAN') < 4 then
    r.SetMediaTrackInfo_Value(tr, 'I_NCHAN', 4)
  end
  r.CreateTrackSend(srctr, tr)
  local ri = r.GetTrackNumSends(tr, -1) - 1
  r.SetTrackSendInfo_Value(tr, -1, ri, 'I_SRCCHAN', 0)
  r.SetTrackSendInfo_Value(tr, -1, ri, 'I_DSTCHAN', 2)

  local _, srcname = r.GetTrackName(srctr)
  if not fxidx or fxidx >= r.TrackFX_GetCount(tr) then
    fxNote(('Sidechain: %s -> ch 3/4.  No FX to map — add one and set its detector input.'):format(srcname))
    return
  end
  local ok, inpins = pcall(function()
    local _, ip = r.TrackFX_GetIOSize(tr, fxidx)
    return ip
  end)
  if ok and inpins and inpins >= 4 then
    r.TrackFX_SetPinMappings(tr, fxidx, 0, 2, 1 << 2, 0)
    r.TrackFX_SetPinMappings(tr, fxidx, 0, 3, 1 << 3, 0)
    local _, fxname = r.TrackFX_GetFXName(tr, fxidx, '')
    fxNote(('Sidechain: %s -> ch 3/4, %s aux inputs pinned to 3/4. Enable its detector/ext input.'):format(srcname, fxname))
  else
    fxNote(('Sidechain: %s -> ch 3/4.  Selected FX has no aux input pins — route inside the plugin.'):format(srcname))
  end
end

local function buildFXRows(tr)
  local rows = {}
  for i = 0, r.TrackFX_GetCount(tr) - 1 do
    rows[#rows + 1] = { kind = 'fx', i = i }
  end
  local cats = { { 0, 'send' }, { -1, 'recv' }, { 1, 'hw' } }
  for _, c in ipairs(cats) do
    for i = 0, r.GetTrackNumSends(tr, c[1]) - 1 do
      rows[#rows + 1] = { kind = c[2], i = i, cat = c[1] }
    end
  end
  return rows
end

local function fxViewKeys(tr, idx, rows)
  if fx_pick then return end
  if not r.ImGui_IsWindowFocused(ctx, r.ImGui_FocusedFlags_RootAndChildWindows()) then return end
  if r.ImGui_IsAnyItemActive(ctx) then return end
  local function pressed(key, rep)
    return r.ImGui_IsKeyPressed(ctx, key, rep or false)
  end
  local mods = r.ImGui_GetKeyMods(ctx)
  local ctrl  = (mods & r.ImGui_Mod_Ctrl())  ~= 0
  local alt   = (mods & r.ImGui_Mod_Alt())   ~= 0
  local shift = (mods & r.ImGui_Mod_Shift()) ~= 0
  local row = rows[fx_sel]
  local vstep = shift and 0.25 or 1

  -- left/right switch track, like the deck
  local move = 0
  if pressed(r.ImGui_Key_LeftArrow(), true) then move = -1 end
  if pressed(r.ImGui_Key_RightArrow(), true) then move = 1 end
  if move ~= 0 then
    local n = r.CountTracks(0)
    idx = clamp(idx + move, 0, n - 1)
    r.SetOnlyTrackSelected(r.GetTrack(0, idx))
    r.UpdateArrange()
    fx_sel = 1
    fx_param_sel = 0
    return
  end

  local vert = 0
  if pressed(r.ImGui_Key_UpArrow(), true) then vert = -1 end
  if pressed(r.ImGui_Key_DownArrow(), true) then vert = 1 end
  if vert ~= 0 then
    if ctrl and row and row.kind == 'fx' then -- reorder FX
      local j = row.i + vert
      if j >= 0 and j < r.TrackFX_GetCount(tr) then
        r.TrackFX_CopyToTrack(tr, row.i, tr, j, true)
        fx_sel = fx_sel + vert
        fx_nav = true
      end
    elseif alt and row and row.kind ~= 'fx' then -- send volume
      sendNudge(tr, row.cat, row.i, -vert * vstep)
    else
      fx_sel = clamp(fx_sel + vert, 1, math.max(1, #rows))
      fx_param_sel = 0
      fx_nav = true
    end
    return
  end

  -- parameter navigation / adjustment on FX rows
  if row and row.kind == 'fx' then
    local np = r.TrackFX_GetNumParams(tr, row.i)
    if np > 0 then
      if pressed(r.ImGui_Key_Comma(), true) then
        fx_param_sel = clamp(fx_param_sel - 1, 0, np - 1); fx_pnav = true
      end
      if pressed(r.ImGui_Key_Period(), true) then
        fx_param_sel = clamp(fx_param_sel + 1, 0, np - 1); fx_pnav = true
      end
      local pdelta = 0
      if pressed(r.ImGui_Key_Minus(), true) then pdelta = -1 end
      if pressed(r.ImGui_Key_Equal(), true) then pdelta = 1 end
      if pdelta ~= 0 then
        fx_param_sel = clamp(fx_param_sel, 0, np - 1)
        local v = r.TrackFX_GetParamNormalized(tr, row.i, fx_param_sel)
        r.TrackFX_SetParamNormalized(tr, row.i, fx_param_sel,
          clamp(v + pdelta * (shift and 0.001 or 0.01), 0, 1))
      end
    end
  end

  if not row then
    if pressed(r.ImGui_Key_A()) then r.Main_OnCommand(40271, 0) end -- FX browser
    return
  end

  if pressed(r.ImGui_Key_Enter()) or pressed(r.ImGui_Key_F()) then
    if row.kind == 'fx' then fxFloatToggle(tr, row.i) end
  end
  if pressed(r.ImGui_Key_B()) or (row.kind ~= 'fx' and pressed(r.ImGui_Key_M())) then
    if row.kind == 'fx' then
      r.TrackFX_SetEnabled(tr, row.i, not r.TrackFX_GetEnabled(tr, row.i))
    else
      local m = r.GetTrackSendInfo_Value(tr, row.cat, row.i, 'B_MUTE')
      r.SetTrackSendInfo_Value(tr, row.cat, row.i, 'B_MUTE', m > 0 and 0 or 1)
    end
  end
  if pressed(r.ImGui_Key_O()) and row.kind == 'fx' then
    r.TrackFX_SetOffline(tr, row.i, not r.TrackFX_GetOffline(tr, row.i))
  end
  if pressed(r.ImGui_Key_Delete()) then
    if row.kind == 'fx' then
      r.TrackFX_Delete(tr, row.i)
    else
      r.RemoveTrackSend(tr, row.cat, row.i)
    end
    fx_sel = clamp(fx_sel, 1, math.max(1, #rows - 1))
  end
  if pressed(r.ImGui_Key_A()) then r.Main_OnCommand(40271, 0) end -- FX browser
  if pressed(r.ImGui_Key_I()) then r.Main_OnCommand(40293, 0) end -- routing window
  if pressed(r.ImGui_Key_Q()) then quantizeTrack(tr) end
  if pressed(r.ImGui_Key_N()) then -- new send (shift: new receive)
    fx_pick = { mode = shift and 'recv' or 'send', filter = '', sel = 1 }
    fx_pick_new = true
  end
  if pressed(r.ImGui_Key_C()) then -- sidechain from...
    fx_pick = {
      mode = 'sc', filter = '', sel = 1,
      fxidx = (row and row.kind == 'fx') and row.i or 0,
    }
    fx_pick_new = true
  end
  -- send channel mapping: [ ] cycles source pair, shift+[ ] cycles dest pair
  if row and row.kind ~= 'fx' then
    if pressed(r.ImGui_Key_LeftBracket(), true) then cycleSendChan(tr, row.cat, row.i, shift, -1) end
    if pressed(r.ImGui_Key_RightBracket(), true) then cycleSendChan(tr, row.cat, row.i, shift, 1) end
  end
end

-- destination picker popup for creating sends/receives
local function drawRoutePicker(tr)
  if fx_pick_new then
    r.ImGui_OpenPopup(ctx, 'RoutePicker')
    fx_pick_new = false
  end
  if not fx_pick then return end

  if r.ImGui_BeginPopup(ctx, 'RoutePicker') then
    local titles = {
      send = 'Add send to...',
      recv = 'Add receive from...',
      sc   = 'Sidechain from...  (source -> ch 3/4 + FX aux pins)',
    }
    r.ImGui_Text(ctx, titles[fx_pick.mode])
    if r.ImGui_IsWindowAppearing(ctx) then r.ImGui_SetKeyboardFocusHere(ctx) end
    r.ImGui_SetNextItemWidth(ctx, 280)
    local ch, txt = r.ImGui_InputText(ctx, '##pickfilter', fx_pick.filter)
    if ch then fx_pick.filter = txt; fx_pick.sel = 1 end

    local cands = {}
    local filter = fx_pick.filter:lower()
    for i = 0, r.CountTracks(0) - 1 do
      local t = r.GetTrack(0, i)
      if t ~= tr then
        local _, nm = r.GetTrackName(t)
        if filter == '' or nm:lower():find(filter, 1, true) then
          cands[#cands + 1] = { t = t, nm = nm, i = i }
        end
      end
    end

    if r.ImGui_IsKeyPressed(ctx, r.ImGui_Key_UpArrow(), true) then fx_pick.sel = fx_pick.sel - 1 end
    if r.ImGui_IsKeyPressed(ctx, r.ImGui_Key_DownArrow(), true) then fx_pick.sel = fx_pick.sel + 1 end
    fx_pick.sel = clamp(fx_pick.sel, 1, math.max(1, #cands))
    local confirm = r.ImGui_IsKeyPressed(ctx, r.ImGui_Key_Enter(), false)
      or r.ImGui_IsKeyPressed(ctx, r.ImGui_Key_KeypadEnter(), false)

    if r.ImGui_BeginChild(ctx, 'pickcands', 300, 200) then
      for k, c in ipairs(cands) do
        if r.ImGui_Selectable(ctx, string.format('%d  %s###pc%d', c.i + 1, c.nm, k), fx_pick.sel == k) then
          fx_pick.sel = k
          confirm = true
        end
      end
      r.ImGui_EndChild(ctx)
    end

    if confirm and cands[fx_pick.sel] then
      local dest = cands[fx_pick.sel].t
      if fx_pick.mode == 'send' then
        r.CreateTrackSend(tr, dest)
      elseif fx_pick.mode == 'recv' then
        r.CreateTrackSend(dest, tr)
      else
        applySidechain(tr, dest, fx_pick.fxidx)
      end
      r.ImGui_CloseCurrentPopup(ctx)
      fx_pick = nil
    elseif r.ImGui_IsKeyPressed(ctx, r.ImGui_Key_Escape(), false) then
      r.ImGui_CloseCurrentPopup(ctx)
      fx_pick = nil
    end
    r.ImGui_EndPopup(ctx)
  else
    fx_pick = nil -- closed by clicking elsewhere
  end
end

-- right pane: generic param sliders for an FX row, send controls for a routing row
local function drawFXParams(tr, row)
  if not row then
    r.ImGui_TextColored(ctx, COL_TXT_DIM, 'Select a row on the left.')
    return
  end

  if row.kind ~= 'fx' then
    local cat, i = row.cat, row.i
    r.ImGui_TextColored(ctx, COL_TXT_DIM, row.kind == 'recv' and 'RECEIVE CONTROLS' or 'SEND CONTROLS')
    r.ImGui_Separator(ctx)

    local vol = r.GetTrackSendInfo_Value(tr, cat, i, 'D_VOL')
    local db = val2db(vol); if db < -60 then db = -60 end
    r.ImGui_Text(ctx, 'Volume'); r.ImGui_SameLine(ctx, 110); r.ImGui_SetNextItemWidth(ctx, -1)
    local vch, ndb = r.ImGui_SliderDouble(ctx, '##sxv', db, -60, 12, dbstr(vol))
    if vch then r.SetTrackSendInfo_Value(tr, cat, i, 'D_VOL', ndb <= -59.9 and 0 or 10 ^ (ndb / 20)) end

    local pan = r.GetTrackSendInfo_Value(tr, cat, i, 'D_PAN')
    local pfmt = math.abs(pan) < 0.005 and 'C'
      or (pan < 0 and ('L' .. math.floor(-pan * 100 + 0.5)) or ('R' .. math.floor(pan * 100 + 0.5)))
    r.ImGui_Text(ctx, 'Pan'); r.ImGui_SameLine(ctx, 110); r.ImGui_SetNextItemWidth(ctx, -1)
    local pch, npan = r.ImGui_SliderDouble(ctx, '##sxp', pan, -1, 1, pfmt)
    if pch then r.SetTrackSendInfo_Value(tr, cat, i, 'D_PAN', npan) end

    -- channel mapping: source pair -> destination pair
    r.ImGui_Text(ctx, 'Audio'); r.ImGui_SameLine(ctx, 110)
    if r.ImGui_ArrowButton(ctx, '##scl', r.ImGui_Dir_Left()) then cycleSendChan(tr, cat, i, false, -1) end
    r.ImGui_SameLine(ctx, 0, 4)
    r.ImGui_Text(ctx, chanPairLabel(r.GetTrackSendInfo_Value(tr, cat, i, 'I_SRCCHAN')))
    r.ImGui_SameLine(ctx, 0, 4)
    if r.ImGui_ArrowButton(ctx, '##scr', r.ImGui_Dir_Right()) then cycleSendChan(tr, cat, i, false, 1) end
    r.ImGui_SameLine(ctx, 0, 12); r.ImGui_Text(ctx, '->'); r.ImGui_SameLine(ctx, 0, 12)
    if r.ImGui_ArrowButton(ctx, '##dcl', r.ImGui_Dir_Left()) then cycleSendChan(tr, cat, i, true, -1) end
    r.ImGui_SameLine(ctx, 0, 4)
    r.ImGui_Text(ctx, chanPairLabel(r.GetTrackSendInfo_Value(tr, cat, i, 'I_DSTCHAN')))
    r.ImGui_SameLine(ctx, 0, 4)
    if r.ImGui_ArrowButton(ctx, '##dcr', r.ImGui_Dir_Right()) then cycleSendChan(tr, cat, i, true, 1) end

    if cat ~= 1 then -- MIDI passthrough only exists on track sends/receives
      local mflags = math.floor(r.GetTrackSendInfo_Value(tr, cat, i, 'I_MIDIFLAGS'))
      local midion = mflags % 32 ~= 31
      local mih, nmi = r.ImGui_Checkbox(ctx, 'MIDI', midion)
      if mih then
        r.SetTrackSendInfo_Value(tr, cat, i, 'I_MIDIFLAGS', nmi and 0 or 4294967295)
      end
    end

    if cat ~= 1 then -- send mode only applies to track sends/receives
      local smode = r.GetTrackSendInfo_Value(tr, cat, i, 'I_SENDMODE')
      r.ImGui_Text(ctx, 'Mode'); r.ImGui_SameLine(ctx, 110)
      local function moderadio(lbl, val)
        if r.ImGui_RadioButton(ctx, lbl, smode == val) then
          r.SetTrackSendInfo_Value(tr, cat, i, 'I_SENDMODE', val)
        end
        r.ImGui_SameLine(ctx)
      end
      moderadio('Post-Fader', 0)
      moderadio('Pre-FX', 1)
      moderadio('Post-FX', 3)
      r.ImGui_NewLine(ctx)
    end

    local mono = r.GetTrackSendInfo_Value(tr, cat, i, 'B_MONO') > 0
    local mch, nmono = r.ImGui_Checkbox(ctx, 'Mono', mono)
    if mch then r.SetTrackSendInfo_Value(tr, cat, i, 'B_MONO', nmono and 1 or 0) end
    r.ImGui_SameLine(ctx, 0, 16)
    local phase = r.GetTrackSendInfo_Value(tr, cat, i, 'B_PHASE') > 0
    local phch, nphase = r.ImGui_Checkbox(ctx, 'Invert phase', phase)
    if phch then r.SetTrackSendInfo_Value(tr, cat, i, 'B_PHASE', nphase and 1 or 0) end
    return
  end

  local fx = row.i
  local np = r.TrackFX_GetNumParams(tr, fx)
  local _, fxname = r.TrackFX_GetFXName(tr, fx, '')
  r.ImGui_TextColored(ctx, COL_TXT_DIM, ('PARAMETERS  -  %s  (%d)'):format(fxname, np))
  r.ImGui_Separator(ctx)
  fx_param_sel = clamp(fx_param_sel, 0, math.max(0, np - 1))

  for p = 0, np - 1 do
    local _, pname = r.TrackFX_GetParamName(tr, fx, p, '')
    if fx_param_sel == p then
      r.ImGui_TextColored(ctx, 0xFFD24AFF, pname)
    else
      r.ImGui_Text(ctx, pname)
    end
    if fx_pnav and fx_param_sel == p then r.ImGui_SetScrollHereY(ctx, 0.5) end
    if r.ImGui_IsItemClicked(ctx, 0) then fx_param_sel = p end
    r.ImGui_SameLine(ctx, 170)
    r.ImGui_SetNextItemWidth(ctx, -1)
    local v = r.TrackFX_GetParamNormalized(tr, fx, p)
    local _, disp = r.TrackFX_GetFormattedParamValue(tr, fx, p, '')
    local fmt = (disp or ''):gsub('%%', '%%%%')
    if fmt == '' then fmt = '%.2f' end
    local ch, nv = r.ImGui_SliderDouble(ctx, '##p' .. p, v, 0, 1, fmt)
    if ch then
      fx_param_sel = p
      r.TrackFX_SetParamNormalized(tr, fx, p, nv)
    end
  end
  fx_pnav = false
end

local function drawFXView()
  local n = r.CountTracks(0)
  if n == 0 then
    r.ImGui_Text(ctx, 'No tracks in project.  (Tab: back to deck)')
    return
  end
  local idx = selTrackIndex()
  if not idx then
    idx = 0
    r.SetOnlyTrackSelected(r.GetTrack(0, 0))
  end
  local tr = r.GetTrack(0, idx)
  local dl = r.ImGui_GetWindowDrawList(ctx)
  local availw = select(1, r.ImGui_GetContentRegionAvail(ctx))

  -- header: color band + track name + master send + hints
  local cr, cg, cb = trackRGB(tr)
  local hx, hy = r.ImGui_GetCursorScreenPos(ctx)
  r.ImGui_DrawList_AddRectFilled(dl, hx, hy, hx + availw, hy + 5, rgba(cr, cg, cb, 0xFF))
  r.ImGui_Dummy(ctx, 1, 7)
  local _, name = r.GetTrackName(tr)
  r.ImGui_Text(ctx, string.format('%d  %s', idx + 1, name))
  r.ImGui_SameLine(ctx, 0, 24)
  local ms = r.GetMediaTrackInfo_Value(tr, 'B_MAINSEND') > 0
  local ch, nms = r.ImGui_Checkbox(ctx, 'Master/parent send', ms)
  if ch then r.SetMediaTrackInfo_Value(tr, 'B_MAINSEND', nms and 1 or 0) end
  r.ImGui_SameLine(ctx, 0, 24)
  if r.ImGui_Button(ctx, '+ Send') then
    fx_pick = { mode = 'send', filter = '', sel = 1 }
    fx_pick_new = true
  end
  r.ImGui_SameLine(ctx, 0, 4)
  if r.ImGui_Button(ctx, '+ Receive') then
    fx_pick = { mode = 'recv', filter = '', sel = 1 }
    fx_pick_new = true
  end
  r.ImGui_SameLine(ctx, 0, 4)
  if r.ImGui_Button(ctx, '+ Sidechain') then
    local rowsel = buildFXRows(tr)[fx_sel]
    fx_pick = {
      mode = 'sc', filter = '', sel = 1,
      fxidx = (rowsel and rowsel.kind == 'fx') and rowsel.i or 0,
    }
    fx_pick_new = true
  end
  r.ImGui_SameLine(ctx, 0, 4)
  if r.ImGui_Button(ctx, '+ HW out') then
    local ok = pcall(r.CreateTrackSend, tr, nil)
    if not ok then r.Main_OnCommand(40293, 0) end -- fall back to the routing window
  end
  r.ImGui_SameLine(ctx, math.max(0, availw - 130))
  r.ImGui_TextColored(ctx, COL_TXT_DIM, 'Tab: back to deck')
  drawRoutePicker(tr)
  r.ImGui_Separator(ctx)

  local rows = buildFXRows(tr)
  fx_sel = clamp(fx_sel, 1, math.max(1, #rows))
  fxViewKeys(tr, idx, rows)
  rows = buildFXRows(tr) -- keys may have added/removed/reordered
  fx_sel = clamp(fx_sel, 1, math.max(1, #rows))

  -- rows list (left) + params pane (right)
  if r.ImGui_BeginChild(ctx, 'fxrows', availw * 0.45, -22) then
    local lastkind
    if #rows == 0 then
      r.ImGui_TextColored(ctx, COL_TXT_DIM, 'Empty chain, no routing.  Press A to add FX.')
    end
    for k, row in ipairs(rows) do
      if row.kind ~= lastkind then
        lastkind = row.kind
        r.ImGui_Dummy(ctx, 1, 6)
        r.ImGui_TextColored(ctx, COL_TXT_DIM, FXROW_KINDS[row.kind])
        r.ImGui_Separator(ctx)
      end

      local label
      local dim = false
      if row.kind == 'fx' then
        local en = r.TrackFX_GetEnabled(tr, row.i)
        local off = r.TrackFX_GetOffline(tr, row.i)
        local _, fxname = r.TrackFX_GetFXName(tr, row.i, '')
        local flag = off and '  [OFFLINE]' or (en and '' or '  [BYP]')
        label = string.format('%2d   %s%s', row.i + 1, fxname, flag)
        dim = off or not en
      else
        local sname
        if row.kind == 'recv' then
          local _, nm = r.GetTrackReceiveName(tr, row.i, '')
          sname = '<-  ' .. nm
        elseif row.kind == 'hw' then
          local _, nm = r.GetTrackSendName(tr, row.i, '')
          sname = '=>  ' .. nm
        else
          local hwn = r.GetTrackNumSends(tr, 1)
          local _, nm = r.GetTrackSendName(tr, hwn + row.i, '')
          sname = '->  ' .. nm
        end
        local mute = r.GetTrackSendInfo_Value(tr, row.cat, row.i, 'B_MUTE') > 0
        label = sname .. (mute and '  [MUTE]' or '')
        dim = mute
      end

      if dim then r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Text(), 0xFFFFFF66) end
      if r.ImGui_Selectable(ctx, label .. '###row' .. k, fx_sel == k) then
        if fx_sel ~= k then fx_param_sel = 0 end
        fx_sel = k
      end
      if dim then r.ImGui_PopStyleColor(ctx) end
      if fx_nav and fx_sel == k then
        r.ImGui_SetScrollHereY(ctx, 0.5)
      end
      if r.ImGui_IsItemHovered(ctx) and r.ImGui_IsMouseDoubleClicked(ctx, 0) and row.kind == 'fx' then
        fxFloatToggle(tr, row.i)
      end

      -- compact volume readout for routing rows (full controls in right pane)
      if row.kind ~= 'fx' then
        local rowsw = availw * 0.45
        r.ImGui_SameLine(ctx, math.max(150, rowsw - 120))
        r.ImGui_SetNextItemWidth(ctx, 106)
        local vol = r.GetTrackSendInfo_Value(tr, row.cat, row.i, 'D_VOL')
        local db = val2db(vol)
        if db < -60 then db = -60 end
        local sch, ndb = r.ImGui_SliderDouble(ctx, '##sv' .. k, db, -60, 12, dbstr(vol), NOINPUT)
        if sch then
          r.SetTrackSendInfo_Value(tr, row.cat, row.i, 'D_VOL', ndb <= -59.9 and 0 or 10 ^ (ndb / 20))
        end
      end
    end
    fx_nav = false
    r.ImGui_EndChild(ctx)
  end

  r.ImGui_SameLine(ctx)
  if r.ImGui_BeginChild(ctx, 'fxparams', 0, -22) then
    drawFXParams(tr, rows[fx_sel])
    r.ImGui_EndChild(ctx)
  end

  if fx_msg and os.clock() - fx_msg_t < 6 then
    r.ImGui_TextColored(ctx, 0x53E06AFF, fx_msg)
  else
    r.ImGui_TextColored(ctx, COL_TXT_DIM,
      'up/down row   , . param   - = value   enter/F float   B bypass   O offline   Del remove   ctrl+up/down reorder   alt+up/down send vol   [ ] send chans (shift: dest)   N send   shift+N receive   C sidechain   A add FX   I routing   left/right track   Q quantize')
  end
end

--------------------------------------------------------------------- toolbar

local function drawToolbar(availw)
  if view_mode == 'edit' then
    r.ImGui_TextColored(ctx, 0xFFD24AFF, 'EDIT')
    if r.ImGui_IsItemHovered(ctx) then
      r.ImGui_SetTooltip(ctx, 'Playlist editor: scrub, items, record.  Esc: back to mixer, Tab: FX view')
    end
  else
    r.ImGui_TextColored(ctx, COL_TXT_DIM, 'MIX')
    if r.ImGui_IsItemHovered(ctx) then
      r.ImGui_SetTooltip(ctx, 'Mixer: volume/pan/mute etc.  Enter: playlist editor, Tab: FX view')
    end
  end
  r.ImGui_SameLine(ctx, 0, 12)

  local ch, nf = r.ImGui_Checkbox(ctx, 'Follow', follow)
  if ch then follow = nf; follow_hold = false; save() end

  if scrub then
    r.ImGui_SameLine(ctx, 0, 6)
    r.ImGui_TextColored(ctx, 0xFFD24AFF,
      ('SCRUB %s %.2fx'):format(scrub.dir and scrub.dir < 0 and '^' or 'v', scrub_speed))
  end

  r.ImGui_SameLine(ctx, 0, 10)
  local oc, noc = r.ImGui_Checkbox(ctx, '1cur', one_cursor)
  if oc then one_cursor = noc; save() end
  if r.ImGui_IsItemHovered(ctx) and r.ImGui_BeginTooltip(ctx) then
    r.ImGui_Text(ctx, 'One cursor: when playback stops or pauses (from anywhere),')
    r.ImGui_Text(ctx, 'the edit cursor moves to where playback stopped instead of')
    r.ImGui_Text(ctx, 'jumping back to where it started.')
    r.ImGui_EndTooltip(ctx)
  end

  r.ImGui_SameLine(ctx, 0, 14)
  r.ImGui_Text(ctx, 'Zoom')
  r.ImGui_SameLine(ctx)
  if r.ImGui_Button(ctx, '-##z', 22, 0) then pps = clamp(pps / 1.25, MIN_PPS, MAX_PPS); save() end
  r.ImGui_SameLine(ctx, 0, 2)
  if r.ImGui_Button(ctx, '+##z', 22, 0) then pps = clamp(pps * 1.25, MIN_PPS, MAX_PPS); save() end

  r.ImGui_SameLine(ctx, 0, 14)
  r.ImGui_Text(ctx, 'Width')
  r.ImGui_SameLine(ctx)
  if r.ImGui_Button(ctx, '-##w', 22, 0) then colw = clamp(colw - 8, MIN_COLW, MAX_COLW); save() end
  r.ImGui_SameLine(ctx, 0, 2)
  if r.ImGui_Button(ctx, '+##w', 22, 0) then colw = clamp(colw + 8, MIN_COLW, MAX_COLW); save() end

  r.ImGui_SameLine(ctx, 0, 14)
  local dockid = r.ImGui_GetWindowDockID(ctx)
  local dch, docked = r.ImGui_Checkbox(ctx, 'Dock', dockid ~= 0)
  if dch then pending_dock = docked and -3 or 0 end

  r.ImGui_SameLine(ctx, 0, 14)
  r.ImGui_Button(ctx, '?', 22, 0)
  if r.ImGui_IsItemHovered(ctx) and r.ImGui_BeginTooltip(ctx) then
    r.ImGui_Text(ctx, 'Mouse')
    r.ImGui_TextColored(ctx, COL_TXT_DIM, 'wheel: scroll time   ctrl+wheel: zoom   shift+wheel: tracks')
    r.ImGui_TextColored(ctx, COL_TXT_DIM, 'click lane: seek   drag item: move in time   dbl-click MIDI: editor')
    r.ImGui_Text(ctx, 'Modes')
    r.ImGui_TextColored(ctx, COL_TXT_DIM, 'MIX (default) --Enter--> EDIT (playlist)   Tab: FX view   Esc: back')
    r.ImGui_Text(ctx, 'MIX mode (selected track)')
    r.ImGui_TextColored(ctx, COL_TXT_DIM, 'left/right: switch track   up/down: volume (shift: fine)   alt+lr: pan')
    r.ImGui_TextColored(ctx, COL_TXT_DIM, 'M: mute   S: solo   R: arm   F: fx chain   Q: quantize   0: reset vol')
    r.ImGui_Text(ctx, 'EDIT mode (playlist editor)')
    r.ImGui_TextColored(ctx, COL_TXT_DIM, 'Space: play/stop   up/down HOLD: scrub audio (down = forward),')
    r.ImGui_TextColored(ctx, COL_TXT_DIM, '  release = pause + select item under cursor.  shift 6x / alt 0.2x')
    r.ImGui_TextColored(ctx, COL_TXT_DIM, '- =: scrub speed')
    r.ImGui_TextColored(ctx, COL_TXT_DIM, 'Enter: MIDI under cursor -> MIDI editor, else cursor to item start')
    r.ImGui_TextColored(ctx, COL_TXT_DIM, 'E: MIDI editor   X: split   D: duplicate')
    r.ImGui_TextColored(ctx, COL_TXT_DIM, 'Del: remove   , .: nudge by grid   R: record (auto-arms)   Q: quantize')
    r.ImGui_EndTooltip(ctx)
  end

  local pos = playing and playpos or editpos
  local ptxt = r.format_timestr_pos(pos, '', 2)
  local tw = r.ImGui_CalcTextSize(ctx, ptxt)
  r.ImGui_SameLine(ctx, math.max(0, availw - tw - 8))
  r.ImGui_Text(ctx, ptxt)
end

----------------------------------------------------------------------- frame

local function frame()
  playing = (r.GetPlayState() & 1) == 1
  playpos = r.GetPlayPosition()
  editpos = r.GetCursorPosition()

  -- one cursor: whenever playback stops or pauses (no matter who stopped it),
  -- park the edit cursor where playback actually was, not where it started
  if one_cursor then
    if was_playing and not playing then
      r.SetEditCurPos(last_play, false, false)
      editpos = last_play
    end
    if playing then last_play = playpos end
  end
  was_playing = playing

  handleKeys()
  handleTransport()

  if view_mode == 'fx' then
    drawFXView()
    return
  end

  local availw = select(1, r.ImGui_GetContentRegionAvail(ctx))
  drawToolbar(availw)

  local _, availh = r.ImGui_GetContentRegionAvail(ctx)
  if view_mode == 'edit' then
    strip_h = 30 -- playlist editor: just a name tab per column, lanes get the room
  else
    strip_h = math.floor(math.min(STRIP_H_MAX, math.max(120, availh * 0.55)))
  end
  lane_h = math.max(40, availh - strip_h)

  if playing and follow and not follow_hold then
    local y = (playpos - scroll_t) * pps
    if y < 0 or y > lane_h * 0.8 then
      scroll_t = math.max(0, playpos - lane_h * 0.2 / pps)
    end
  end
  if not playing then follow_hold = false end

  -- left pane: time ruler + master strip
  if r.ImGui_BeginChild(ctx, 'left', RULER_W + colw, 0) then
    local dl = r.ImGui_GetWindowDrawList(ctx)
    local wx, wy = r.ImGui_GetWindowPos(ctx)
    local ww = RULER_W + colw

    r.ImGui_SetCursorPos(ctx, 0, 0)
    r.ImGui_InvisibleButton(ctx, 'ruler', ww, lane_h)
    if r.ImGui_IsItemActive(ctx) then
      local _, my = r.ImGui_GetMousePos(ctx)
      r.SetEditCurPos(maybeSnap(math.max(0, scroll_t + (my - wy) / pps)), false, true)
    end
    if r.ImGui_IsItemHovered(ctx) then laneWheel(wy, false) end

    r.ImGui_DrawList_PushClipRect(dl, wx, wy, wx + ww, wy + lane_h, true)
    r.ImGui_DrawList_AddRectFilled(dl, wx, wy, wx + RULER_W, wy + lane_h, 0x00000050)
    eachMeasure(scroll_t, scroll_t + lane_h / pps, function(m, mt)
      local y = wy + (mt - scroll_t) * pps
      r.ImGui_DrawList_AddLine(dl, wx, y, wx + RULER_W, y, COL_MEASURE, 1)
      r.ImGui_DrawList_AddText(dl, wx + 4, y + 2, COL_TXT_DIM, tostring(m + 1))
    end)
    r.ImGui_DrawList_PopClipRect(dl)
    drawCursors(dl, wx, wx + ww, wy, wy + lane_h)

    if view_mode ~= 'edit' then
      r.ImGui_SetCursorPos(ctx, RULER_W + 2, lane_h + 2)
      local vis = beginStripChild('stripM')
      if vis then drawStrip(r.GetMasterTrack(0), 0) end
      endStripChild(vis)
    end
    r.ImGui_EndChild(ctx)
  end

  r.ImGui_SameLine(ctx, 0, 4)

  -- deck: one column per track (lane above, strip below), shared horizontal scroll
  local deckflags = r.ImGui_WindowFlags_HorizontalScrollbar() | r.ImGui_WindowFlags_NoScrollWithMouse()
  if r.ImGui_BeginChild(ctx, 'deck', 0, 0, 0, deckflags) then
    local dl = r.ImGui_GetWindowDrawList(ctx)
    local wx, wy = r.ImGui_GetWindowPos(ctx)
    local vw, vh = r.ImGui_GetWindowSize(ctx)
    if scroll_to_track then -- keep keyboard-selected track in view
      local x0 = scroll_to_track * colw
      local cur = r.ImGui_GetScrollX(ctx)
      if x0 < cur then
        r.ImGui_SetScrollX(ctx, x0)
      elseif x0 + colw > cur + vw then
        r.ImGui_SetScrollX(ctx, x0 + colw - vw)
      end
      scroll_to_track = nil
    end
    local sx = r.ImGui_GetScrollX(ctx)
    local laneY0, laneY1 = wy, wy + lane_h
    local n = r.CountTracks(0)

    -- background pass: column tints, separators, grid, loop region
    r.ImGui_DrawList_PushClipRect(dl, wx, laneY0, wx + vw, laneY1, true)
    for i = 0, n - 1 do
      local cx = wx - sx + i * colw
      if cx + colw >= wx and cx <= wx + vw then
        local tr = r.GetTrack(0, i)
        if r.IsTrackSelected(tr) then
          r.ImGui_DrawList_AddRectFilled(dl, cx, laneY0, cx + colw, laneY1, COL_SELCOL)
        elseif i % 2 == 1 then
          r.ImGui_DrawList_AddRectFilled(dl, cx, laneY0, cx + colw, laneY1, COL_ALTCOL)
        end
        r.ImGui_DrawList_AddLine(dl, cx + colw, laneY0, cx + colw, laneY1, COL_SEP, 1)
      end
    end
    r.ImGui_DrawList_PopClipRect(dl)
    drawGrid(dl, wx, wx + vw, laneY0, laneY1)

    -- columns
    for i = 0, n - 1 do
      local tr = r.GetTrack(0, i)
      r.ImGui_SetCursorPos(ctx, i * colw, 0)
      r.ImGui_InvisibleButton(ctx, 'lane' .. i, colw, lane_h)
      local bx = select(1, r.ImGui_GetItemRectMin(ctx))
      laneInteraction(tr, laneY0)
      if bx + colw >= wx and bx <= wx + vw then
        drawLaneItems(dl, tr, bx, laneY0, laneY1)
      end
      if view_mode == 'edit' then
        -- playlist editor: color band + name tab only
        r.ImGui_SetCursorPos(ctx, i * colw + 2, lane_h + 2)
        local tx2, ty2 = r.ImGui_GetCursorScreenPos(ctx)
        local cr2, cg2, cb2 = trackRGB(tr)
        r.ImGui_DrawList_AddRectFilled(dl, tx2, ty2, tx2 + colw - 4, ty2 + 3, rgba(cr2, cg2, cb2, 0xFF))
        r.ImGui_SetCursorPos(ctx, i * colw + 2, lane_h + 6)
        local _, nm2 = r.GetTrackName(tr)
        if r.ImGui_Selectable(ctx, string.format('%d %s###nt%d', i + 1, nm2, i),
            r.IsTrackSelected(tr), 0, colw - 4, strip_h - 8) then
          r.SetOnlyTrackSelected(tr)
          r.UpdateArrange()
        end
      else
        r.ImGui_SetCursorPos(ctx, i * colw + 2, lane_h + 2)
        local vis = beginStripChild('strip' .. i)
        if vis then drawStrip(tr, i + 1) end
        endStripChild(vis)
      end
    end

    if n == 0 then
      r.ImGui_SetCursorPos(ctx, 20, 20)
      r.ImGui_Text(ctx, 'No tracks in project.')
      r.ImGui_SetCursorPos(ctx, 20, 44)
      if r.ImGui_Button(ctx, 'Insert track') then r.Main_OnCommand(40001, 0) end
    end

    drawCursors(dl, wx, wx + vw, laneY0, laneY1)
    processDrag()

    local mx, my = r.ImGui_GetMousePos(ctx)
    if mx >= wx and mx <= wx + vw and my >= wy and my <= wy + vh then
      laneWheel(laneY0, true)
    end
    r.ImGui_EndChild(ctx)
  end
end

------------------------------------------------------------------- main loop

local function loop()
  if pending_dock then
    r.ImGui_SetNextWindowDockID(ctx, pending_dock, r.ImGui_Cond_Always())
    pending_dock = nil
  end
  r.ImGui_SetNextWindowSize(ctx, 1100, 620, r.ImGui_Cond_FirstUseEver())
  local wflags = r.ImGui_WindowFlags_NoScrollbar() | r.ImGui_WindowFlags_NoScrollWithMouse()
    | r.ImGui_WindowFlags_NoNav()
  local visible, open = r.ImGui_Begin(ctx, 'MixLab###MixLab', true, wflags)
  if visible then
    local ok, err = pcall(frame)
    r.ImGui_End(ctx)
    if not ok then
      r.ShowConsoleMsg('MixLab error: ' .. tostring(err) .. '\n')
      open = false
    end
  end
  if open then
    r.defer(loop)
  else
    endScrub(false) -- never leave playrate/preserve-pitch altered
    save()
  end
end

r.defer(loop)
