-- @description PietosiRudiments 6 - Flam Tap
-- @version 1.0.0
-- @author pie
-- @provides [main=midi_editor] .
-- Numpad 6 suggestion: Flam Tap
-- Applies the "flam_tap" rudiment from PietosiRudiments_Core.lua
local sep = package.config:sub(1,1)
local dir = debug.getinfo(1, "S").source:match("@(.*"..sep..")")
local core = dofile(dir .. "PietosiRudiments_Core.lua")
core.apply("flam_tap")
