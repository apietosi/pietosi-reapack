-- @description PietosiRudiments 3 - Single Paradiddle
-- @version 1.0.0
-- @author pie
-- @provides [main=midi_editor] .
-- Numpad 3 suggestion: Single Paradiddle
-- Applies the "paradiddle" rudiment from PietosiRudiments_Core.lua
local sep = package.config:sub(1,1)
local dir = debug.getinfo(1, "S").source:match("@(.*"..sep..")")
local core = dofile(dir .. "PietosiRudiments_Core.lua")
core.apply("paradiddle")
