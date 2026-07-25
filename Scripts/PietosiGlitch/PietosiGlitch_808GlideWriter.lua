-- @description PietosiGlitch 808GlideWriter - turn selected notes into one gliding 808
-- @version 1.0.0
-- @author pie
-- @provides [main=midi_editor] .
-- @about MIDI editor script. Select a run of 808 notes: the first note is
--   extended across the whole phrase, the others are removed, and pitch-bend
--   ramps glide to each subsequent pitch. Set BEND_RANGE to match your
--   sampler/synth's pitch bend range (semitones)!
local r = reaper

local BEND_RANGE = 24  -- must match the instrument's bend range
local GLIDE = 0.35     -- fraction of each gap used for the glide ramp
local STEPS = 12       -- bend events per glide

local ed = r.MIDIEditor_GetActive()
local take = ed and r.MIDIEditor_GetTake(ed)
if not take then return end

local _, ncnt = r.MIDI_CountEvts(take)
local notes = {}
for i = 0, ncnt - 1 do
  local _, sel, _, sppq, eppq, chan, pitch, vel = r.MIDI_GetNote(take, i)
  if sel then
    notes[#notes + 1] = { idx = i, s = sppq, e = eppq, pitch = pitch, vel = vel, chan = chan }
  end
end
if #notes < 2 then
  r.MB('Select at least two notes (the 808 phrase to glide through).', '808GlideWriter', 0)
  return
end
table.sort(notes, function(a, b) return a.s < b.s end)

local base = notes[1].pitch
local chan = notes[1].chan

local function bendVal(semis)
  local v = math.floor(8192 + semis / BEND_RANGE * 8191 + 0.5)
  if v < 0 then v = 0 elseif v > 16383 then v = 16383 end
  return v & 127, (v >> 7) & 127
end

r.Undo_BeginBlock2(0)
r.MIDI_DisableSort(take)

-- extend the first note across the phrase
r.MIDI_SetNote(take, notes[1].idx, nil, nil, notes[1].s, notes[#notes].e, nil, nil, nil, true)

-- remove the rest (descending index)
for i = #notes, 2, -1 do
  r.MIDI_DeleteNote(take, notes[i].idx)
end

-- bend: center at phrase start, ramp into each subsequent pitch
local lsb, msb = bendVal(0)
r.MIDI_InsertCC(take, false, false, notes[1].s, 224, chan, lsb, msb)
local prev = 0
for i = 2, #notes do
  local target = notes[i].pitch - base
  local gap = notes[i].s - notes[i - 1].s
  local ramp0 = notes[i].s - math.floor(gap * GLIDE)
  for s = 1, STEPS do
    local f = s / STEPS
    local semis = prev + (target - prev) * f
    local ppq = math.floor(ramp0 + gap * GLIDE * f - 1)
    lsb, msb = bendVal(semis)
    r.MIDI_InsertCC(take, false, false, ppq, 224, chan, lsb, msb)
  end
  prev = target
end

r.MIDI_Sort(take)
r.Undo_EndBlock2(0, '808GlideWriter: glide through ' .. #notes .. ' notes', -1)
