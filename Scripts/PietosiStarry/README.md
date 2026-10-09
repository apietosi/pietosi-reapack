# PietosiStarry

Makes the MPL RS5k manager keep up with the Donner STARRYPAD, so hitting the
pad's bank buttons just works.

## Why it was broken

- The manager only turns pages in its **Default** pad layout. The **Custom**
  layout always shows the same notes, so pads in bank B and C were off-screen.
- The manager never moves the page when notes come in. It only highlights the
  pad, and only if that pad is already on the page you're looking at.
- The manager saves its MIDI input as a slot number, not a device name. If
  REAPER moves the pad to a different slot, the manager is left pointing at the
  wrong device.

## Actions

| Action | What it does |
|---|---|
| `PietosiStarry_Setup` | Run once with the manager closed. Switches it to the 4x4 pad layout, finds the pad's MIDI input by name, turns off the manager's own note-follow (it fights this one), and fixes the selected kit's page and MIDI bus input |
| `PietosiStarry_Follow` | Background toggle, started by `__startup.lua`. Hit a pad and the manager jumps to that pad's bank and selects that pad |

## Banks

Factory map: A = 36–51, B = 52–67, C = 68–83. If you remapped the pad in
Donner's editor, override it in `reaper-extstate.ini`:

```ini
[PietosiStarry]
base=36
bank_size=16
device=starrypad
follow_note=1
```

`follow_note=0` flips the page without changing which pad is selected.

## How the refresh works

The manager only reloads its track data when the project changes, the edit
cursor moves, or you switch projects. Saving the page to the track changes
none of those. So after each page change, Follow moves the edit cursor by one
microsecond, then moves it back once the pads have been quiet for 0.2 s. This
never shows up in undo history. If you move the cursor yourself in that time,
Follow leaves it where you put it.

For 0.5 s after a bank change, Follow puts the new page back if anything else
switches it to the old one. After that, scrolling the manager by hand works as
normal.

## Tests

```
lua tests/test_pstarry_core.lua
```
