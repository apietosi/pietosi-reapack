-- @description PietosiRudiments 1 - Single Stroke Roll
-- @version 1.0.0
-- @author pie
-- @provides [main=midi_editor] .
-- Numpad 1 suggestion: Single Stroke Roll
-- Applies the "single_stroke" rudiment from PietosiRudiments_Core.lua
local sep = package.config:sub(1,1)
local dir = debug.getinfo(1, "S").source:match("@(.*"..sep..")")
local core = dofile(dir .. "PietosiRudiments_Core.lua")
core.apply("single_stroke")
