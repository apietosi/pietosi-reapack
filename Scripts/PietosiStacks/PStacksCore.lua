-- @description PStacksCore - pure logic for the PietosiStacks tools
-- @version 1.0.0
-- @author pie
-- @provides [nomain] .
-- No reaper API in this file. It must stay loadable by a stock lua binary.
local C = {}

C.TOL      = 0.020
C.FADE_IN  = 0.001
C.FADE_OUT = 0.005

-- Tags are stripped from the end in either order, so a hand-edited
-- "kick x3 s1" reads the same as the canonical "kick s1 x3". Anchoring to a
-- fixed order meant the wrong order silently parsed as weight 1 with the tag
-- swallowed into the base - no error, and identical in the arrange view.
function C.parseName(name)
  local base = (name or ""):match("^%s*(.-)%s*$")
  local idx, weight

  local stripped = true
  while stripped do
    stripped = false
    if not weight then
      local b, n = base:match("^(.-)%s+[xX](%d+%.?%d*)$")
      if b then base, weight, stripped = b, tonumber(n), true end
    end
    if not idx then
      local b, n = base:match("^(.-)%s+[sS](%d+)$")
      if b then base, idx, stripped = b, tonumber(n), true end
    end
  end

  -- A name that is nothing but a label leaves an empty base.
  if not idx then
    local n = base:match("^[sS](%d+)$")
    if n then base, idx = "", tonumber(n) end
  end

  -- The strip loop needs whitespace before a tag, so a weight tag that LEADS
  -- the name with nothing before it ("x0 s2") survives into base after the
  -- label is stripped. An index tag elsewhere in the name proves tag syntax is
  -- in use, so read the leftover as the weight it is. A name that is nothing
  -- but "x3" stays a base name on purpose - with no other tag present there is
  -- no evidence it means a weight.
  if idx and not weight then
    local n = base:match("^[xX](%d+%.?%d*)$")
    if n then base, weight = "", tonumber(n) end
  end

  return base, idx, weight or 1
end

-- math.tointeger returns nil (rather than throwing) for values with no exact
-- integer representation, e.g. 1e20 -- string.format("%d", 1e20) would raise
-- "number has no integer representation". Falling through to tostring keeps
-- formatName total for any number, at the cost of an ugly-but-harmless
-- "s1e+20" for indices no real slice pool would ever produce.
local function numstr(n)
  local i = math.tointeger(n)
  if i then return tostring(i) end
  return tostring(n)
end

-- `base` is assumed already stripped of any label/weight tags (i.e. it came
-- from parseName, not a raw take name). Leading/trailing
-- whitespace, irregular internal spacing, and leading zeros in
-- index/weight are not preserved from the input that produced
-- base/index/weight -- they are deliberately canonicalized here on every
-- reformat.
function C.formatName(base, index, weight)
  local s = base or ""
  if index then
    s = (s == "") and ("s" .. numstr(index)) or (s .. " s" .. numstr(index))
  end
  if weight and weight ~= 1 then
    s = (s == "") and ("x" .. numstr(weight)) or (s .. " x" .. numstr(weight))
  end
  return s
end

-- Returns EVERY group in ascending time order, singletons included. Unpack needs
-- the singletons: its slot end is "the next item on the track", and because the
-- groups partition the items contiguously, that is the next group's start only
-- so long as lone slices are still in the sequence.
function C.groupByStart(items, tol)
  tol = tol or C.TOL
  local sorted = {}
  for i, rec in ipairs(items) do sorted[i] = rec end
  table.sort(sorted, function(a, b)
    if a.pos ~= b.pos then return a.pos < b.pos end
    return tostring(a.guid) < tostring(b.guid)
  end)

  local groups, cur = {}, nil
  for _, rec in ipairs(sorted) do
    if cur and (rec.pos - cur[1].pos) <= tol then
      cur[#cur + 1] = rec
    else
      cur = { rec }
      groups[#groups + 1] = cur
    end
  end
  return groups
end

function C.anchor(pool)
  local a = pool[1]
  for _, rec in ipairs(pool) do
    if tostring(rec.guid) < tostring(a.guid) then a = rec end
  end
  return a
end

function C.weightedPick(weights, rnd)
  local n = #weights
  if n == 0 then return nil end

  local total = 0
  for _, w in ipairs(weights) do
    if w > 0 then total = total + w end
  end

  if total <= 0 then
    return math.min(math.floor(rnd() * n) + 1, n)
  end

  local target, acc = rnd() * total, 0
  for i, w in ipairs(weights) do
    if w > 0 then
      acc = acc + w
      if target < acc then return i end
    end
  end

  for i = n, 1, -1 do
    if weights[i] > 0 then return i end
  end
  return n
end

-- Folds "can this member be drawn at all" into the weights before a pick.
-- weightedPick's all-zero fallback is equal odds across EVERYONE, which is
-- right for "every slice tagged x0" but wrong when some members are benched
-- for a harder reason - no take to play, or a mute the user set by hand.
-- drawable[i] falsy means member i must never win. Returns nil when no member
-- is drawable (the caller skips the pool entirely); otherwise returns weights
-- with undrawable members zeroed, falling back to equal odds among drawable
-- members when every drawable weight is zero.
function C.resolveDraw(weights, drawable)
  local out, total, any = {}, 0, false
  for i, w in ipairs(weights) do
    local d = (drawable == nil) or drawable[i]
    out[i] = d and w or 0
    if d then any = true end
    total = total + out[i]
  end

  if not any then return nil end

  if total <= 0 then
    for i = 1, #out do
      out[i] = ((drawable == nil) or drawable[i]) and 1 or 0
    end
  end
  return out
end

-- Pools of two are left alone on purpose: benching the last winner there gives
-- strict alternation, which is a flip-flop rather than a roll.
function C.applyNoRepeat(weights, last)
  if #weights < 3 or not last then return weights end

  local out, remaining = {}, 0
  for i, w in ipairs(weights) do
    out[i] = (i == last) and 0 or w
    if out[i] > 0 then remaining = remaining + out[i] end
  end

  if remaining <= 0 then return weights end
  return out
end

function C.orderPool(pool)
  local decorated, allLabelled = {}, true
  for i, rec in ipairs(pool) do
    local _, idx = C.parseName(rec.name or "")
    if not idx then
      if rec.noTake then
        -- A takeless member can never carry a label (there is no take to
        -- name), so it must not veto label ordering for the whole pool.
        -- It is silent anyway; sort it after every labelled member.
        idx = math.huge
      else
        allLabelled = false
      end
    end
    decorated[i] = { rec = rec, idx = idx, ord = i }
  end

  if allLabelled then
    table.sort(decorated, function(a, b)
      if a.idx ~= b.idx then return a.idx < b.idx end
      return a.ord < b.ord
    end)
  end

  local out = {}
  for i, d in ipairs(decorated) do out[i] = d.rec end
  return out
end

-- Subdivision follows the pile, not the project grid: n slices always divide
-- the slot into n, so the burst fits whatever n happens to be. Three gives
-- triplets, five gives quintuplets, and the surrounding groove never moves.
function C.planUnpack(pool, slotLength)
  local n = #pool
  local step = slotLength / n

  -- Anchor on the pool's EARLIEST position, not pool[1]. Callers hand this
  -- array over after orderPool may have reordered it by label, and members
  -- sit within TOL of each other rather than exactly together - so trusting
  -- index 1 would let a relabelled pool start up to TOL late and overrun the
  -- slot the caller measured from the pool's true start.
  local start = pool[1].pos
  for _, rec in ipairs(pool) do
    if rec.pos < start then start = rec.pos end
  end

  local out = {}
  for i, rec in ipairs(pool) do
    local len = math.min(rec.len, step)
    out[i] = {
      pos     = start + (i - 1) * step,
      len     = len,
      fadeIn  = math.min(C.FADE_IN, len / 2),
      fadeOut = math.min(C.FADE_OUT, len / 2),
    }
  end
  return out
end

-- How much room a pool gets to spread into: its own start to the start of the
-- next thing on the track. Deliberately the next GROUP rather than the next
-- pool - groupByStart returns singletons too, so the next group's start is the
-- next item's start, and a lone slice sitting between two pools does not get
-- run over. The last group on a track has nothing after it, so it borrows its
-- own longest member's length.
function C.slotLength(groups, index)
  local group = groups[index]
  local nextGroup = groups[index + 1]
  if nextGroup then
    return nextGroup[1].pos - group[1].pos
  end

  local longest = 0
  for _, rec in ipairs(group) do
    if rec.len > longest then longest = rec.len end
  end
  return longest
end

-- True when any member starts inside [a, b). Half-open on purpose: a pool
-- sitting exactly on the loop end belongs to the next loop, not this one.
function C.poolInRange(pool, a, b)
  for _, rec in ipairs(pool) do
    if rec.pos >= a and rec.pos < b then return true end
  end
  return false
end

-- The index of the single unmuted member, or nil when none or several are.
-- "Several unmuted" is the never-rolled state, and reporting nil for it is what
-- lets a caller print "-" rather than naming whichever member came first.
function C.poolWinner(pool)
  local found
  for i, rec in ipairs(pool) do
    if rec.mute == 0 then
      if found then return nil end
      found = i
    end
  end
  return found
end

return C
