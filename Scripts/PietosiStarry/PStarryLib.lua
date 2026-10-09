-- @description PStarryLib - REAPER glue for the PietosiStarry tools
-- @version 1.0.0
-- @author pie
-- @provides [nomain] .
local r = reaper
local L = {}

local sep = package.config:sub(1, 1)
local root = ({ r.get_action_context() })[2]:match("^(.*" .. sep .. ")")

L.Core = dofile(root .. "PStarryCore.lua")
L.ROOT = root

L.ES = "PietosiStarry"
L.MGR_ES = "MPL_RS5K manager"

-- Overrides live in ExtState so a re-mapped pad needs no code edit:
--   [PietosiStarry] base=36  bank_size=16  device=starrypad  follow_note=1
function L.settings()
  local function num(key, default)
    return tonumber(r.GetExtState(L.ES, key)) or default
  end
  local dev = r.GetExtState(L.ES, "device")
  return {
    base       = num("base", L.Core.BASE),
    size       = num("bank_size", L.Core.BANK_SIZE),
    device     = dev ~= "" and dev or L.Core.DEVICE,
    followNote = num("follow_note", 1) == 1,
  }
end

-- Resolved by name every time: REAPER's input slots move when devices are
-- plugged into different ports, which is what left the manager pointing at
-- a stale index.
function L.findInput(pattern)
  for i = 0, r.GetNumMIDIInputs() - 1 do
    local ok, name = r.GetMIDIInputName(i, "")
    if ok and L.Core.nameMatches(name, pattern) then
      -- CoreMIDI reports an empty manufacturer as "  - STARRYPAD".
      return i, (name:gsub("^[%s%-]+", ""))
    end
  end
end

function L.inputName(dev)
  if dev == L.Core.ALL_INPUTS then return "All MIDI inputs" end
  local ok, name = r.GetMIDIInputName(dev, "")
  return ok and name or ("input " .. dev)
end

local function ext(tr, key)
  local _, v = r.GetSetMediaTrackInfo_String(tr, "P_EXT:" .. key, "", false)
  return v
end
L.ext = ext

local function trackByGUID(guid)
  if not guid or guid == "" then return end
  for i = 0, r.CountTracks(0) - 1 do
    local tr = r.GetTrack(0, i)
    if r.GetTrackGUID(tr) == guid then return tr end
  end
end

-- Same resolution the manager uses (CollectData_Parent): a stuck parent from
-- project ExtState, else the selected track, and a selected child hands over
-- to its parent. Only tracks the manager has already stamped count, so a
-- random selected audio track is never written to.
function L.parentTrack()
  local _, stuck = r.GetProjExtState(0, "MPLRS5KMAN", "STICKPARENTGUID")
  local tr = trackByGUID(stuck) or r.GetSelectedTrack(0, 0)
  if not tr then return end

  local owner = trackByGUID(ext(tr, "MPLRS5KMAN_CHILD_PARENTGUID"))
  if owner then tr = owner end

  if ext(tr, "MPLRS5KMAN_VERSION") == "" and ext(tr, "MPLRS5KMAN_GUIDINTERNAL") == "" then
    return
  end
  return tr
end

function L.midiBus(parent)
  local guid = r.GetTrackGUID(parent)
  local first = r.GetMediaTrackInfo_Value(parent, "IP_TRACKNUMBER")
  if r.GetMediaTrackInfo_Value(parent, "I_FOLDERDEPTH") ~= 1 then return end
  local depth = 1
  for i = first, r.CountTracks(0) - 1 do
    local tr = r.GetTrack(0, i)
    if ext(tr, "MPLRS5KMAN_MIDIBUS") == "1"
      and ext(tr, "MPLRS5KMAN_CHILD_PARENTGUID") == guid then
      return tr
    end
    depth = depth + r.GetMediaTrackInfo_Value(tr, "I_FOLDERDEPTH")
    if depth <= 0 then return end
  end
end

-- Writes only on change, so an idle pad never dirties the project.
function L.setExt(tr, key, value)
  value = tostring(value)
  if ext(tr, key) == value then return false end
  r.GetSetMediaTrackInfo_String(tr, "P_EXT:" .. key, value, true)
  return true
end

-- The manager writes 1 to slot 1026 on open and 0 on close. A crash can leave
-- it stale at 1 until REAPER restarts, so treat this as a hint, not a lock.
-- Read-only: these scripts never write into the manager's namespace.
function L.managerOpen()
  r.gmem_attach("RS5K_manager")
  return r.gmem_read(1026) ~= 0
end

return L
