-- @description __startup
-- Runs automatically when REAPER starts.

-- PietosiKeys background watchers:
--   ModeHUD   - flash the active key-mode (MIX/EDIT/REC/AUTO) on switch
--   ViewWatch - EDIT mode minimizes trackless lanes; restores on exit
for _, name in ipairs({ 'PietosiKeys_ModeHUD', 'PietosiKeys_ViewWatch' }) do
  local path = reaper.GetResourcePath() .. '/Scripts/PietosiKeys/' .. name .. '.lua'
  local f = io.open(path, 'rb')
  if f then
    f:close()
    local cmd = reaper.AddRemoveReaScript(true, 0, path, true)
    if cmd and cmd ~= 0 then reaper.Main_OnCommand(cmd, 0) end
  end
end

-- PietosiPad: Launchpad MK1 control surface for the PietosiKeys modes
do
  local path = reaper.GetResourcePath() .. '/Scripts/PietosiPad/PietosiPad.lua'
  local f = io.open(path, 'rb')
  if f then
    f:close()
    local cmd = reaper.AddRemoveReaScript(true, 0, path, true)
    if cmd and cmd ~= 0 then reaper.Main_OnCommand(cmd, 0) end
  end
end
