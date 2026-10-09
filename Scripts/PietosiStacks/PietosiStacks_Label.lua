-- @description PietosiStacks_Label
-- @version 1.0.0
-- @author pie
-- @provides [main=main] .
-- Writes s1..sn onto the take names of every pool member, keeping any weight
-- tag the name already carries.
local r = reaper
local sep = package.config:sub(1, 1)
local root = ({ r.get_action_context() })[2]:match("^(.*" .. sep .. ")")
local L = dofile(root .. "PStacksLib.lua")
local C = L.Core

L.run("PietosiStacks: Label", function(items)
  L.eachTrackGroups(items, function(groups)
    for _, group in ipairs(groups) do
      if #group >= 2 and group.inScope then L.labelPool(group) end
    end
  end)
end)
