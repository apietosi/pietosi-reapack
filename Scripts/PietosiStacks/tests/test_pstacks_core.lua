local here = arg[0]:match("^(.*)/[^/]+$") or "."
local H = dofile(here .. "/harness.lua")
local C = dofile(here .. "/../PStacksCore.lua")

local b2, idx, w2

b2, idx, w2 = C.parseName("kick s2 x3")
H.eq(b2, "kick", "parseName full base")
H.eq(idx, 2, "parseName full index")
H.eq(w2, 3, "parseName full weight")

b2, idx, w2 = C.parseName("kick s2")
H.eq(idx, 2, "parseName label without weight")
H.eq(w2, 1, "parseName label without weight defaults")

b2, idx, w2 = C.parseName("kick")
H.eq(b2, "kick", "parseName no label base")
H.eq(idx, nil, "parseName no label index is nil")

b2, idx, w2 = C.parseName("bass s10 x0")
H.eq(idx, 10, "parseName two-digit index")
H.eq(w2, 0, "parseName benched weight")

H.eq(C.formatName("kick", 2, 3), "kick s2 x3", "formatName full")
H.eq(C.formatName("kick", 2, 1), "kick s2", "formatName omits weight 1")
H.eq(C.formatName("kick", 1, 0), "kick s1 x0", "formatName keeps weight 0")
H.eq(C.formatName("kick", 2, 2.5), "kick s2 x2.5", "formatName fractional")
H.eq(C.formatName("", 1, 1), "s1", "formatName with empty base")
H.eq(C.formatName("kick", nil, 3), "kick x3", "formatName with no index")
H.eq(C.formatName("kick", 2.0, 1), "kick s2", "formatName integer-valued float index stays clean")

-- Trailing whitespace must not hide a tag. A stray trailing space/tab after
-- "x0" is a one-keystroke accident in REAPER's arrange view, and the tag
-- must still parse.
local base4, idx3, w4
base4, idx3, w4 = C.parseName("kick s2 x0 ")
H.eq(base4, "kick", "parseName trailing space still reads base")
H.eq(idx3, 2, "parseName trailing space still reads index")
H.eq(w4, 0, "parseName trailing space still reads x0")

-- Round-trip property: formatting a parsed name reproduces it exactly, for
-- every well-formed name shape the tools themselves produce.
local roundtrip = {
  "kick s1",
  "kick s2 x3",
  "kick s10 x0",
  "kick s2 x2.5",
  "s1",
  "kick",
  "matrix2",
  "remix",
}
for _, n in ipairs(roundtrip) do
  local rb, ri, rw = C.parseName(n)
  H.eq(C.formatName(rb, ri, rw), n, "round-trip: " .. n)
end

-- formatName must never throw, even for an index with no exact integer
-- representation (e.g. a value far beyond any real slice count).
local ok5, result5 = pcall(C.formatName, "kick", 1e20, 1)
H.eq(ok5, true, "formatName with huge float index does not raise")
H.eq(type(result5), "string", "formatName with huge float index returns a string")

-- Leading whitespace must be trimmed symmetrically with trailing, so
-- "  kick" and "kick " canonicalize the same way, and a label separated
-- from a leading space (" s2 ") still parses instead of collapsing base
-- and label into the wrong shape.
local base7, idx7, w7
base7, idx7, w7 = C.parseName("  kick")
H.eq(base7, "kick", "parseName trims leading whitespace from base")
H.eq(idx7, nil, "parseName leading-whitespace name has no index")
H.eq(C.formatName(base7, idx7, w7), "kick", "leading-whitespace name canonicalizes to its trimmed form")

local base8, idx8, w8
base8, idx8, w8 = C.parseName(" s2 ")
H.eq(base8, "", "parseName ' s2 ' has empty base")
H.eq(idx8, 2, "parseName ' s2 ' reads index 2")
H.eq(w8, 1, "parseName ' s2 ' weight is default")
H.eq(C.formatName(base8, idx8, w8), "s2", "' s2 ' canonicalizes to 's2'")

-- All-whitespace deliberately does NOT round-trip: it canonicalizes to the
-- empty string, same as any other name with nothing left after trimming.
local base9, idx9, w9
base9, idx9, w9 = C.parseName("   ")
H.eq(base9, "", "parseName all-whitespace name has empty base")
H.eq(idx9, nil, "parseName all-whitespace name has no index")
H.eq(w9, 1, "parseName all-whitespace name weight is default")
H.eq(C.formatName(base9, idx9, w9), "", "all-whitespace name canonicalizes to empty string, not itself")

-- The bare-label branch of parseName (a name that is nothing but s<digits>)
-- was only reached by one lowercase, weightless case. Pin it combined with a
-- weight tag and in uppercase, so a regression there cannot pass silently.
local baseB, idxB, wB

baseB, idxB, wB = C.parseName("s5 x3")
H.eq(baseB, "", "parseName bare label with weight has empty base")
H.eq(idxB, 5, "parseName bare label with weight keeps index")
H.eq(wB, 3, "parseName bare label with weight keeps weight")
H.eq(C.formatName(baseB, idxB, wB), "s5 x3", "bare label with weight round-trips")

baseB, idxB, wB = C.parseName("S5 X3")
H.eq(idxB, 5, "parseName uppercase bare label keeps index")
H.eq(wB, 3, "parseName uppercase bare label keeps weight")
H.eq(C.formatName(baseB, idxB, wB), "s5 x3", "uppercase bare label canonicalizes to lowercase tags")

-- Tag order must not matter: a hand-edited "kick x3 s1" must parse
-- identically to the canonical "kick s1 x3", and both must format back to
-- the canonical order.
local baseC1, idxC1, wC1
baseC1, idxC1, wC1 = C.parseName("kick x3 s1")
H.eq(baseC1, "kick", "parseName x-then-s order base")
H.eq(idxC1, 1, "parseName x-then-s order index")
H.eq(wC1, 3, "parseName x-then-s order weight")
H.eq(C.formatName(baseC1, idxC1, wC1), "kick s1 x3", "x-then-s order formats to canonical order")

local baseC2, idxC2, wC2
baseC2, idxC2, wC2 = C.parseName("kick s1 x3")
H.eq(baseC2, "kick", "parseName s-then-x order base")
H.eq(idxC2, 1, "parseName s-then-x order index")
H.eq(wC2, 3, "parseName s-then-x order weight")
H.eq(C.formatName(baseC2, idxC2, wC2), "kick s1 x3", "s-then-x order formats to canonical order")

local baseC3, idxC3, wC3
baseC3, idxC3, wC3 = C.parseName("bass x0 s10")
H.eq(baseC3, "bass", "parseName bass x0 s10 base")
H.eq(idxC3, 10, "parseName bass x0 s10 index")
H.eq(wC3, 0, "parseName bass x0 s10 weight")
H.eq(C.formatName(baseC3, idxC3, wC3), "bass s10 x0", "bass x0 s10 formats to canonical order")

local function it(pos, len, name, guid)
  return { pos = pos, len = len, name = name or "", guid = guid or tostring(pos) }
end

local g

g = C.groupByStart({ it(1.0, 0.2, "", "b"), it(1.0, 0.3, "", "a") }, 0.020)
H.eq(#g, 1, "identical starts make one group")
H.eq(#g[1], 2, "identical starts group both items")
H.eq(g[1][1].guid, "a", "ties break on ascending guid")

g = C.groupByStart({ it(1.0, 0.2, "", "a"), it(1.019, 0.2, "", "b") }, 0.020)
H.eq(#g, 1, "starts inside tolerance group")

g = C.groupByStart({ it(1.0, 0.2, "", "a"), it(1.021, 0.2, "", "b") }, 0.020)
H.eq(#g, 2, "starts outside tolerance do not group")

g = C.groupByStart({ it(1.0, 0.2, "", "a") }, 0.020)
H.eq(#g, 1, "a lone item is still returned as a group")
H.eq(#g[1], 1, "the lone group has one member")

-- A long slice whose TAIL covers a later start must not group with it.
g = C.groupByStart({ it(1.0, 2.0, "", "a"), it(1.5, 0.2, "", "b") }, 0.020)
H.eq(#g, 2, "overlap by tail does not group")

-- Comparison is against the GROUP start, not the previous item, so a drifting
-- run cannot chain into one oversized pool.
g = C.groupByStart({
  it(1.000, 0.1, "", "a"), it(1.015, 0.1, "", "b"),
  it(1.030, 0.1, "", "c"), it(1.045, 0.1, "", "d"),
}, 0.020)
H.eq(#g, 2, "drift does not chain into one group")
H.eq(#g[1], 2, "first drift group takes two")
H.eq(#g[2], 2, "second drift group takes two")

g = C.groupByStart({}, 0.020)
H.eq(#g, 0, "empty input yields no groups")

g = C.groupByStart({ it(2.0, 0.1, "", "z"), it(1.0, 0.1, "", "y") }, 0.020)
H.eq(g[1][1].pos, 1.0, "groups come back in ascending time order")

H.eq(C.anchor({ it(1, 0.1, "", "m"), it(1, 0.1, "", "c"), it(1, 0.1, "", "t") }).guid,
  "c", "anchor is the lowest guid in the pool")

local function fixed(v) return function() return v end end

H.eq(C.weightedPick({ 1, 1, 1 }, fixed(0.0)),  1, "pick lands on first at 0.0")
H.eq(C.weightedPick({ 1, 1, 1 }, fixed(0.34)), 2, "pick lands on second past 1/3")
H.eq(C.weightedPick({ 1, 1, 1 }, fixed(0.67)), 3, "pick lands on third past 2/3")
H.eq(C.weightedPick({ 3, 1 }, fixed(0.74)),    1, "heavier candidate owns more range")
H.eq(C.weightedPick({ 3, 1 }, fixed(0.76)),    2, "lighter candidate owns the tail")
H.eq(C.weightedPick({ 1, 0, 1 }, fixed(0.6)),  3, "zero weight is never drawn")
H.eq(C.weightedPick({ 0, 0 }, fixed(0.6)),     2, "all zero falls back to equal odds")
H.eq(C.weightedPick({ 1, 1 }, fixed(0.999999)), 2, "value just under 1 stays in range")

-- Distribution: an x3 slice should land about three times as often as its
-- untagged sibling. 10k draws, generous tolerance, deterministic seed.
math.randomseed(20260814)
local counts = { 0, 0 }
for _ = 1, 10000 do
  local i = C.weightedPick({ 3, 1 }, math.random)
  counts[i] = counts[i] + 1
end
H.near(counts[1] / counts[2], 3.0, 0.35, "x3 draws about 3x as often as x1")

local nr

nr = C.applyNoRepeat({ 1, 1, 1 }, 2)
H.eq(nr[2], 0, "no-repeat benches the last winner")
H.eq(nr[1], 1, "no-repeat leaves other weights alone")
H.eq(nr[3], 1, "no-repeat leaves the slot after the benched one alone")

nr = C.applyNoRepeat({ 1, 1 }, 2)
H.eq(nr[2], 1, "no-repeat is skipped for a pool of two")

nr = C.applyNoRepeat({ 1, 1, 1 }, nil)
H.eq(nr[2], 1, "no-repeat is skipped with no recorded winner")

nr = C.applyNoRepeat({ 0, 1, 0 }, 2)
H.eq(nr[2], 1, "no-repeat is skipped when it would empty the pool")

-- Candidate ranges are half-open: a target landing exactly on a cumulative
-- boundary belongs to the NEXT candidate. Without these, `target <= acc`
-- passes every other assertion in this file identically.
H.eq(C.weightedPick({ 1, 1, 1 }, fixed(1 / 3)), 2, "exact boundary goes to the next candidate")
H.eq(C.weightedPick({ 1, 1 }, fixed(0.5)), 2, "exact midpoint goes to the second candidate")

local pool, ordered, plan

pool = { it(1, 0.1, "kick s3"), it(1, 0.1, "kick s1"), it(1, 0.1, "kick s2") }
ordered = C.orderPool(pool)
H.eq(ordered[1].name, "kick s1", "orderPool sorts by label index")
H.eq(ordered[3].name, "kick s3", "orderPool puts s3 last")

pool = { it(1, 0.1, "kick s3"), it(1, 0.1, "kick"), it(1, 0.1, "kick s2") }
ordered = C.orderPool(pool)
H.eq(ordered[1].name, "kick s3", "orderPool keeps detection order if any label is missing")

-- Three slices in a 0.6 s slot: triplets at 0.2 s apart.
plan = C.planUnpack({ it(1.0, 0.5), it(1.0, 0.5), it(1.0, 0.5) }, 0.6)
H.eq(#plan, 3, "planUnpack returns one entry per slice")
H.near(plan[1].pos, 1.0, 1e-9, "first slice does not move")
H.near(plan[2].pos, 1.2, 1e-9, "second slice lands one step in")
H.near(plan[3].pos, 1.4, 1e-9, "third slice lands two steps in")
H.near(plan[1].len, 0.2, 1e-9, "slices are trimmed to the step")

-- Five slices in the same slot: quintuplets. Subdivision follows the pile.
plan = C.planUnpack({ it(1, 0.5), it(1, 0.5), it(1, 0.5), it(1, 0.5), it(1, 0.5) }, 0.6)
H.near(plan[2].pos, 1.12, 1e-9, "five slices subdivide the slot evenly")

-- A slice already shorter than the step keeps its own length.
plan = C.planUnpack({ it(1.0, 0.05), it(1.0, 0.5) }, 0.6)
H.near(plan[1].len, 0.05, 1e-9, "short slice is not stretched")
H.near(plan[2].len, 0.3, 1e-9, "long slice is trimmed to the step")

-- Fades never exceed half the new length.
plan = C.planUnpack({ it(1.0, 0.004), it(1.0, 0.5) }, 0.6)
H.near(plan[1].fadeOut, 0.002, 1e-9, "fade out is clamped to half the length")
H.near(plan[1].fadeIn, 0.001, 1e-9, "fade in stays at the default when it fits")
H.near(plan[2].fadeOut, 0.005, 1e-9, "normal slice gets the default fade out")

-- The anchor is the pool's own start, not zero.
plan = C.planUnpack({ it(7.5, 0.2), it(7.5, 0.2) }, 0.4)
H.near(plan[1].pos, 7.5, 1e-9, "unpack anchors on the pool start")
H.near(plan[2].pos, 7.7, 1e-9, "second slice offsets from the pool start")

-- A relabelled pool must not shift planUnpack's anchor. orderPool can put a
-- later-positioned slice first (that is the whole point of relabelling
-- playback order); planUnpack must still anchor on the pool's true earliest
-- position, not whichever record ends up at index 1 after ordering.
pool = { it(10.000, 0.1, "kick s3"), it(10.008, 0.1, "kick s2"), it(10.019, 0.1, "kick s1") }
ordered = C.orderPool(pool)
H.near(ordered[1].pos, 10.019, 1e-9, "sanity: relabelling puts the later slice first")
plan = C.planUnpack(ordered, 0.6)
H.near(plan[1].pos, 10.000, 1e-9, "planUnpack anchors on the pool's earliest position, not orderPool's index 1")
local lastEnd = plan[#plan].pos + plan[#plan].len
H.eq(lastEnd <= 10.600 + 1e-9, true, "relabelled burst does not overrun its slot")

-- Duplicate label index: two members carry the same hand-typed s2 label.
-- orderPool must not error, and the tie must resolve by detection order.
local dupA = it(1, 0.1, "kick s2", "a")
local dupB = it(1, 0.1, "kick s1", "b")
local dupC = it(1, 0.1, "kick s2", "c")
local dupOk, dupOrdered = pcall(C.orderPool, { dupA, dupB, dupC })
H.eq(dupOk, true, "orderPool does not error on duplicate label indices")
local idxA, idxC
for i, rec in ipairs(dupOrdered) do
  if rec.guid == "a" then idxA = i end
  if rec.guid == "c" then idxC = i end
end
H.eq(idxA < idxC, true, "duplicate s2 members keep their relative detection order")

-- orderPool purity: new array, same record identities, input left untouched.
local pureA = it(1, 0.1, "kick s2", "x")
local pureB = it(1, 0.1, "kick s1", "y")
local purePool = { pureA, pureB }
local pureOrdered = C.orderPool(purePool)
H.eq(pureOrdered ~= purePool, true, "orderPool returns a different table from the input")
H.eq(pureOrdered[1] == pureB, true, "orderPool result holds the same record object, not a copy")
H.eq(purePool[1] == pureA and purePool[2] == pureB, true, "orderPool leaves the input array's own order unchanged")

-- Both fades clamp at once when the step is under 2x the default fade-in.
plan = C.planUnpack({ it(1.0, 0.5), it(1.0, 0.5) }, 0.0016)
local half = plan[1].len / 2
H.near(plan[1].fadeIn, half, 1e-9, "fade in clamps to half the length when the step is tiny")
H.near(plan[1].fadeOut, half, 1e-9, "fade out clamps to half the length when the step is tiny")
H.near(plan[1].fadeIn + plan[1].fadeOut, plan[1].len, 1e-9, "clamped fades sum to exactly the slice length")

-- slotLength: how much room a pool gets to spread into.
local groupsA = {
  { it(1.0, 0.1, "", "a") },
  { it(1.5, 0.1, "", "b") },
}
H.near(C.slotLength(groupsA, 1), 0.5, 1e-9, "slotLength runs to the next group's start")

-- Last group on the track falls back to its longest member's length, not
-- whichever member happens to be first.
local groupsB = {
  { it(2.0, 0.1, "", "a"), it(2.0, 0.5, "", "b"), it(2.0, 0.3, "", "c") },
}
H.near(C.slotLength(groupsB, 1), 0.5, 1e-9,
  "slotLength on the last group picks the longest member, not the first")

-- A lone slice sitting between two pools must stop the first pool's slot at
-- the lone slice's start, not run over it to the next pool. Built through
-- groupByStart on real records so the group shape (pool, singleton, pool) is
-- the actual output of the grouping logic, not a hand-built stand-in for it.
local betweenRecs = {
  it(0.0, 0.2, "", "a1"), it(0.0, 0.2, "", "a2"),
  it(0.5, 0.3, "", "lone"),
  it(1.0, 0.2, "", "b1"), it(1.0, 0.2, "", "b2"),
}
local groupsC = C.groupByStart(betweenRecs, C.TOL)
H.eq(#groupsC, 3, "sanity: pool, lone slice, pool forms three groups")
H.eq(#groupsC[2], 1, "sanity: the middle group is the lone slice")
H.near(C.slotLength(groupsC, 1), 0.5, 1e-9,
  "slotLength stops the first pool's slot at the lone slice, not the next pool")

-- A weight tag that LEADS the name with no base text must still parse once an
-- index tag proves tag syntax is in use. Without this, "x0 s2" reads as base
-- "x0" weight 1 - a deliberately benched slice re-enters the draw silently.
local baseW, idxW, wW

baseW, idxW, wW = C.parseName("x0 s2")
H.eq(baseW, "", "parseName leading bare weight has empty base")
H.eq(idxW, 2, "parseName leading bare weight keeps index")
H.eq(wW, 0, "parseName leading bare weight reads x0")
H.eq(C.formatName(baseW, idxW, wW), "s2 x0", "leading bare weight canonicalizes to label-first order")

baseW, idxW, wW = C.parseName("x3 s1")
H.eq(wW, 3, "parseName leading bare x3 reads weight 3")
H.eq(idxW, 1, "parseName leading bare x3 keeps index")

baseW, idxW, wW = C.parseName("X2.5 s4")
H.eq(wW, 2.5, "parseName leading bare uppercase fractional weight parses")

-- Without any index tag there is no evidence "x3" means a weight, so it stays
-- a base name - matching the long-standing bare-name rule.
baseW, idxW, wW = C.parseName("x3")
H.eq(baseW, "x3", "parseName bare x3 alone stays a base name")
H.eq(wW, 1, "parseName bare x3 alone keeps default weight")

-- resolveDraw: folds drawability into the weights before a pick.
local rd

rd = C.resolveDraw({ 2, 1 }, nil)
H.eq(rd[1], 2, "resolveDraw with nil drawable passes weights through")
H.eq(rd[2], 1, "resolveDraw with nil drawable passes all weights through")

rd = C.resolveDraw({ 2, 1, 5 }, { true, true, false })
H.eq(rd[3], 0, "resolveDraw zeroes an undrawable member's weight")
H.eq(rd[1], 2, "resolveDraw leaves drawable weights alone")

-- All weights zero but some members drawable: equal odds among the drawable
-- only. This is the case weightedPick's own fallback gets wrong - it would
-- share odds with members that cannot sound.
rd = C.resolveDraw({ 0, 0, 0 }, { true, false, true })
H.eq(rd[1], 1, "resolveDraw all-zero fallback includes drawable members")
H.eq(rd[2], 0, "resolveDraw all-zero fallback excludes undrawable members")
H.eq(rd[3], 1, "resolveDraw all-zero fallback includes the other drawable member")

rd = C.resolveDraw({ 1, 1 }, { false, false })
H.eq(rd, nil, "resolveDraw returns nil when no member is drawable")

rd = C.resolveDraw({}, nil)
H.eq(rd, nil, "resolveDraw returns nil for an empty pool")

-- A takeless member cannot carry a label, so it must not veto label ordering
-- for the whole pool. It sorts after every labelled member instead.
local tkA = it(1, 0.1, "kick s2", "a")
local tkB = it(1, 0.1, "", "b"); tkB.noTake = true
local tkC = it(1, 0.1, "kick s1", "c")
ordered = C.orderPool({ tkA, tkB, tkC })
H.eq(ordered[1].guid, "c", "takeless member does not veto label ordering: s1 first")
H.eq(ordered[2].guid, "a", "takeless member does not veto label ordering: s2 second")
H.eq(ordered[3].guid, "b", "takeless member sorts after every labelled member")

-- But an unlabelled member WITH a take still falls the pool back to detection
-- order, exactly as before.
local tkD = it(1, 0.1, "kick s2", "d")
local tkE = it(1, 0.1, "kick", "e")
ordered = C.orderPool({ tkD, tkE })
H.eq(ordered[1].guid, "d", "unlabelled take-bearing member still forces detection order")

-- Records carrying a mute state, which the shared `it` helper does not set.
local function itm(pos, mute)
  return { pos = pos, len = 0.1, name = "", guid = tostring(pos), mute = mute }
end

H.eq(C.poolInRange({ itm(1.0) }, 0.5, 1.5), true, "poolInRange: member inside")
H.eq(C.poolInRange({ itm(0.5) }, 0.5, 1.5), true, "poolInRange: lower bound is inside")
H.eq(C.poolInRange({ itm(1.5) }, 0.5, 1.5), false, "poolInRange: upper bound is outside")
H.eq(C.poolInRange({ itm(0.4) }, 0.5, 1.5), false, "poolInRange: member before the range")
H.eq(C.poolInRange({ itm(0.4), itm(1.0) }, 0.5, 1.5), true, "poolInRange: one member inside is enough")
H.eq(C.poolInRange({}, 0.5, 1.5), false, "poolInRange: empty pool is never in range")

H.eq(C.poolWinner({ itm(1, 1), itm(1, 0), itm(1, 1) }), 2, "poolWinner: the one unmuted member")
H.eq(C.poolWinner({ itm(1, 0) }), 1, "poolWinner: pool of one")
H.eq(C.poolWinner({ itm(1, 1), itm(1, 1) }), nil, "poolWinner: nothing unmuted")
H.eq(C.poolWinner({ itm(1, 0), itm(1, 0) }), nil, "poolWinner: several unmuted is the never-rolled state")

H.report()
