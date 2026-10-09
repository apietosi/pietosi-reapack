-- @description StackLab
-- @version 1.0.0
-- @author pie
-- @provides [main=main] .
-- Performance surface for PietosiStacks: stop, roll, replay. Scoped to the
-- time selection on the selected tracks.
local r = reaper

if not r.ImGui_CreateContext then
  r.MB('StackLab needs the ReaImGui extension.\n\nInstall via ReaPack: Extensions > ReaPack > Browse packages > "ReaImGui".', 'StackLab', 0)
  return
end

local sep = package.config:sub(1, 1)
local root = ({ r.get_action_context() })[2]:match("^(.*" .. sep .. ")")
local L = dofile(root .. "PStacksLib.lua")
local C = L.Core

local ctx = r.ImGui_CreateContext('StackLab')

local state = {
  sig      = nil,
  pools    = {},
  loopA    = 0,
  loopB    = 0,
  hasLoop  = false,
  isLoop   = false,
  rollable = 0,
  trackLbl = "",
  nsel     = 0,
}

-- The range the panel works on: your time selection when you have one,
-- otherwise whatever is visible in the arrange view. Requiring a loop meant a
-- panel that sat there doing nothing until you made one, with no hint that was
-- why - and the visible range is almost always the range you are looking at
-- anyway. Returns the range plus whether it came from a real time selection.
local function workingRange()
  local a, b = r.GetSet_LoopTimeRange(false, false, 0, 0, false)
  if b > a then return a, b, true end
  local va, vb = r.GetSet_ArrangeView2(0, false, 0, 0)
  return va, vb, false
end

-- Everything the display depends on, in one cheap string. Rebuilding the pool
-- list walks every item on every selected track, so it only happens when one of
-- these actually moves. The project change counter is what keeps the panel
-- honest: it ticks on every roll, every manual edit and every undo, so the
-- display cannot show a stale winner after something changes behind its back.
local function signature()
  local a, b = workingRange()
  local parts = {
    string.format("%.9f|%.9f", a, b),
    tostring(r.GetProjectStateChangeCount(0)),
  }
  for t = 0, r.CountSelectedTracks(0) - 1 do
    parts[#parts + 1] = tostring(r.GetSelectedTrack(0, t))
  end
  return table.concat(parts, ";"), a, b
end

local function selectedTrackItems()
  local items = {}
  for t = 0, r.CountSelectedTracks(0) - 1 do
    local tr = r.GetSelectedTrack(0, t)
    for i = 0, r.CountTrackMediaItems(tr) - 1 do
      items[#items + 1] = r.GetTrackMediaItem(tr, i)
    end
  end
  return items
end

-- Items whose START falls inside the loop. Used by the panel's Restore and as
-- the pre-pass for its Unpack, both of which act per item rather than per pool.
local function loopItems()
  local out = {}
  for _, item in ipairs(selectedTrackItems()) do
    local pos = r.GetMediaItemInfo_Value(item, "D_POSITION")
    if pos >= state.loopA and pos < state.loopB then out[#out + 1] = item end
  end
  return out
end

local function describeTracks(nsel)
  if nsel == 0 then return "" end
  if nsel > 1 then return nsel .. " tracks" end
  local ok, nm = r.GetSetMediaTrackInfo_String(
    r.GetSelectedTrack(0, 0), "P_NAME", "", false)
  if ok and nm ~= "" then return nm end
  return "track"
end

local function scan()
  local sig = signature()
  local a, b, isLoop = workingRange()
  local nsel = r.CountSelectedTracks(0)
  local pools = {}

  state.loopA, state.loopB = a, b
  state.hasLoop = b > a
  state.isLoop = isLoop
  state.nsel = nsel
  state.trackLbl = describeTracks(nsel)

  if state.hasLoop and nsel > 0 then
    -- Group over every item on the track, then keep the pools that reach into
    -- the loop. Grouping the loop's items alone would treat a stack straddling
    -- the loop edge as a partial pool.
    L.eachTrackGroups(selectedTrackItems(), function(groups)
      for gi, group in ipairs(groups) do
        if C.poolInRange(group, a, b) then
          pools[#pools + 1] = {
            group  = group,
            groups = groups,
            gi     = gi,
            pos    = group[1].pos,
            count  = #group,
          }
        end
      end
    end)
  end

  table.sort(pools, function(x, y) return x.pos < y.pos end)

  local num = 0
  for _, p in ipairs(pools) do
    p.label = r.format_timestr_pos(p.pos, "", 2)
    if p.count >= 2 then
      num = num + 1
      if num <= 9 then p.num = num end

      local w = C.poolWinner(p.group)
      if w then
        local _, idx = C.parseName(p.group[w].name)
        -- Name the sounding slice by its label when it has one, since that is
        -- what shows on the item. An unlabelled pool has no such name, so fall
        -- back to a position rather than printing a bare index that looks like
        -- a label but is not.
        p.winner = idx and ("playing s" .. idx)
                       or ("playing " .. w .. " of " .. p.count)
      else
        p.winner = "—"
      end
    end
  end

  state.rollable = num
  state.sig, state.pools = sig, pools
end

local function rollAll()
  if #state.pools == 0 then return end
  L.runScoped("StackLab: Roll loop", function()
    for _, p in ipairs(state.pools) do
      if p.count >= 2 then L.rollPool(p.group) end
    end
  end)
  scan()
end

local function rollOne(p)
  if p.count < 2 then return end
  L.runScoped("StackLab: Roll pool at " .. p.label, function()
    L.rollPool(p.group)
  end)
  scan()
end

local function rollNumbered(n)
  for _, p in ipairs(state.pools) do
    if p.num == n then rollOne(p) return end
  end
end

local function restoreLoop()
  if not state.hasLoop or state.nsel == 0 then return end
  L.runScoped("StackLab: Restore loop", function()
    L.restore(loopItems())
  end)
  scan()
end

local function unpackLoop()
  if not state.hasLoop or state.nsel == 0 then return end
  local a, b = state.loopA, state.loopB
  L.runScoped("StackLab: Unpack loop", function()
    -- Restore the loop's items before grouping: an already-spread pool no
    -- longer shares a start, so it would not be recognised as a pool at all.
    -- Only the loop's items, so unpacks elsewhere on the track survive.
    -- Neighbouring pools outside the loop keep their first member at its
    -- original start even when spread, so slot measurement is unaffected.
    L.restore(loopItems())

    L.eachTrackGroups(selectedTrackItems(), function(groups)
      for gi, group in ipairs(groups) do
        if #group >= 2 and C.poolInRange(group, a, b) then
          L.unpackPool(group, C.slotLength(groups, gi))
        end
      end
    end)
  end)
  scan()
end

local function labelRange()
  if state.rollable == 0 then return end
  L.runScoped("StackLab: Label", function()
    for _, p in ipairs(state.pools) do
      if p.count >= 2 then L.labelPool(p.group) end
    end
  end)
  scan()
end

local CELL_W, CELL_H = 104, 62

local function draw()
  if state.nsel == 0 then
    r.ImGui_Text(ctx, "Select a track.")
    return
  end

  local scopeWord = state.isLoop and "loop" or "view"
  r.ImGui_Text(ctx, string.format("%s  ·  %s  ·  %s – %s",
    state.trackLbl,
    state.isLoop and "time selection" or "visible arrange view",
    r.format_timestr_pos(state.loopA, "", 2),
    r.format_timestr_pos(state.loopB, "", 2)))

  -- Say plainly when there is nothing to act on, and disable the controls. The
  -- first version drew a big inviting button that silently did nothing when the
  -- range held no pools, which reads as a broken panel rather than an empty one.
  if state.rollable == 0 then
    if #state.pools == 0 then
      r.ImGui_Text(ctx, "No items here. Scroll to some, or make a time selection.")
    else
      r.ImGui_Text(ctx, string.format(
        "%d items here, but no piles - nothing is stacked to choose between.",
        #state.pools))
    end
  else
    r.ImGui_Text(ctx, string.format("%d piles, %d rollable",
      #state.pools, state.rollable))
  end

  r.ImGui_Spacing(ctx)

  r.ImGui_BeginDisabled(ctx, state.rollable == 0)
  local avail = r.ImGui_GetContentRegionAvail(ctx)
  if r.ImGui_Button(ctx, "roll the " .. scopeWord .. "   (R)", avail, 48) then
    rollAll()
  end
  r.ImGui_EndDisabled(ctx)

  r.ImGui_Spacing(ctx)

  for i, p in ipairs(state.pools) do
    if i > 1 then r.ImGui_SameLine(ctx) end

    if p.count < 2 then
      -- Lone slices are drawn in place so the row still reads as a timeline
      -- rather than a gapless strip of only-the-rollable. They are inert.
      r.ImGui_BeginDisabled(ctx, true)
      r.ImGui_Button(ctx, p.label .. "\n1 slice\nnothing to roll", CELL_W, CELL_H)
      r.ImGui_EndDisabled(ctx)
    else
      local key = p.num and ("  (" .. p.num .. ")") or ""
      local caption = string.format("%s%s\n%d slices\n%s",
        p.label, key, p.count, p.winner)
      if r.ImGui_Button(ctx, caption .. "##" .. i, CELL_W, CELL_H) then
        rollOne(p)
      end
    end
  end

  r.ImGui_Spacing(ctx)
  r.ImGui_BeginDisabled(ctx, state.rollable == 0)
  if r.ImGui_Button(ctx, "label", 110, 32) then labelRange() end
  r.ImGui_SameLine(ctx)
  if r.ImGui_Button(ctx, "unpack", 110, 32) then unpackLoop() end
  r.ImGui_SameLine(ctx)
  if r.ImGui_Button(ctx, "restore", 110, 32) then restoreLoop() end
  r.ImGui_EndDisabled(ctx)
end

local function pressed(key)
  return r.ImGui_IsKeyPressed(ctx, key, false)
end

local function keys()
  -- Space must reach the transport. A ReaImGui window takes keyboard focus
  -- while it is in front, so without this forward, play/stop stops working the
  -- moment the panel is focused - and stop-edit-replay dies on its second step.
  if pressed(r.ImGui_Key_Space()) then r.Main_OnCommand(40044, 0) end
  if pressed(r.ImGui_Key_R()) then rollAll() end

  for n = 1, 9 do
    local keyfn = r['ImGui_Key_' .. n]
    if keyfn and pressed(keyfn()) then rollNumbered(n) end
  end

  return not pressed(r.ImGui_Key_Escape())
end

local function loop()
  local sig = signature()
  if sig ~= state.sig then scan() end

  r.ImGui_SetNextWindowSize(ctx, 740, 280, r.ImGui_Cond_FirstUseEver())
  local visible, open = r.ImGui_Begin(ctx, 'StackLab', true)

  if visible then
    -- End must run even if the body throws, or the window stack is left
    -- unbalanced and the next frame errors somewhere unrelated. Both sibling
    -- panels wrap their frame the same way.
    local ok, err = pcall(function()
      if not keys() then open = false end
      draw()
    end)
    r.ImGui_End(ctx)

    if not ok then
      r.ShowMessageBox(tostring(err), "StackLab error", 0)
      open = false
    end
  end

  if open then r.defer(loop) end
end

scan()
r.defer(loop)
