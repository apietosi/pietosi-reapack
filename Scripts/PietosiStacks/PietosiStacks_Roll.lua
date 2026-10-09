-- @description PietosiStacks_Roll
-- @version 1.0.0
-- @author pie
-- @provides [main=main] .
-- Picks one slice per pool by weight and mutes the rest. Nothing is moved or
-- destroyed, so this is repeatable indefinitely.
local r = reaper
local sep = package.config:sub(1, 1)
local root = ({ r.get_action_context() })[2]:match("^(.*" .. sep .. ")")
local L = dofile(root .. "PStacksLib.lua")

L.run("PietosiStacks: Roll", function(items)
  L.eachTrackGroups(items, function(groups)
    for _, group in ipairs(groups) do
      if #group >= 2 and group.inScope then L.rollPool(group) end
    end
  end)
end)
