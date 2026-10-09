-- @description PStacksLib - REAPER glue for the PietosiStacks tools
-- @version 1.0.0
-- @author pie
-- @provides [nomain] .
local r = reaper
local L = {}

local sep = package.config:sub(1, 1)
local root = ({ r.get_action_context() })[2]:match("^(.*" .. sep .. ")")

L.Core = dofile(root .. "PStacksCore.lua")

-- Seeded once per script run, in the library rather than in each caller, so
-- the actions and the panel cannot disagree. Argless math.randomseed() mixes
-- time(NULL) - one-second resolution - with the lua_State address, and every
-- trigger gets a fresh state inside REAPER's long-lived process, a classic
-- malloc-reuse candidate. Two runs inside one second could therefore seed
-- alike and repeat a pick. time_precise is sub-microsecond.
math.randomseed(math.floor(r.time_precise() * 1e6))

-- Selected items if there is a selection, otherwise every item on every
-- selected track. Returns nil when neither yields anything.
function L.scope()
  local items = {}

  local n = r.CountSelectedMediaItems(0)
  if n > 0 then
    for i = 0, n - 1 do items[#items + 1] = r.GetSelectedMediaItem(0, i) end
  else
    for t = 0, r.CountSelectedTracks(0) - 1 do
      local tr = r.GetSelectedTrack(0, t)
      for i = 0, r.CountTrackMediaItems(tr) - 1 do
        items[#items + 1] = r.GetTrackMediaItem(tr, i)
      end
    end
  end

  if #items == 0 then return nil end
  return items
end

function L.byTrack(items)
  local order, map = {}, {}
  for _, item in ipairs(items) do
    local key = tostring(r.GetMediaItemTrack(item))
    if not map[key] then
      map[key] = {}
      order[#order + 1] = key
    end
    local bucket = map[key]
    bucket[#bucket + 1] = item
  end

  local out = {}
  for _, key in ipairs(order) do out[#out + 1] = map[key] end
  return out
end

function L.read(item)
  local take = r.GetActiveTake(item)
  local ok, guid = r.GetSetMediaItemInfo_String(item, "GUID", "", false)
  return {
    item   = item,
    take   = take,
    -- Core is pure and cannot ask REAPER whether a take exists, so the fact
    -- travels as a plain field (orderPool sorts takeless members last).
    noTake = take == nil,
    pos    = r.GetMediaItemInfo_Value(item, "D_POSITION"),
    len    = r.GetMediaItemInfo_Value(item, "D_LENGTH"),
    mute   = r.GetMediaItemInfo_Value(item, "B_MUTE"),
    name   = (take and r.GetTakeName(take)) or "",
    guid   = ok and guid or tostring(item),
  }
end

function L.readAll(items)
  local out = {}
  for i, item in ipairs(items) do out[i] = L.read(item) end
  return out
end

function L.setName(rec, name)
  if rec.take then
    r.GetSetMediaItemTakeInfo_String(rec.take, "P_NAME", name, true)
  end
end

function L.getExt(item, key)
  local ok, value = r.GetSetMediaItemInfo_String(item, "P_EXT:" .. key, "", false)
  if ok and value ~= "" then return value end
  return nil
end

function L.setExt(item, key, value)
  r.GetSetMediaItemInfo_String(item, "P_EXT:" .. key, value or "", true)
end

-- The one place item geometry gets written. restore and Unpack both go
-- through here, so a new field (say D_STARTOFFS) has exactly one write site
-- to grow into.
function L.setGeometry(item, pos, len, fadeIn, fadeOut)
  r.SetMediaItemInfo_Value(item, "D_POSITION",   pos)
  r.SetMediaItemInfo_Value(item, "D_LENGTH",     len)
  r.SetMediaItemInfo_Value(item, "D_FADEINLEN",  fadeIn)
  r.SetMediaItemInfo_Value(item, "D_FADEOUTLEN", fadeOut)
end

-- Position, length and BOTH fades. The fade-in matters: planUnpack sets one,
-- so a snapshot that omits it silently destroys the original on every restore.
-- Writer and reader live together here so the field order cannot drift.
function L.snapshot(item)
  return string.format("%.17g|%.17g|%.17g|%.17g",
    r.GetMediaItemInfo_Value(item, "D_POSITION"),
    r.GetMediaItemInfo_Value(item, "D_LENGTH"),
    r.GetMediaItemInfo_Value(item, "D_FADEINLEN"),
    r.GetMediaItemInfo_Value(item, "D_FADEOUTLEN"))
end

-- Restores anything Unpack moved and clears PietosiStacks' own state. Shared by
-- the Restore action and by Unpack's re-entrancy guard. Safe on items that were
-- never touched.
function L.restore(items)
  for _, item in ipairs(items) do
    local orig = L.getExt(item, "pstacks_orig")
    if orig then
      local pos, len, fin, fout = orig:match("^([^|]+)|([^|]+)|([^|]+)|([^|]+)$")
      if pos then
        L.setGeometry(item, tonumber(pos), tonumber(len),
          tonumber(fin), tonumber(fout))
        -- Only clear once it has actually been applied. A value we could not
        -- parse is the only way back for this item, so it survives instead.
        L.setExt(item, "pstacks_orig", "")
      end
    end

    -- Un-mute only what Roll muted. B_MUTE carries no provenance, so without
    -- this marker a Restore over a whole track would wipe the user's own mutes.
    if L.getExt(item, "pstacks_muted") then
      r.SetMediaItemInfo_Value(item, "B_MUTE", 0)
      L.setExt(item, "pstacks_muted", "")
    end

    L.setExt(item, "pstacks_last", "")
  end
end

-- One undo point, UI frozen for the duration, errors in a dialog rather than
-- REAPER's console so a half-applied pass is obvious. No scope resolution:
-- callers that already know their items use this directly.
function L.runScoped(label, fn)
  r.PreventUIRefresh(1)
  r.Undo_BeginBlock()

  local ok, err = pcall(fn)

  r.Undo_EndBlock(label, -1)
  r.PreventUIRefresh(-1)
  r.UpdateArrange()

  if not ok then
    r.ShowMessageBox(tostring(err), "PietosiStacks error", 0)
  end
end

-- The action-script entry point: resolve scope, bail with a message when there
-- is nothing to work on, then delegate.
function L.run(label, fn)
  local items = L.scope()
  if not items then
    r.ShowMessageBox(
      "Select some items, or select the tracks you want to work on.",
      "PietosiStacks", 0)
    return
  end

  L.runScoped(label, function() fn(items) end)
end

-- One pool, one winner. Shared by the Roll action and StackLab so the two can
-- never drift apart. Expects a group of 2 or more; callers gate on that.
function L.rollPool(group)
  local C = L.Core
  local anchor = C.anchor(group)

  -- The previous winner is remembered by GUID, not by position in the pool. An
  -- index into detection order silently pointed at the wrong slice as soon as
  -- a member was added or deleted between rolls - the GUID survives any
  -- membership change, and a winner that no longer exists resolves to "no
  -- memory".
  local lastGuid = L.getExt(anchor.item, "pstacks_last")
  local last
  if lastGuid then
    for i, rec in ipairs(group) do
      if rec.guid == lastGuid then last = i break end
    end
  end

  -- A member is drawable unless it has no take (nothing to play) or the user
  -- muted it by hand (a mute with no marker of ours on it) - either way it must
  -- never win a slot. resolveDraw returns nil when nothing in the pool is
  -- drawable, and then the pool is left alone entirely.
  local weights, drawable, userMuted = {}, {}, {}
  for i, rec in ipairs(group) do
    local _, _, w = C.parseName(rec.name)
    weights[i] = w
    userMuted[i] = rec.mute == 1 and not L.getExt(rec.item, "pstacks_muted")
    drawable[i] = not rec.noTake and not userMuted[i]
  end

  local resolved = C.resolveDraw(weights, drawable)
  if not resolved then return end

  local pick = C.weightedPick(C.applyNoRepeat(resolved, last), math.random)

  -- The marker is what lets Restore tell our mutes from the user's own. A
  -- hand-muted member is not written to at all: its mute stays the user's,
  -- unmarked, and Restore will never touch it.
  for i, rec in ipairs(group) do
    if not userMuted[i] then
      if i == pick then
        r.SetMediaItemInfo_Value(rec.item, "B_MUTE", 0)
        L.setExt(rec.item, "pstacks_muted", "")
      else
        r.SetMediaItemInfo_Value(rec.item, "B_MUTE", 1)
        L.setExt(rec.item, "pstacks_muted", "1")
      end
    end
  end

  L.setExt(anchor.item, "pstacks_last", group[pick].guid)
end

-- Number the members that can carry a name. A takeless member has no take to
-- write to, so giving it a number would leave a silent gap in the sequence
-- (s1, s3) with nothing visible to explain it. Shared by the Label action and
-- StackLab.
function L.labelPool(group)
  local C = L.Core
  local n = 0
  for _, rec in ipairs(group) do
    if not rec.noTake then
      n = n + 1
      local base, _, weight = C.parseName(rec.name)
      L.setName(rec, C.formatName(base, n, weight))
    end
  end
end

-- Spread one pool across the slot it was measured for. Shared by the Unpack
-- action and StackLab. Expects a group of 2 or more.
function L.unpackPool(group, slotLength)
  local C = L.Core

  -- Membership comes from the whole track, so a pool can hold members an
  -- earlier Roll muted - those would leave silent holes in the burst. Restore
  -- the pool's own members (marker-gated, so user mutes are untouched), then
  -- re-read them so the plan sees restored geometry.
  local memberItems = {}
  for _, rec in ipairs(group) do
    memberItems[#memberItems + 1] = rec.item
  end
  L.restore(memberItems)
  for j, rec in ipairs(group) do group[j] = L.read(rec.item) end

  local ordered = C.orderPool(group)
  local plan = C.planUnpack(ordered, slotLength)

  for i, rec in ipairs(ordered) do
    -- A snapshot that survived L.restore is one it could not parse, and is
    -- that item's only way home. Never overwrite it with a snapshot of the
    -- position it is currently stuck at.
    if not L.getExt(rec.item, "pstacks_orig") then
      L.setExt(rec.item, "pstacks_orig", L.snapshot(rec.item))
    end
    L.setGeometry(rec.item, plan[i].pos, plan[i].len,
      plan[i].fadeIn, plan[i].fadeOut)
  end
end

-- Every action walks the same shape: for each track the scope touches, group
-- THE WHOLE TRACK's items and hand back the groups, each flagged with whether
-- the scope reached it.
--
-- Grouping over the full track rather than the scoped items is what keeps two
-- invariants honest. A pool is a physical stack: grouping a partial selection
-- would treat 3 selected members of a 5-stack as a complete pool - Roll would
-- crown a winner while the 2 unselected siblings keep sounding on top of it,
-- and Label would renumber the subset into colliding tags. And Unpack's slot
-- must end at the next REAL item on the track: measured against only the
-- selected items, a burst can spread straight over an unselected slice
-- sitting between two pools. Stacked items render in separate lanes and TOL
-- spans real pixels under a marquee, so partial stack selections happen in
-- ordinary editing, not just contrived ones.
--
-- Selection therefore picks WHICH pools an action touches (group.inScope);
-- membership always comes from the track itself.
function L.eachTrackGroups(items, fn)
  local inScope = {}
  for _, item in ipairs(items) do inScope[tostring(item)] = true end

  for _, scopedItems in ipairs(L.byTrack(items)) do
    local track = r.GetMediaItemTrack(scopedItems[1])

    local trackItems = {}
    for i = 0, r.CountTrackMediaItems(track) - 1 do
      trackItems[#trackItems + 1] = r.GetTrackMediaItem(track, i)
    end

    local groups = L.Core.groupByStart(L.readAll(trackItems), L.Core.TOL)
    for _, group in ipairs(groups) do
      for _, rec in ipairs(group) do
        if inScope[tostring(rec.item)] then
          group.inScope = true
          break
        end
      end
    end

    fn(groups)
  end
end

return L
