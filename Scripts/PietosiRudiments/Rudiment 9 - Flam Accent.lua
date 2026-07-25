-- @description PietosiRudiments 9 - Flam Accent
-- @version 1.0.0
-- @author pie
-- @provides [main=midi_editor] .
-- Numpad 9 suggestion: Flam Accent
-- Applies the "flam_accent" rudiment from PietosiRudiments_Core.lua
local sep = package.config:sub(1,1)
local dir = debug.getinfo(1, "S").source:match("@(.*"..sep..")")
local core = dofile(dir .. "PietosiRudiments_Core.lua")
core.apply("flam_accent")
