-- @description PietosiStarry Follow - RS5k manager pad page follows the STARRYPAD bank
-- @version 1.0.0
-- @author pie
-- @provides [main=main] .
-- @about
--   Background watcher. Hit any pad on the Donner STARRYPAD and the RS5k
--   manager flips to that pad's bank (A = 36-51, B = 52-67, ...) and selects
--   the pad. Toggle action; auto-started from __startup.lua.
--
--   The manager only re-reads its track data when the project state count,
--   the edit cursor, or the active project changes. Writing track P_EXT does
--   none of those, so after a write the edit cursor is nudged by a microsecond
--   and put back once the pads go quiet. That is invisible and, unlike an
--   undo point, never lands in the undo history.
local r = reaper

local sep = package.config:sub(1, 1)
local root = ({ r.get_action_context() })[2]:match("^(.*" .. sep .. ")")
local L = dofile(root .. "PStarryLib.lua")
local C = L.Core

local NUDGE       = 1e-6  -- seconds; far below one sample
local SETTLE      = 0.20  -- put the cursor back after this much pad silence
local REASSERT    = 0.50  -- keep the page pinned this long after a bank change
local RESCAN      = 2.0   -- look for the pad again (hot-plug) this often
local MAX_EVENTS  = 64

local _, _, section, cmd = r.get_action_context()
if r.set_action_options then r.set_action_options(1) end -- re-run stops it
r.SetToggleCommandState(section, cmd, 1)
r.RefreshToolbar2(section, cmd)

local cfg = L.settings()
local dev, lastScan = nil, -math.huge
local lastSeq -- nil until primed, so old buffered hits are never replayed
local want    -- { page, note, until_t }
local nudge   -- { home, flip, at }

local function readEvents()
  local out = {}
  for i = 0, MAX_EVENTS - 1 do
    local seq, msg, _, devIdx = r.MIDI_GetRecentInputEvent(i)
    if not seq or seq == 0 then break end
    out[#out + 1] = { seq = seq, msg = msg, dev = devIdx }
  end
  return out
end

local function kickManager()
  if not L.managerOpen() then return end
  local now = r.time_precise()
  if not nudge then
    nudge = { home = r.GetCursorPosition(), flip = false }
  end
  nudge.flip = not nudge.flip
  r.SetEditCurPos(nudge.home + (nudge.flip and NUDGE or 2 * NUDGE), false, false)
  nudge.at = now
end

local function settleCursor(force)
  if not nudge then return end
  if not force and r.time_precise() - nudge.at < SETTLE then return end
  local pos = r.GetCursorPosition()
  -- Only undo our own nudge. If the cursor was moved by hand meanwhile it is
  -- further than two nudges away, and it stays where it was put.
  if math.abs(pos - nudge.home) <= 3 * NUDGE then
    r.SetEditCurPos(nudge.home, false, false)
  end
  nudge = nil
end

local function apply()
  local parent = L.parentTrack()
  if not parent then return end
  local changed = L.setExt(parent, "MPLRS5KMAN_DRRACKSHIFT", want.page)
  if cfg.followNote then
    changed = L.setExt(parent, "MPLRS5KMAN_LASTACTIVENOTE", want.note) or changed
  end
  if changed then kickManager() end
end

local function loop()
  local now = r.time_precise()

  -- Rescan even while found: an unplug/replug can land on another slot.
  if now - lastScan >= RESCAN then
    cfg = L.settings()
    dev = L.findInput(cfg.device)
    lastScan = now
  end

  if dev then
    local events = readEvents()
    if not lastSeq then
      -- Prime: remember where the buffer is without acting on it.
      lastSeq = events[1] and events[1].seq or 0
    else
      local note
      note, lastSeq = C.newestNoteOn(events, dev, lastSeq)
      local page = note and C.pageFor(note, cfg.base, cfg.size)
      if page then
        local newBank = not want or want.page ~= page
        want = {
          page = page,
          note = note,
          until_t = newBank and now + REASSERT or want.until_t,
        }
        apply()
      elseif want and now < want.until_t then
        -- Something else (the manager's own note-follow, a stale write)
        -- can put the old page back right after a bank change.
        apply()
      end
    end
  end

  settleCursor(false)
  r.defer(loop)
end

r.atexit(function()
  settleCursor(true)
  r.SetToggleCommandState(section, cmd, 0)
  r.RefreshToolbar2(section, cmd)
end)

loop()
