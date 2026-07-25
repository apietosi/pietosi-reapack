-- @description PietosiQuantize - audio quantizer with onset backtracking
-- @version 0.1.0
-- @author pie
-- @provides [main=main] .
-- @about
--   Transient-based audio quantizer for selected items. Designed to fix the
--   common failure modes of envelope-gate quantizers:
--   * Onset backtracking: after the envelope gate fires, the detector walks
--     backward to the real attack start, so detection points don't lag hot
--     hits less and soft hits more.
--   * No hidden retrigger floor: the Retrig slider is honored down to 5 ms,
--     so fast rolls and flams stay separate hits.
--   * Grid matching keeps the CLOSEST or the STRONGEST transient per gridline
--     (selectable) and quantizes each hit to the line it matched, never to
--     "whatever grid happens to be nearest after moving".
--   * Grid is computed from the project tempo map + swing directly; the
--     script never touches snap settings or the arrange view.
--   Analyze the sum of all selected items (multitrack-safe: cuts land at the
--   same times on every selected track), audition the markers on the
--   waveform, click markers to drop bad ones, then apply in Split mode
--   (split + move + heal + crossfade) or Warp mode (stretch markers).
--   Requires ReaImGui. No SWS needed.

local r = reaper

if not r.ImGui_CreateContext then
  r.MB('PietosiQuantize needs the ReaImGui extension.\n\nInstall via ReaPack: Extensions > ReaPack > Browse packages > "ReaImGui".', 'PietosiQuantize', 0)
  return
end

local SR = 44100          -- analysis samplerate (accessor resamples for us)
local BLOCK = 65536       -- analysis block size (samples)
local MAX_LEN = 8 * 60    -- refuse to analyze more than 8 minutes
local GUI_BINS = 4096     -- waveform display resolution

--------------------------------------------------------------------- settings

local function numSetting(key, def)
  return tonumber(r.GetExtState('PQuant', key)) or def
end
local function boolSetting(key, def)
  local v = r.GetExtState('PQuant', key)
  if v == '' then return def end
  return v == '1'
end

local P = {
  thresh   = numSetting('thresh', -30),  -- dB gate threshold
  crest    = numSetting('crest', 4),     -- dB fast/slow envelope ratio
  retrig   = numSetting('retrig', 40),   -- ms minimum distance between hits
  attack   = numSetting('attack', 20),   -- % of peak that counts as onset start
  hp       = numSetting('hp', 60),       -- detection highpass Hz
  lp       = numSetting('lp', 12000),    -- detection lowpass Hz
  gain     = numSetting('gain', 0),      -- detection gain dB
  sens     = numSetting('sens', 0),      -- % weakest hits to drop
  gridscan = boolSetting('gridscan', true),
  gridtol  = numSetting('gridtol', 60),  -- ms grid match tolerance
  strongest= boolSetting('strongest', true), -- match strongest (vs closest)
  qstr     = numSetting('qstr', 90),     -- % quantize strength
  pad      = numSetting('pad', 5),       -- ms leading pad before onset cuts
  xfade    = numSetting('xfade', 8),     -- ms crossfade
  warp     = boolSetting('warp', false), -- warp mode instead of split
}

local function saveSettings()
  for k, v in pairs(P) do
    r.SetExtState('PQuant', k, type(v) == 'boolean' and (v and '1' or '0') or tostring(v), true)
  end
end

----------------------------------------------------------------------- state

local A = nil
-- analysis result: {
--   t0, t1          analysis range (project time)
--   items           source items {item, take, pos, fin, nch, track}
--   tracks          ordered list of tracks involved
--   bins_max        GUI waveform peaks
--   markers         { t, strength(0..1), enabled, matched(line time or nil) }
--   gridlines       { t, strong(bool) } at analysis time (redrawn live too)
-- }

local view_t0, view_t1 = 0, 1 -- waveform view range
local status = 'Select items, then Analyze.'
local last_err = nil

local abs, floor, ceil, exp, sqrt = math.abs, math.floor, math.ceil, math.exp, math.sqrt

local function clamp(v, lo, hi)
  if v < lo then return lo elseif v > hi then return hi else return v end
end

------------------------------------------------------------------------ grid

-- project gridlines (with swing) between ta..tb, computed from the tempo map.
-- REAPER swing 100% pushes the offbeat to the triplet position (div/3 in QN).
local function gridLines(ta, tb)
  local _, division, swingmode, swingamt = r.GetSetProjectGrid(0, false)
  local div_qn = division * 4
  if div_qn <= 0 then div_qn = 1 end
  local lines = {}
  local qa = r.TimeMap2_timeToQN(0, ta)
  local k = floor(qa / div_qn) - 1
  for _ = 1, 100000 do
    local qn = k * div_qn
    if swingmode == 1 and k % 2 ~= 0 then
      qn = qn + swingamt * div_qn / 3
    end
    local t = r.TimeMap2_QNToTime(0, qn)
    if t > tb then break end
    if t >= ta then
      lines[#lines + 1] = { t = t, strong = (k * div_qn) % 1 < 1e-9 }
    end
    k = k + 1
  end
  return lines
end

--------------------------------------------------------------------- analyze

local function collectSourceItems()
  local n = r.CountSelectedMediaItems(0)
  if n == 0 then return nil, 'No items selected.' end
  local items, tracks, seen = {}, {}, {}
  local t0, t1 = math.huge, -math.huge
  for i = 0, n - 1 do
    local it = r.GetSelectedMediaItem(0, i)
    local tk = r.GetActiveTake(it)
    if tk and not r.TakeIsMIDI(tk) then
      local src = r.GetMediaItemTake_Source(tk)
      local pos = r.GetMediaItemInfo_Value(it, 'D_POSITION')
      local fin = pos + r.GetMediaItemInfo_Value(it, 'D_LENGTH')
      items[#items + 1] = {
        item = it, take = tk, pos = pos, fin = fin,
        nch = clamp(r.GetMediaSourceNumChannels(src), 1, 4),
        track = r.GetMediaItemTrack(it),
      }
      t0, t1 = math.min(t0, pos), math.max(t1, fin)
      local tr = r.GetMediaItemTrack(it)
      if not seen[tostring(tr)] then
        seen[tostring(tr)] = true
        tracks[#tracks + 1] = tr
      end
    end
  end
  if #items == 0 then return nil, 'No audio items selected (MIDI items are ignored).' end
  if t1 - t0 > MAX_LEN then return nil, ('Selection is %.0f s — max is %d s.'):format(t1 - t0, MAX_LEN) end
  return { items = items, tracks = tracks, t0 = t0, t1 = t1 }
end

local function analyze()
  last_err = nil
  local src, err = collectSourceItems()
  if not src then status = err return end

  local t0, t1 = src.t0, src.t1
  local total = floor((t1 - t0) * SR)
  if total < SR * 0.02 then status = 'Selection too short.' return end

  -- audio accessors per item
  for _, it in ipairs(src.items) do
    it.acc = r.CreateTakeAudioAccessor(it.take)
  end

  -- detector setup ------------------------------------------------------
  local thresh = 10 ^ (P.thresh / 20)
  local crest = 10 ^ (P.crest / 20)
  local gaindb = 10 ^ (P.gain / 20)
  local attackfrac = clamp(P.attack / 100, 0.02, 0.9)
  local retrig_s = floor(clamp(P.retrig, 5, 500) / 1000 * SR)
  local peakwin = floor(0.020 * SR)  -- look 20 ms ahead of the gate for the peak
  local backwin = floor(0.040 * SR)  -- backtrack up to 40 ms for the onset

  local ga1, gr1 = exp(-1 / (SR * 0.001)), exp(-1 / (SR * 0.010)) -- fast env
  local ga2, gr2 = exp(-1 / (SR * 0.007)), exp(-1 / (SR * 0.015)) -- slow env
  local hp_a = exp(-2 * math.pi * clamp(P.hp, 20, 20000) / SR)
  local lp_b = 1 - exp(-2 * math.pi * clamp(P.lp, 20, 20000) / SR)

  local env1, env2, hp_y, hp_x, lp_y = 0, 0, 0, 0, 0
  local ring, RINGSZ = {}, 8192 -- recent detection samples for backtracking
  for i = 1, RINGSZ do ring[i] = 0 end

  local markers = {}
  local pending = nil -- { gate_i, peak, peak_i, until_i }
  local lastonset = -retrig_s

  local bins_max = {}
  for i = 1, GUI_BINS do bins_max[i] = 0 end
  local binsize = total / GUI_BINS

  -- streaming main loop --------------------------------------------------
  local buf = r.new_array(BLOCK * 8)
  local acc = {}
  local gi = 0 -- global sample index

  for b0 = 0, total - 1, BLOCK do
    local n = math.min(BLOCK, total - b0)
    for i = 1, n do acc[i] = 0 end
    local bt0 = t0 + b0 / SR

    for _, it in ipairs(src.items) do
      local ov0 = math.max(bt0, it.pos)
      local ov1 = math.min(bt0 + n / SR, it.fin)
      if ov1 > ov0 then
        local nsm = floor((ov1 - ov0) * SR)
        local dst = floor((ov0 - bt0) * SR)
        if nsm > 0 then
          buf.clear()
          r.GetAudioAccessorSamples(it.acc, SR, it.nch, ov0 - it.pos, nsm, buf)
          local t = buf.table(1, nsm * it.nch)
          local nch = it.nch
          for i = 0, nsm - 1 do
            local s = 0
            local base = i * nch
            for c = 1, nch do s = s + t[base + c] end
            local d = dst + i + 1
            if d >= 1 and d <= n then acc[d] = acc[d] + s / nch end
          end
        end
      end
    end

    -- detect over this block
    for i = 1, n do
      gi = gi + 1
      local x = acc[i] * gaindb
      -- detection filters (one-pole HP then LP)
      hp_y = hp_a * (hp_y + x - hp_x); hp_x = x
      lp_y = lp_y + lp_b * (hp_y - lp_y)
      local d = lp_y
      if d < 0 then d = -d end
      ring[(gi - 1) % RINGSZ + 1] = d

      -- GUI peaks (of the unfiltered sum)
      local ax = x < 0 and -x or x
      local bin = floor((gi - 1) / binsize) + 1
      if bin >= 1 and bin <= GUI_BINS and ax > bins_max[bin] then bins_max[bin] = ax end

      if env1 < d then env1 = d + ga1 * (env1 - d) else env1 = d + gr1 * (env1 - d) end
      if env2 < d then env2 = d + ga2 * (env2 - d) else env2 = d + gr2 * (env2 - d) end

      if pending then
        if d > pending.peak then pending.peak, pending.peak_i = d, gi end
        if gi >= pending.until_i then
          -- backtrack from the gate point to the true onset: walk back while
          -- the detection signal stays above attackfrac * peak
          local want = pending.peak * attackfrac
          local onset = pending.gate_i
          local lim = math.max(1, pending.gate_i - backwin)
          for j = pending.gate_i, lim, -1 do
            if gi - j >= RINGSZ then break end
            if ring[(j - 1) % RINGSZ + 1] < want then break end
            onset = j
          end
          if onset - lastonset >= retrig_s then
            markers[#markers + 1] = { smp = onset, strength = pending.peak }
            lastonset = onset
          end
          pending = nil
        end
      elseif env1 > thresh and env2 > 0 and (env1 / env2) > crest and gi - lastonset >= retrig_s then
        pending = { gate_i = gi, peak = d, peak_i = gi, until_i = gi + peakwin }
      end
    end
  end

  for _, it in ipairs(src.items) do
    r.DestroyAudioAccessor(it.acc)
    it.acc = nil
  end

  -- normalize strengths, build marker times ------------------------------
  local smax = 0
  for _, m in ipairs(markers) do smax = math.max(smax, m.strength) end
  for _, m in ipairs(markers) do
    m.t = t0 + m.smp / SR
    m.strength = smax > 0 and m.strength / smax or 0
    m.enabled = true
  end

  A = {
    t0 = t0, t1 = t1, items = src.items, tracks = src.tracks,
    bins_max = bins_max, markers = markers,
  }
  view_t0, view_t1 = t0, t1
  status = ('%d transients found on %d track%s.'):format(#markers, #src.tracks, #src.tracks == 1 and '' or 's')
end

------------------------------------------------------- marker filtering/grid

-- returns the list of markers that will actually be used, each with .target
local function activeMarkers()
  if not A then return {} end
  local out = {}
  local cut = P.sens / 100
  local kept = {}
  for _, m in ipairs(A.markers) do
    m.dropped = (m.strength < cut)
    m.matched = nil
    if m.enabled and not m.dropped then kept[#kept + 1] = m end
  end
  local lines = gridLines(A.t0 - 0.5, A.t1 + 0.5)

  if P.gridscan then
    local tol = P.gridtol / 1000
    for _, ln in ipairs(lines) do
      local best
      for _, m in ipairs(kept) do
        local d = abs(m.t - ln.t)
        if d <= tol and not m.matched then
          if not best then
            best = m
          elseif P.strongest then
            if m.strength > best.strength then best = m end
          else
            if d < abs(best.t - ln.t) then best = m end
          end
        end
      end
      if best then
        best.matched = ln.t
        out[#out + 1] = best
      end
    end
    table.sort(out, function(a, b) return a.t < b.t end)
  else
    for _, m in ipairs(kept) do
      -- nearest gridline as target
      local best, bd = nil, math.huge
      for _, ln in ipairs(lines) do
        local d = abs(m.t - ln.t)
        if d < bd then best, bd = ln.t, d end
      end
      m.matched = best
      out[#out + 1] = m
    end
  end
  return out, lines
end

------------------------------------------------------------------ apply edit

local function applySplit(marks)
  local q = clamp(P.qstr, 0, 100) / 100
  local pad = clamp(P.pad, 0, 50) / 1000
  local xf = clamp(P.xfade, 0, 50) / 1000

  -- cuts: one per marker, all tracks at the same time (multitrack lock)
  local cuts = {}
  for i, m in ipairs(marks) do
    cuts[i] = { t = m.t - pad, delta = (m.matched - m.t) * q }
  end

  for _, srcit in ipairs(A.items) do
    if r.ValidatePtr2(0, srcit.item, 'MediaItem*') then
      local slices = { { it = srcit.item, cut = nil } }
      local cur = srcit.item
      for ci, c in ipairs(cuts) do
        local pos = r.GetMediaItemInfo_Value(cur, 'D_POSITION')
        local len = r.GetMediaItemInfo_Value(cur, 'D_LENGTH')
        if c.t > pos + 0.0005 and c.t < pos + len - 0.0005 then
          local right = r.SplitMediaItem(cur, c.t)
          if right then
            slices[#slices + 1] = { it = right, cut = ci }
            cur = right
          end
        end
      end
      -- move slices by their cut's delta
      for _, s in ipairs(slices) do
        if s.cut then
          local d = cuts[s.cut].delta
          if d ~= 0 then
            r.SetMediaItemInfo_Value(s.it, 'D_POSITION',
              r.GetMediaItemInfo_Value(s.it, 'D_POSITION') + d)
          end
        end
      end
      -- heal gaps / overlaps + crossfades
      for i = 1, #slices - 1 do
        local L, R = slices[i].it, slices[i + 1].it
        local lpos = r.GetMediaItemInfo_Value(L, 'D_POSITION')
        local rpos = r.GetMediaItemInfo_Value(R, 'D_POSITION')
        local newlen = rpos - lpos
        if newlen > 0.0001 then
          if xf > 0 then
            r.SetMediaItemInfo_Value(L, 'D_LENGTH', newlen + xf)
            r.SetMediaItemInfo_Value(L, 'D_FADEOUTLEN', xf)
            r.SetMediaItemInfo_Value(R, 'D_FADEINLEN', xf)
          else
            r.SetMediaItemInfo_Value(L, 'D_LENGTH', newlen)
          end
        end
      end
    end
  end
end

local function applyWarp(marks)
  local q = clamp(P.qstr, 0, 100) / 100
  for _, srcit in ipairs(A.items) do
    if r.ValidatePtr2(0, srcit.item, 'MediaItem*') then
      local take = srcit.take
      local pos = r.GetMediaItemInfo_Value(srcit.item, 'D_POSITION')
      local len = r.GetMediaItemInfo_Value(srcit.item, 'D_LENGTH')
      local rate = r.GetMediaItemTakeInfo_Value(take, 'D_PLAYRATE')
      local nsm = r.GetTakeNumStretchMarkers(take)
      if nsm > 0 then r.DeleteTakeStretchMarkers(take, 0, nsm) end
      -- anchors at the edges, one marker per onset
      r.SetTakeStretchMarker(take, -1, 0)
      r.SetTakeStretchMarker(take, -1, len * rate)
      local idxs = {}
      for _, m in ipairs(marks) do
        if m.t > pos + 0.001 and m.t < pos + len - 0.001 then
          local mpos = (m.t - pos) * rate
          local mi = r.SetTakeStretchMarker(take, -1, mpos)
          idxs[#idxs + 1] = { mi = mi, from = mpos, to = ((m.t + (m.matched - m.t) * q) - pos) * rate }
        end
      end
      for _, w in ipairs(idxs) do
        local _, _, srcpos = r.GetTakeStretchMarker(take, w.mi)
        r.SetTakeStretchMarker(take, w.mi, w.to, srcpos)
      end
      r.UpdateItemInProject(srcit.item)
    end
  end
end

local function apply()
  if not A then status = 'Analyze first.' return end
  local marks = activeMarkers()
  if #marks == 0 then status = 'No active transients to quantize.' return end

  r.PreventUIRefresh(1)
  r.Undo_BeginBlock2(0)
  local ok, err = pcall(P.warp and applyWarp or applySplit, marks)
  r.Undo_EndBlock2(0, 'PietosiQuantize: ' .. (P.warp and 'warp' or 'split & quantize'), -1)
  r.PreventUIRefresh(-1)
  r.UpdateArrange()

  if ok then
    status = ('Quantized %d hits (%s mode). Ctrl+Z undoes it in one step.'):format(#marks, P.warp and 'warp' or 'split')
    A = nil -- item pointers are stale after splitting; require re-analyze
  else
    last_err = tostring(err)
    status = 'Apply failed: ' .. last_err
  end
end

------------------------------------------------------------------------- GUI

local ctx = r.ImGui_CreateContext('PietosiQuantize')

local COL_WAVE   = 0x6FB3E0FF
local COL_GRID   = 0xFFFFFF30
local COL_GRIDS  = 0xFFFFFF60
local COL_MARK   = 0x53E06AFF
local COL_MARK_D = 0xE05353C0
local COL_DIM    = 0x888888A0
local COL_TXT    = 0xFFFFFF88

local function sliderD(label, key, lo, hi, fmt, w)
  r.ImGui_SetNextItemWidth(ctx, w or 150)
  local ch, v = r.ImGui_SliderDouble(ctx, '##' .. key, P[key], lo, hi, fmt)
  if ch then P[key] = v end
  if r.ImGui_IsItemDeactivatedAfterEdit(ctx) then saveSettings() end
  return ch
end

local function toggle(label, key)
  local ch, v = r.ImGui_Checkbox(ctx, label, P[key])
  if ch then P[key] = v; saveSettings() end
  return ch
end

local wave_dragged = 0 -- px moved during current drag, to tell click from pan

local function waveformPanel(lines)
  local availw, _ = r.ImGui_GetContentRegionAvail(ctx)
  local h = 210
  r.ImGui_InvisibleButton(ctx, 'wave', availw, h)
  local x0, y0 = r.ImGui_GetItemRectMin(ctx)
  local x1, y1 = r.ImGui_GetItemRectMax(ctx)
  local dl = r.ImGui_GetWindowDrawList(ctx)
  r.ImGui_DrawList_AddRectFilled(dl, x0, y0, x1, y1, 0x14171AFF, 4)
  if not A then
    r.ImGui_DrawList_AddText(dl, x0 + 12, y0 + 12, COL_TXT, 'No analysis yet.')
    return
  end

  local span = view_t1 - view_t0
  if span <= 0 then span = 0.001 end
  local function tx(t) return x0 + (t - view_t0) / span * (x1 - x0) end
  local midy = (y0 + y1) / 2
  local hh = (y1 - y0) / 2 - 4

  r.ImGui_DrawList_PushClipRect(dl, x0, y0, x1, y1, true)

  -- gridlines (live from project)
  for _, ln in ipairs(lines or {}) do
    if ln.t >= view_t0 and ln.t <= view_t1 then
      local x = tx(ln.t)
      r.ImGui_DrawList_AddLine(dl, x, y0, x, y1, ln.strong and COL_GRIDS or COL_GRID, ln.strong and 2 or 1)
    end
  end

  -- waveform from analysis bins
  local total = A.t1 - A.t0
  for px = 0, floor(x1 - x0) - 1 do
    local t = view_t0 + px / (x1 - x0) * span
    local bin = floor((t - A.t0) / total * GUI_BINS) + 1
    if bin >= 1 and bin <= GUI_BINS then
      local v = clamp(A.bins_max[bin], 0, 1) * hh
      if v > 0.5 then
        r.ImGui_DrawList_AddLine(dl, x0 + px, midy - v, x0 + px, midy + v, COL_WAVE, 1)
      end
    end
  end

  -- threshold line
  local tl = clamp(10 ^ (P.thresh / 20), 0, 1) * hh
  r.ImGui_DrawList_AddLine(dl, x0, midy - tl, x1, midy - tl, 0xE0C05360, 1)

  -- markers
  for _, m in ipairs(A.markers) do
    if m.t >= view_t0 and m.t <= view_t1 then
      local x = tx(m.t)
      local col
      if not m.enabled then col = COL_MARK_D
      elseif m.dropped then col = COL_DIM
      elseif P.gridscan and not m.matched then col = COL_DIM
      else col = COL_MARK end
      r.ImGui_DrawList_AddLine(dl, x, y0, x, y1, col, m.matched and 2 or 1)
      -- strength tick at the top
      r.ImGui_DrawList_AddRectFilled(dl, x - 2, y0, x + 2, y0 + 6 + m.strength * 18, col)
      -- quantize destination hint
      if m.matched and m.enabled and not m.dropped then
        local dx = tx(m.t + (m.matched - m.t) * P.qstr / 100)
        r.ImGui_DrawList_AddLine(dl, x, y0 + 10, dx, y0 + 10, 0xFFD24AB0, 1)
      end
    end
  end

  r.ImGui_DrawList_PopClipRect(dl)

  -- interaction: wheel = zoom, drag = pan, click near marker = toggle
  if r.ImGui_IsItemHovered(ctx) then
    local wheel = r.ImGui_GetMouseWheel(ctx)
    local mx = select(1, r.ImGui_GetMousePos(ctx))
    if wheel ~= 0 then
      local t_anchor = view_t0 + (mx - x0) / (x1 - x0) * span
      local factor = 1.25 ^ (-wheel)
      view_t0 = math.max(A.t0, t_anchor - (t_anchor - view_t0) * factor)
      view_t1 = math.min(A.t1, t_anchor + (view_t1 - t_anchor) * factor)
    end
  end
  if r.ImGui_IsItemActivated(ctx) then wave_dragged = 0 end
  if r.ImGui_IsItemActive(ctx) then
    local dx = select(1, r.ImGui_GetMouseDelta(ctx))
    if dx ~= 0 then
      wave_dragged = wave_dragged + abs(dx)
      local dt = -dx / (x1 - x0) * span
      dt = clamp(dt, A.t0 - view_t0, A.t1 - view_t1)
      view_t0, view_t1 = view_t0 + dt, view_t1 + dt
    end
  end
  if r.ImGui_IsItemDeactivated(ctx) and wave_dragged < 3 then
    local mx = select(1, r.ImGui_GetMousePos(ctx))
    local bestm, bd = nil, 6
    for _, m in ipairs(A.markers) do
      local d = abs(tx(m.t) - mx)
      if d < bd then bestm, bd = m, d end
    end
    if bestm then bestm.enabled = not bestm.enabled end
  end
end

local function frame()
  -- row 1: detection
  if r.ImGui_Button(ctx, A and 'Re-Analyze' or 'Analyze', 90, 0) then analyze() end
  r.ImGui_SameLine(ctx)
  sliderD('thresh', 'thresh', -60, 0, 'Thresh %.0f dB')
  r.ImGui_SameLine(ctx)
  sliderD('crest', 'crest', 1, 12, 'Crest %.1f dB')
  r.ImGui_SameLine(ctx)
  sliderD('retrig', 'retrig', 5, 200, 'Retrig %.0f ms')
  r.ImGui_SameLine(ctx)
  sliderD('attack', 'attack', 5, 60, 'Onset @ %.0f%% of peak')

  -- row 2: filters + strength filter
  r.ImGui_Text(ctx, 'Detect:') r.ImGui_SameLine(ctx)
  sliderD('hp', 'hp', 20, 2000, 'HP %.0f Hz', 120)
  r.ImGui_SameLine(ctx)
  sliderD('lp', 'lp', 500, 20000, 'LP %.0f Hz', 120)
  r.ImGui_SameLine(ctx)
  sliderD('gain', 'gain', -24, 24, 'Gain %.0f dB', 100)
  r.ImGui_SameLine(ctx)
  sliderD('sens', 'sens', 0, 90, 'Drop weakest %.0f%%', 140)

  -- row 3: grid
  toggle('GridScan', 'gridscan')
  r.ImGui_SameLine(ctx)
  sliderD('gridtol', 'gridtol', 10, 200, 'Tolerance %.0f ms', 130)
  r.ImGui_SameLine(ctx)
  toggle('Keep strongest (vs closest)', 'strongest')
  r.ImGui_SameLine(ctx)
  local _, division, swingmode, swingamt = r.GetSetProjectGrid(0, false)
  r.ImGui_TextColored(ctx, COL_TXT,
    ('grid: 1/%d%s'):format(math.floor(1 / math.max(division, 1e-9) + 0.5),
      swingmode == 1 and (' swing %d%%'):format(floor(swingamt * 100 + 0.5)) or ''))

  -- one matching pass per frame, shared by the panel and the status line
  local marks, lines
  if A then marks, lines = activeMarkers() end

  waveformPanel(lines)

  -- row 4: apply
  toggle('Warp mode (stretch markers, no cuts)', 'warp')
  r.ImGui_SameLine(ctx)
  sliderD('qstr', 'qstr', 0, 100, 'Strength %.0f%%', 120)
  if not P.warp then
    r.ImGui_SameLine(ctx)
    sliderD('pad', 'pad', 0, 50, 'Pad %.0f ms', 100)
    r.ImGui_SameLine(ctx)
    sliderD('xfade', 'xfade', 0, 50, 'XFade %.0f ms', 100)
  end
  r.ImGui_SameLine(ctx)
  if r.ImGui_Button(ctx, 'APPLY', 90, 0) then apply() end

  -- status
  r.ImGui_TextColored(ctx, COL_TXT,
    (A and ('%s  |  %d hits will be quantized.'):format(status, marks and #marks or 0) or status))
  if last_err then r.ImGui_TextColored(ctx, 0xE05353FF, last_err) end
end

local function loop()
  r.ImGui_SetNextWindowSize(ctx, 980, 430, r.ImGui_Cond_FirstUseEver())
  local visible, open = r.ImGui_Begin(ctx, 'PietosiQuantize###PQuant', true)
  if visible then
    local ok, err = pcall(frame)
    r.ImGui_End(ctx)
    if not ok then
      r.ShowConsoleMsg('PietosiQuantize error: ' .. tostring(err) .. '\n')
      open = false
    end
  end
  if open then r.defer(loop) else saveSettings() end
end

r.defer(loop)
