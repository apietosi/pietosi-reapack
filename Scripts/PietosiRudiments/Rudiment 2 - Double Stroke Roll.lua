-- @description PietosiRudiments 2 - Double Stroke Roll
-- @version 1.0.0
-- @author pie
-- @provides [main=midi_editor] .
-- Numpad 2 suggestion: Double Stroke Roll
-- Applies the "double_stroke" rudiment from PietosiRudiments_Core.lua
local sep = package.config:sub(1,1)
local dir = debug.getinfo(1, "S").source:match("@(.*"..sep..")")
local core = dofile(dir .. "PietosiRudiments_Core.lua")
core.apply("double_stroke")
