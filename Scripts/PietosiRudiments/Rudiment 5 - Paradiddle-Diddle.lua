-- @description PietosiRudiments 5 - Paradiddle-Diddle
-- @version 1.0.0
-- @author pie
-- @provides [main=midi_editor] .
-- Numpad 5 suggestion: Paradiddle-Diddle
-- Applies the "paradiddle_diddle" rudiment from PietosiRudiments_Core.lua
local sep = package.config:sub(1,1)
local dir = debug.getinfo(1, "S").source:match("@(.*"..sep..")")
local core = dofile(dir .. "PietosiRudiments_Core.lua")
core.apply("paradiddle_diddle")
