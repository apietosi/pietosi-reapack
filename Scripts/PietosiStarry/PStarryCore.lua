-- @description PStarryCore - pure logic for the PietosiStarry tools
-- @version 1.0.0
-- @author pie
-- @provides [nomain] .
-- No reaper API in this file. It must stay loadable by a stock lua binary.
local C = {}

-- Donner STARRYPAD factory map: bank A sends 36-51, B 52-67, C 68-83.
-- Both are overridable from ExtState (see PStarryLib.settings) in case the
-- pad has been re-mapped in Donner's editor.
C.BASE      = 36
C.BANK_SIZE = 16
C.DEVICE    = "starrypad"

-- RS5k manager's per-parent page offset is simply the first note on the
-- 4x4 grid, so a bank's first note is the page. Notes below the first bank
-- are not ours to follow and return nil rather than a negative page.
function C.pageFor(note, base, size)
  base, size = base or C.BASE, size or C.BANK_SIZE
  if type(note) ~= "number" or note < base or note > 127 or size < 1 then
    return nil
  end
  return base + size * math.floor((note - base) / size)
end

function C.bankName(page, base, size)
  base, size = base or C.BASE, size or C.BANK_SIZE
  local i = math.floor((page - base) / size)
  if i < 0 or i > 25 then return tostring(page) end
  return string.char(65 + i)
end

function C.nameMatches(name, pattern)
  if not name or not pattern or pattern == "" then return false end
  return name:lower():find(pattern:lower(), 1, true) ~= nil
end

-- I_RECINPUT for a MIDI hardware input. chan 0 means all channels.
function C.recInput(dev, chan)
  return 4096 + (chan or 0) + (dev << 5)
end

-- The "All MIDI inputs" device slot, which we leave alone so other
-- controllers keep playing the kit.
C.ALL_INPUTS = 63

function C.recInputDevice(recinput)
  if not recinput or recinput < 4096 then return nil end
  return (recinput >> 5) & 63
end

-- events: newest first, each { seq, msg, dev } as MIDI_GetRecentInputEvent
-- reports them. Returns the newest note-on from `dev` that is newer than
-- lastSeq, plus the newest seq seen so the caller never replays an event.
-- Note-on with velocity 0 is a note-off by the MIDI spec and is skipped.
function C.newestNoteOn(events, dev, lastSeq)
  lastSeq = lastSeq or 0
  local topSeq = lastSeq
  local note
  for _, e in ipairs(events) do
    if e.seq <= lastSeq then break end
    if e.seq > topSeq then topSeq = e.seq end
    local b1, b2, b3 = e.msg:byte(1, 3)
    local fromDev = (e.dev & 0xFFFF) == dev
    if not note and fromDev and b1 and (b1 >> 4) == 0x9 and (b3 or 0) > 0 then
      note = b2
    end
  end
  return note, topSeq
end

return C
