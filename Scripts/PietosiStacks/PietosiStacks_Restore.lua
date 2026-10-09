-- @description PietosiStacks_Restore
-- @version 1.0.0
-- @author pie
-- @provides [main=main] .
-- Un-mutes what Roll muted, moves anything Unpack shifted back home, and clears
-- all PietosiStacks state. Safe on items that were never touched.
local r = reaper
local sep = package.config:sub(1, 1)
local root = ({ r.get_action_context() })[2]:match("^(.*" .. sep .. ")")
local L = dofile(root .. "PStacksLib.lua")

L.run("PietosiStacks: Restore", function(items)
  L.restore(items)
end)
