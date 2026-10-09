-- @description PietosiStarry Setup - point the RS5k manager at the STARRYPAD in one go
-- @version 1.0.0
-- @author pie
-- @provides [main=main] .
-- @about
--   One click instead of a trip through the manager's settings:
--     - Rack layout -> Default 4x4 pads (the only layout the manager pages;
--       Custom never moves, so bank B/C pads were off-screen)
--     - MIDI bus default input -> the STARRYPAD, found by name
--     - The manager's own "active note follow incoming note" -> off, because
--       it rewrites the old page over ours; Follow selects the pad instead
--     - Selected kit: page set to bank A, MIDI bus input fixed if it points
--       at a specific device that is not the pad
--     - Starts PietosiStarry_Follow if it is not running
local r = reaper

local sep = package.config:sub(1, 1)
local root = ({ r.get_action_context() })[2]:match("^(.*" .. sep .. ")")
local L = dofile(root .. "PStarryLib.lua")
local C = L.Core

local TITLE = "PietosiStarry Setup"
local cfg = L.settings()

local dev, devName = L.findInput(cfg.device)
if not dev then
  r.MB("No MIDI input matching \"" .. cfg.device .. "\".\n\n"
    .. "Plug the STARRYPAD in and enable it for input in\n"
    .. "Preferences > MIDI Inputs, then run this again.", TITLE, 0)
  return
end

-- The manager holds its settings in memory and saves them over ExtState on
-- every change, so writing while it is open would be silently undone.
while L.managerOpen() do
  local ans = r.MB("The RS5k manager looks open.\n\n"
    .. "Close its window, then press Retry.\n"
    .. "(If it is already closed, press Ignore.)", TITLE, 2)
  if ans == 3 then return end -- Abort
  if ans == 5 then break end  -- Ignore: stale flag after a crash
end

local report = {}
local function say(s) report[#report + 1] = s end

r.SetExtState(L.MGR_ES, "UI_drracklayout", "0", true)
r.SetExtState(L.MGR_ES, "UI_incomingnoteselectpad", "0", true)
r.SetExtState(L.MGR_ES, "CONF_midiinput", tostring(dev), true)
say("Manager: 4x4 pad layout, new MIDI buses listen to " .. devName)

local parent = L.parentTrack()
if parent then
  r.Undo_BeginBlock2(0)
  local _, pname = r.GetTrackName(parent)
  L.setExt(parent, "MPLRS5KMAN_DRRACKSHIFT", cfg.base)
  say("Kit \"" .. pname .. "\": showing bank A (" .. cfg.base .. "-" .. (cfg.base + cfg.size - 1) .. ")")

  local bus = L.midiBus(parent)
  if bus then
    local cur = C.recInputDevice(r.GetMediaTrackInfo_Value(bus, "I_RECINPUT"))
    if cur == dev then
      say("MIDI bus already listens to the pad")
    elseif cur == C.ALL_INPUTS then
      say("MIDI bus left on All MIDI inputs (other controllers still play it)")
    else
      local was = cur and L.inputName(cur) or "no MIDI input"
      r.SetMediaTrackInfo_Value(bus, "I_RECINPUT", C.recInput(dev, 0))
      r.SetMediaTrackInfo_Value(bus, "I_RECARM", 1)
      r.SetMediaTrackInfo_Value(bus, "I_RECMON", 1)
      say("MIDI bus input: " .. was .. " -> " .. devName)
    end
  else
    say("Kit has no MIDI bus yet - add one from the manager and it will use the pad")
  end
  r.Undo_EndBlock2(0, "PietosiStarry: set up RS5k kit for STARRYPAD", -1)
else
  say("No kit selected - select an RS5k manager parent track to also fix its page and MIDI bus")
end

local follow = root .. "PietosiStarry_Follow.lua"
local followCmd = r.AddRemoveReaScript(true, 0, follow, true)
if followCmd ~= 0 then
  if r.GetToggleCommandState(followCmd) == 1 then
    say("Follow is already running")
  else
    r.Main_OnCommand(followCmd, 0)
    say("Follow started")
  end
end

r.MB(table.concat(report, "\n") .. "\n\nOpen the RS5k manager and hit a pad.", TITLE, 0)
