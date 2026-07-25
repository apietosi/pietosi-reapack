-- @description PietosiRudiments 8 - Single Drag Tap
-- @version 1.0.0
-- @author pie
-- @provides [main=midi_editor] .
-- Numpad 8 suggestion: Single Drag Tap
-- Applies the "drag_tap" rudiment from PietosiRudiments_Core.lua
local sep = package.config:sub(1,1)
local dir = debug.getinfo(1, "S").source:match("@(.*"..sep..")")
local core = dofile(dir .. "PietosiRudiments_Core.lua")
core.apply("drag_tap")
