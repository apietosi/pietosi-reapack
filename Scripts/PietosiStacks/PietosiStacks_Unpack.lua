-- @description PietosiStacks_Unpack
-- @version 1.0.0
-- @author pie
-- @provides [main=main] .
-- Spreads each pool across its own slot so every slice sounds in order. Three
-- slices give triplets, five give quintuplets; the groove around them does not
-- move.
local r = reaper
local sep = package.config:sub(1, 1)
local root = ({ r.get_action_context() })[2]:match("^(.*" .. sep .. ")")
local L = dofile(root .. "PStacksLib.lua")
local C = L.Core

L.run("PietosiStacks: Unpack", function(items)
  -- Unconditionally, and before any grouping happens. Pool detection reads
  -- positions, so an already-spread pool no longer looks like a pool at all;
  -- and a pool that was Rolled but never Unpacked carries mutes that would
  -- otherwise make its burst inaudible.
  L.restore(items)

  L.eachTrackGroups(items, function(groups)
    -- groups covers the WHOLE track, so slotLength measures to the next real
    -- thing on it - an unselected slice between two pools still stops the burst.
    for gi, group in ipairs(groups) do
      if #group >= 2 and group.inScope then
        L.unpackPool(group, C.slotLength(groups, gi))
      end
    end
  end)
end)
