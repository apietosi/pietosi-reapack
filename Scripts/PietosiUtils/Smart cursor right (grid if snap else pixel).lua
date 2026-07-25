-- @description Smart cursor right (grid if snap else pixel)
-- @version 1.0.0
-- @author pie
-- @provides [main=main] .
-- Move edit cursor right: by grid division when snap is on, one pixel when snap is off
if reaper.GetToggleCommandState(1157) == 1 then -- Options: Toggle snapping
  reaper.Main_OnCommand(43615, 0) -- View: Move cursor right by grid division
else
  reaper.Main_OnCommand(40105, 0) -- View: Move cursor right one pixel
end
