-- @description PietosiRudiments_Core - Shared rudiment-writing engine
-- @version 1.0.0
-- @author pie
-- @provides [nomain] .
-- =====================================================================
-- PietosiRudiments_Core.lua
-- Rudiment engine for REAPER MIDI editor.
-- You never run this file directly. The "Rudiment - *.lua" scripts
-- call into it. Edit the tables below to customize.
-- =====================================================================

local M = {}

-- ---------------------------------------------------------------
-- SETTINGS (safe to edit)
-- ---------------------------------------------------------------
M.SETTINGS = {
  default_pitch   = 38,   -- used when you only have a TIME selection (38 = snare in GM)
  vel_accent      = 120,  -- accented strokes
  vel_right       = 98,   -- normal right-hand stroke
  vel_left        = 87,   -- normal left-hand stroke (slightly softer = human)
  vel_grace       = 62,   -- flam/drag grace notes
  grace_qn        = 0.055,-- grace note offset in quarter notes (~28ms at 120bpm)
  note_gap        = 0.90, -- note length as a fraction of the grid step
  humanize_vel    = 4,    -- random +/- velocity added to every stroke (0 = off)
}

-- ---------------------------------------------------------------
-- RUDIMENT DEFINITIONS (safe to edit / add your own)
-- Each stroke: h = hand ("R"/"L"), a = accent (true), g = grace notes (1 = flam, 2 = drag)
-- The pattern repeats to fill your selection.
-- ---------------------------------------------------------------
M.RUDIMENTS = {

  single_stroke = { name = "Single Stroke Roll", strokes = {
    {h="R"}, {h="L"}, {h="R"}, {h="L"},
  }},

  double_stroke = { name = "Double Stroke Roll", strokes = {
    {h="R"}, {h="R"}, {h="L"}, {h="L"},
  }},

  paradiddle = { name = "Single Paradiddle", strokes = {
    {h="R", a=true}, {h="L"}, {h="R"}, {h="R"},
    {h="L", a=true}, {h="R"}, {h="L"}, {h="L"},
  }},

  double_paradiddle = { name = "Double Paradiddle", strokes = {
    {h="R", a=true}, {h="L"}, {h="R"}, {h="L"}, {h="R"}, {h="R"},
    {h="L", a=true}, {h="R"}, {h="L"}, {h="R"}, {h="L"}, {h="L"},
  }},

  paradiddle_diddle = { name = "Paradiddle-Diddle", strokes = {
    {h="R", a=true}, {h="L"}, {h="R"}, {h="R"}, {h="L"}, {h="L"},
  }},

  flam_tap = { name = "Flam Tap", strokes = {
    {h="R", a=true, g=1}, {h="R"},
    {h="L", a=true, g=1}, {h="L"},
  }},

  flamadiddle = { name = "Flamadiddle (Flam Paradiddle)", strokes = {
    {h="R", a=true, g=1}, {h="L"}, {h="R"}, {h="R"},
    {h="L", a=true, g=1}, {h="R"}, {h="L"}, {h="L"},
  }},

  drag_tap = { name = "Single Drag Tap", strokes = {
    {h="R", g=2}, {h="L", a=true},
    {h="L", g=2}, {h="R", a=true},
  }},

  flam_accent = { name = "Flam Accent", strokes = {
    {h="R", a=true, g=1}, {h="L"}, {h="R"},
    {h="L", a=true, g=1}, {h="R"}, {h="L"},
  }},
}

-- ---------------------------------------------------------------
-- ENGINE (no need to edit below here)
-- ---------------------------------------------------------------

local function msg(s)
  reaper.MB(s, "Pietosi Rudiments", 0)
end

-- Find the region + pitch to work on.
-- Priority 1: selected notes (uses their span + the pitch of the first one)
-- Priority 2: time selection (uses default_pitch)
local function get_target(take)
  local sel_idx, first = {}, nil
  local i = reaper.MIDI_EnumSelNotes(take, -1)
  local minppq, maxppq, pitch = math.huge, -math.huge, nil

  while i ~= -1 do
    local ok, _, _, sppq, eppq, _, p = reaper.MIDI_GetNote(take, i)
    if ok then
      sel_idx[#sel_idx + 1] = i
      if sppq < minppq then minppq = sppq end
      if eppq > maxppq then maxppq = eppq end
      if not pitch then pitch = p end
    end
    i = reaper.MIDI_EnumSelNotes(take, i)
  end

  if #sel_idx > 0 then
    return minppq, maxppq, pitch, "selected"
  end

  -- fall back to time selection
  local ts_start, ts_end = reaper.GetSet_LoopTimeRange(false, false, 0, 0, false)
  if ts_end > ts_start then
    local sppq = reaper.MIDI_GetPPQPosFromProjTime(take, ts_start)
    local eppq = reaper.MIDI_GetPPQPosFromProjTime(take, ts_end)
    return sppq, eppq, M.SETTINGS.default_pitch, "timesel"
  end

  return nil
end

-- Delete notes in the region: selected ones, or (time-sel mode) any note
-- of the target pitch inside the region.
local function clear_region(take, sppq, eppq, pitch, mode)
  local _, note_count = reaper.MIDI_CountEvts(take)
  for i = note_count - 1, 0, -1 do
    local ok, sel, _, nsppq, neppq, _, p = reaper.MIDI_GetNote(take, i)
    if ok then
      local kill = false
      if mode == "selected" then
        kill = sel
      else
        kill = (p == pitch) and (nsppq < eppq) and (neppq > sppq)
      end
      if kill then reaper.MIDI_DeleteNote(take, i) end
    end
  end
end

function M.apply(key)
  local rud = M.RUDIMENTS[key]
  if not rud then msg("Unknown rudiment: " .. tostring(key)) return end

  local editor = reaper.MIDIEditor_GetActive()
  if not editor then msg("Open a MIDI editor first.") return end
  local take = reaper.MIDIEditor_GetTake(editor)
  if not take then msg("No active MIDI take.") return end

  local sppq, eppq, pitch, mode = get_target(take)
  if not sppq then
    msg("Select some notes, or make a time selection first.")
    return
  end

  local S = M.SETTINGS
  local grid_qn = reaper.MIDI_GetGrid(take)      -- grid size in quarter notes
  if not grid_qn or grid_qn <= 0 then grid_qn = 0.25 end

  reaper.Undo_BeginBlock()
  reaper.MIDI_DisableSort(take)

  clear_region(take, sppq, eppq, pitch, mode)

  local start_qn = reaper.MIDI_GetProjQNFromPPQPos(take, sppq)
  local end_qn   = reaper.MIDI_GetProjQNFromPPQPos(take, eppq)

  local grace_off = math.min(S.grace_qn, grid_qn * 0.45)
  local strokes   = rud.strokes
  local n         = #strokes
  local step_i    = 0
  local qn        = start_qn

  math.randomseed(reaper.time_precise() * 1000)

  while qn < end_qn - 1e-9 do
    local st  = strokes[(step_i % n) + 1]
    local vel

    if st.a then vel = S.vel_accent
    elseif st.h == "L" then vel = S.vel_left
    else vel = S.vel_right end

    if S.humanize_vel > 0 then
      vel = vel + math.random(-S.humanize_vel, S.humanize_vel)
    end
    if vel > 127 then vel = 127 end
    if vel < 1 then vel = 1 end

    local note_s = reaper.MIDI_GetPPQPosFromProjQN(take, qn)
    local note_e = reaper.MIDI_GetPPQPosFromProjQN(take, qn + grid_qn * S.note_gap)

    -- grace notes (flam = 1, drag = 2), placed just before the main stroke
    local g = st.g or 0
    for gi = g, 1, -1 do
      local gqn = qn - grace_off * gi
      if gqn > start_qn - grace_off * 2.5 then
        local gs = reaper.MIDI_GetPPQPosFromProjQN(take, gqn)
        local ge = reaper.MIDI_GetPPQPosFromProjQN(take, gqn + grace_off * 0.8)
        reaper.MIDI_InsertNote(take, false, false, gs, ge, 0, pitch, S.vel_grace, true)
      end
    end

    reaper.MIDI_InsertNote(take, false, false, note_s, note_e, 0, pitch, vel, true)

    step_i = step_i + 1
    qn = qn + grid_qn
  end

  reaper.MIDI_Sort(take)
  reaper.Undo_EndBlock("Pietosi Rudiments: " .. rud.name, -1)
end

return M
