# PietosiStacks

Split by transient, quantize, and you get slices shoved on top of each other at
the same grid position. This suite does two things with those piles.

**Roll** picks one slice per pile at random and mutes the rest. Nothing moves,
nothing is destroyed, so you can re-roll forever and get a different performance
every time. The previous winner is excluded from the next draw, so you never
hear the same slice twice running.

**Unpack** spreads the pile across its own slot so every slice sounds, in order.
Three slices give triplets, five give quintuplets, seven give septuplets — the
subdivision follows the pile, not the grid, so the burst always fits and the
groove around it never moves.

## Actions

| Action | What it does |
|---|---|
| `PietosiStacks_Roll` | One winner per pool, everyone else muted |
| `PietosiStacks_Unpack` | Spread each pool across its slot as a burst |
| `PietosiStacks_Label` | Write `s1`…`sn` onto take names so you can see and weight them |
| `PietosiStacks_Restore` | Un-mute and move everything home |
| `PietosiStacks_MakeTestBed` | Build a known layout on a new track for checking behaviour |
| `StackLab` | Performance panel — roll the loop, or one pile, from the keyboard |

**Scope:** selected items if you have a selection, otherwise every item on the
selected tracks. Selection chooses **which pools** an action touches — pool
membership always comes from the whole track, so selecting some slices of a
stack acts on the complete stack. (Stacked slices sit in separate lanes and are
individually clickable, so partial stack selections happen by accident all the
time; treating one as a complete pool would leave unselected siblings sounding
on top of the winner.)

## Weights

Run Label, and each slice in a pool gets named `kick s1`, `kick s2`, and so on.
Append a weight tag to bias the draw:

- `kick s2 x3` — three times as likely as an untagged sibling
- `kick s2 x0` — benched, never drawn
- no tag — weight 1

The tags work in either order, so `kick x3 s2` is the same thing — even with no
base name at all (`x0 s2` reads as benched slice 2). A slice whose take you
deleted is always benched, since it can't make sound; it also sorts to the end
of an unpacked burst and never blocks the pool's label ordering.

**Muting a pool member by hand also benches it.** Roll treats a mute it didn't
place itself as yours: that slice can't win, Roll never writes to it, and
Restore never unmutes it. If every member of a pool is benched, Roll leaves the
pool alone entirely.

## Load them

Actions → Show action list → New action → Load ReaScript, then select all five
`PietosiStacks_*.lua` files at once. `PStacksCore.lua` and `PStacksLib.lua` are
libraries — do not load those as actions.

## Layout

`PStacksCore.lua` holds every decision — grouping, weight parsing, random
selection, unpack geometry — as pure functions over plain tables, with no
reference to the `reaper` global anywhere. That's what lets it be tested outside
REAPER:

```bash
cd "$HOME/Library/Application Support/REAPER/Scripts/PietosiPad/Scripts/PietosiStacks" && lua tests/test_pstacks_core.lua
```

154 assertions, no framework, no dependencies.

`PStacksLib.lua` is the only file that talks to REAPER. The actions and StackLab
are thin wrappers over it — rolling and unpacking a pool live in the library, so
the panel and the actions share one implementation rather than two that drift.

## Checking it by hand

**The library and the actions have no automated tests.** There is no REAPER API
outside REAPER and this project does not mock it, so everything from
`PStacksLib.lua` outward is verified by running it. Work through this once.

Run `PietosiStacks_MakeTestBed`, select the new track, then:

1. **Label.** Pools show `pool1 s1`, `pool1 s2`, `pool1 s3` and so on (each
   pool shares one base name; only the `sN` suffix tells members apart). The
   lone slice at 1.0 s is untouched — still `pool3`.
2. **Roll.** Exactly one item per pool is unmuted. The lone slice stays unmuted.
   Ctrl+Z restores every mute in one press.
3. **Roll repeatedly.** Eight or ten times. Winners change, and in the pool of
   five the same slice never wins twice running.
4. **Weights.** Rename one slice in the pool of three to `pool1 s1 x0` and roll
   ten times — it never wins. Change it to `x20` and roll ten times — it wins
   nearly every time. Then try the tag the other way round, `pool1 x20 s1`, and
   confirm it behaves the same.
5. **Unpack.** Restore first, then Unpack. The pool of three becomes triplets
   inside 0–0.5 s. The pool of five becomes quintuplets inside 1.5–2.0 s. The
   lone slice at 1.0 s has not moved and has not been overrun by the pool that
   starts at 0.5 s.
6. **Unpack is re-entrant.** Run it again without restoring. Nothing changes —
   positions identical, not spread further.
7. **Roll then Unpack, on a fresh bed.** The burst sounds complete — no slice is
   left silent by the earlier roll.
8. **Restore.** Everything returns to its original position, length and fades,
   and every item is unmuted.
9. **Restore leaves your own mutes alone.** Mute the lone slice at 1.0 s by
   hand, run Roll, then Restore. Your mute is still there.
10. **Empty scope.** Deselect everything and run Roll. A message box appears and
    no undo point is created.

Two things worth confirming once, because they rest on inference rather than
observation — they were reasoned about carefully but never actually seen to
happen:

11. **Undo covers the stored state.** Read an item's extended state before Roll,
    after Roll, and after Ctrl+Z, and see whether it reverts with the mute:
    ```
    reaper.GetSetMediaItemInfo_String(item, "P_EXT:pstacks_muted", "", false)
    ```
    If it does not revert, nothing breaks — the next action overwrites it — but
    it is worth knowing which it is.
12. **Sourceless fixture items survive a save and reload.** The test bed builds
    items with no media, which should round-trip. If they vanish, the fixture is
    single-session only.

## StackLab

The panel for the stop-roll-replay loop. Select a track, make a time selection,
run `StackLab`.

- **roll the loop** (or `R`) rerolls every pile inside the time selection.
- **Each cell** is one pile, in bar.beat order, showing how many slices it holds
  and which one is sounding. Click it, or press its number, to reroll just that
  one. Lone slices are drawn greyed so the row reads as a timeline; they carry
  no number.
- **Space still plays.** The panel forwards it to the transport rather than
  swallowing it, so you can stop, roll, and replay without leaving the window.
- **unpack** and **restore** apply to the loop, not the whole track.

Selecting several tracks rolls them together. Selecting one holds the rest
steady.

Checklist, on the test bed with a loop over the whole thing:

1. No track selected reads "Select a track."; no time selection reads "Make a
   time selection." Neither is an error dialog.
2. Cells appear in time order, the lone slice at 1.0 s inert among them.
3. Rollable cells number 1–5; the inert one has no number, and pressing `3`
   hits the third *rollable* cell.
4. Roll-all changes several cells; a single cell click changes only that one.
5. Space plays and stops with the panel focused.
6. Rolling in the panel then pressing Ctrl+Z in the arrange view updates the
   panel's display within a frame.
7. Unpack spreads only the pools in the loop; pools outside it do not move.

## Known limits

- The "previous winner" is remembered by the slice's GUID on one nominated pool
  member, so adding, deleting, or reordering slices no longer confuses it. The
  memory is only lost if the previous winner itself is deleted, or if pool
  membership shifts which member is the nominee — worst case, one repeat.
- Restore does not undo Label. Names keep their labels and weights on purpose;
  losing hand-typed weights to a Restore would be worse than the names sticking
  around.
- Unpacking into a slot shorter than about 20 ms leaves the slices close enough
  together that Roll would still see them as a pool. The slices are sub-10 ms
  clicks at that point, so this has not been treated as worth guarding.
- Re-unpacking a previously unpacked pool works best with the whole burst (or
  the track) selected. Selecting only part of a spread burst restores just
  those members before re-planning, leaving the unselected ones where they are.
