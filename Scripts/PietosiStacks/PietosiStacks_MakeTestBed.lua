-- @description PietosiStacks_MakeTestBed
-- @version 1.0.0
-- @author pie
-- @provides [main=main] .
-- Builds a known layout on a new track for checking the glue layer by hand.
-- Items have no media source, so they are silent blocks - this fixture proves
-- grouping, movement, muting and naming, not sound.
local r = reaper

-- { start, { length, ... } } - one entry per pool, lengths give pool size.
local LAYOUT = {
  { 0.0, { 0.30, 0.22, 0.28 } },              -- pool of three
  { 0.5, { 0.20, 0.18 } },                    -- pool of two
  { 1.0, { 0.90 } },                          -- lone slice with a long tail
  { 1.5, { 0.20, 0.20, 0.20, 0.20, 0.20 } },  -- pool of five
  { 2.0, { 0.25, 0.25 } },                    -- last pool on the track
}

r.PreventUIRefresh(1)
r.Undo_BeginBlock()

-- wantDefaults false: a throwaway fixture should not inherit your default
-- new-track FX chain, or you end up debugging a plugin instead of the script.
r.InsertTrackAtIndex(r.CountTracks(0), false)
local track = r.GetTrack(0, r.CountTracks(0) - 1)
r.GetSetMediaTrackInfo_String(track, "P_NAME", "PStacks test bed", true)

for p, entry in ipairs(LAYOUT) do
  local pos, lengths = entry[1], entry[2]
  for _, len in ipairs(lengths) do
    local item = r.AddMediaItemToTrack(track)
    r.SetMediaItemInfo_Value(item, "D_POSITION", pos)
    r.SetMediaItemInfo_Value(item, "D_LENGTH", len)
    local take = r.AddTakeToMediaItem(item)
    r.GetSetMediaItemTakeInfo_String(take, "P_NAME",
      string.format("pool%d", p), true)
  end
end

r.Undo_EndBlock("PietosiStacks: Make test bed", -1)
r.PreventUIRefresh(-1)
r.UpdateArrange()
