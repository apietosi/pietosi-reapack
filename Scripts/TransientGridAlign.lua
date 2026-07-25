-- @description TransientGridAlign - Align transients to the grid
-- @version 1.0.0
-- @author pie
-- @provides [main=main] .
--[[
  TransientGridAlign.lua
  --------------------------------------------------------------------------
  Smarter "split to grid" for selected audio items.

  Instead of slicing every transient and snapping each slice on its own
  (REAPER's stock Dynamic Split -> Quantize, which shreds groove and makes
  gaps everywhere), this:

    1. Reads every transient in the item using REAPER's own transient
       detector (so your Transient Detection Settings drive sensitivity).
    2. Measures how far each transient sits from its nearest grid line.
    3. Works out the DOMINANT drift (e.g. "the whole take is ~12 ms early")
       and slides the entire item by that amount in ONE move.
    4. Only the hits still off-grid after that global shift get sliced and
       nudged onto the grid. Tight hits are left exactly as played.

  ReaScript can't return a transient list directly, so step 1 steps the edit
  cursor through the item with the "move to next transient" action and reads
  each position. Tune detection in Options > Transient Detection Settings.

  USAGE
    - Select one or more audio items.
    - Run this script (Actions > load/run, or bind a key).
    - Undo is a single step.

  Tweak the CONFIG block below to taste.
--------------------------------------------------------------------------]]

-------------------------- CONFIG ----------------------------------------
local MODE          = "hybrid"  -- "hybrid"  : global drift shift + nudge only outliers (recommended)
                                -- "global"  : detect drift, slide whole item, NO slicing at all
                                -- "perslice": slice every transient and snap each one (hard quantize)

local GRID_QN       = 0         -- grid spacing in QUARTER notes. 0 = use current project grid.
                                --   1.0 = 1/4 notes, 0.5 = 1/8, 0.25 = 1/16, 0.75 = dotted 1/8,
                                --   2/3 = 1/4 triplets, 4.0 = one per bar (downbeats / "strong beats").

local TOLERANCE_MS  = 15        -- hybrid: hits within this of the grid (after the global shift)
                                -- are left untouched. Bigger = more groove kept.

local STRENGTH      = 1.0       -- how far a corrected hit moves toward the grid. 1.0 = full snap,
                                -- 0.6 = 60% (keeps some human push/pull).

local MAX_DRIFT_MS  = 50        -- clamp on the global shift so a weird detection can't fling the
                                -- item miles. 0 = no clamp.

local PRE_SLICE_MS  = 5         -- cut this far BEFORE each transient so there's room for a fade-in
                                -- (avoids clicks). The cut's snap offset still points at the transient.

local FADE_MS       = 4         -- crossfade length placed on each cut to mask it.

local MIN_SLICE_MS  = 20        -- ignore transients closer together than this (avoids micro-slices).
--------------------------------------------------------------------------

local PROJ          = 0
local PRE_SLICE_SEC = PRE_SLICE_MS / 1000
local FADE_SEC      = FADE_MS / 1000
local MIN_SLICE_SEC = MIN_SLICE_MS / 1000
local TOL_SEC       = TOLERANCE_MS / 1000

-------------------------- helpers ---------------------------------------

local function median(t)
  if #t == 0 then return 0 end
  local c = {}
  for i = 1, #t do c[i] = t[i] end
  table.sort(c)
  local m = math.floor(#c / 2)
  if #c % 2 == 1 then return c[m + 1] else return (c[m] + c[m + 1]) / 2 end
end

-- nearest grid line (in seconds) to a given time, via the tempo map so it
-- stays correct across tempo changes.
local function nearestGrid(time)
  local qn = reaper.TimeMap2_timeToQN(PROJ, time)
  local gridQN = GRID_QN
  if gridQN <= 0 then
    -- GetSetProjectGrid division: 0.25 = quarter note, so *4 -> quarter notes per step.
    local _, division = reaper.GetSetProjectGrid(PROJ, false)
    gridQN = division * 4
  end
  if gridQN <= 0 then gridQN = 1 end
  local snappedQN = math.floor(qn / gridQN + 0.5) * gridQN
  return reaper.TimeMap2_QNToTime(PROJ, snappedQN)
end

-- Step REAPER's transient detector through one item and collect positions.
-- Caller is responsible for restoring item selection / cursor afterwards.
local function detectTransients(item)
  local pos  = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
  local len  = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
  local iEnd = pos + len

  reaper.SelectAllMediaItems(PROJ, false)
  reaper.SetMediaItemSelected(item, true)
  reaper.SetEditCurPos(pos, false, false)

  local trans = {}
  local prev  = pos - 1
  local guard = 0
  while guard < 100000 do
    guard = guard + 1
    reaper.Main_OnCommand(40375, 0)            -- Item navigation: move cursor to next transient
    local cur = reaper.GetCursorPosition()
    if cur <= prev + 1e-9 then break end       -- cursor stopped advancing -> done
    if cur >= iEnd - 1e-6 then break end        -- ran past the item
    if cur > pos + 1e-6 then trans[#trans + 1] = cur end
    prev = cur
  end
  return trans
end

-------------------------- per-item work ---------------------------------

local function processItem(item)
  local trans = detectTransients(item)
  if #trans == 0 then return false end

  -- 1) deviation of each transient from its grid line (signed; negative = early)
  local dev = {}
  for i = 1, #trans do dev[i] = trans[i] - nearestGrid(trans[i]) end

  -- 2) dominant drift = median deviation (robust against stray ghost hits)
  local drift = 0
  if MODE == "global" or MODE == "hybrid" then drift = median(dev) end
  if MAX_DRIFT_MS > 0 then
    local cap = MAX_DRIFT_MS / 1000
    if drift >  cap then drift =  cap end
    if drift < -cap then drift = -cap end
  end

  -- 3) one move: slide the whole item to cancel the drift
  local shift = -drift
  if shift ~= 0 then
    local p = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
    reaper.SetMediaItemInfo_Value(item, "D_POSITION", p + shift)
    for i = 1, #trans do trans[i] = trans[i] + shift end
  end

  if MODE == "global" then return true end

  -- 4) slice each transient (cut a hair before it, snap-offset back to the hit)
  local workItem = item
  local slices   = {}
  for i = 1, #trans do
    local cut  = trans[i] - PRE_SLICE_SEC
    local wpos = reaper.GetMediaItemInfo_Value(workItem, "D_POSITION")
    if cut > wpos + MIN_SLICE_SEC then
      local right = reaper.SplitMediaItem(workItem, cut)
      if right then
        reaper.SetMediaItemInfo_Value(right,   "D_SNAPOFFSET", trans[i] - cut)
        reaper.SetMediaItemInfo_Value(right,   "D_FADEINLEN",  math.min(PRE_SLICE_SEC, FADE_SEC))
        reaper.SetMediaItemInfo_Value(workItem, "D_FADEOUTLEN", FADE_SEC)
        slices[#slices + 1] = { it = right, tr = trans[i] }
        workItem = right
      end
    end
  end

  -- 5) align: hybrid moves only the hits still outside TOLERANCE; perslice moves all
  for _, s in ipairs(slices) do
    local residual = s.tr - nearestGrid(s.tr)
    local move = (MODE == "perslice") or (math.abs(residual) > TOL_SEC)
    if move then
      local pos = reaper.GetMediaItemInfo_Value(s.it, "D_POSITION")
      reaper.SetMediaItemInfo_Value(s.it, "D_POSITION", pos - STRENGTH * residual)
    end
  end
  return true
end

-------------------------- main ------------------------------------------

local function main()
  local n = reaper.CountSelectedMediaItems(PROJ)
  if n == 0 then
    reaper.MB("Select one or more audio items first.", "TransientGridAlign", 0)
    return
  end

  local items = {}
  for i = 0, n - 1 do items[i + 1] = reaper.GetSelectedMediaItem(PROJ, i) end
  local curPos = reaper.GetCursorPosition()

  reaper.Undo_BeginBlock()
  reaper.PreventUIRefresh(1)

  local touched = 0
  for _, item in ipairs(items) do
    if reaper.ValidatePtr(item, "MediaItem*") then
      if processItem(item) then touched = touched + 1 end
    end
  end

  -- restore the original item selection + cursor
  reaper.SelectAllMediaItems(PROJ, false)
  for _, item in ipairs(items) do
    if reaper.ValidatePtr(item, "MediaItem*") then reaper.SetMediaItemSelected(item, true) end
  end
  reaper.SetEditCurPos(curPos, false, false)

  reaper.PreventUIRefresh(-1)
  reaper.UpdateArrange()
  reaper.Undo_EndBlock("Transient grid align (" .. MODE .. ")", -1)
end

main()
