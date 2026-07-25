-- @description Smart cursor left (grid if snap else pixel)
-- @version 1.0.0
-- @author pie
-- @provides [main=main] .
-- Move edit cursor left: by grid division when snap is on, one pixel when snap is off
if reaper.GetToggleCommandState(1157) == 1 then -- Options: Toggle snapping
  reaper.Main_OnCommand(43614, 0) -- View: Move cursor left by grid division
else
  reaper.Main_OnCommand(40104, 0) -- View: Move cursor left one pixel
end
