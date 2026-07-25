# PadLab — launchpad-style drum sampler for REAPER

A lightweight replacement for the RS5K-manager style drum machine workflow.
One window, one row per pad. Feed each row a **folder**, **loose files**, or a
**Media Explorer database**, and it becomes a playable pad with:

- **Sample select modes** — Normal (always first sample), **Random** (new sample
  every hit), or Round-Robin
- **Auto dynamics** — velocity drives volume on every sample (toggle per row),
  plus optional velocity humanize
- **Note repeat** — Push-style: hold a pad and it rolls in time, quantized to
  the project tempo. Change the rate live while holding. Per-row or global.
- **Native routing** — every pad is a real track, so sends, buses, sidechain,
  and hardware outs all work exactly like normal REAPER tracks

## Why it doesn't crash

There is no custom audio engine. Sound comes from stock **ReaSamplomatic5000**
instances managed for you; the only custom DSP is two ~100-line MIDI JSFX
(note repeat + sample router). The GUI is a plain ReaImGui script whose draw
loop is error-trapped — a UI bug shows an error message instead of taking the
window (or REAPER) down.

## Install

1. Copy the `PadLab` folder into `%APPDATA%\REAPER\Scripts\` (the included
   installer step does this for you if you got it pre-installed).
2. In REAPER: **Actions → Show action list → New action → Load ReaScript…**
   and pick `Scripts\PadLab\PadLab.lua`.
3. Run it. The script auto-installs its two JSFX into `Effects\PadLab\` on
   first launch (and keeps them up to date).

Dependencies (both already installed if you use ReaPack): **ReaImGui**,
**js_ReaScriptAPI** (optional — nicer file/folder pickers).

## How it's structured in your project

```
PadLab            <- folder track, armed, input = all MIDI (monitor only)
 ├─ PL: kick      <- row track: NoteRepeat JSFX -> Router JSFX -> RS5K x N
 ├─ PL: hat
 └─ PL: 808
```

- Every row listens to all MIDI inputs itself (armed, monitor-only, recording
  disabled) and its Router filters to just its own pad note. The parent's arm
  only feeds the MIDI-learn monitor.
- Pad notes start at **C1 (36)** and count up one per row — matches GM drum
  mapping and most pad controllers.
- Inside a row, the Router translates the pad note to an internal note
  (0–63), one per RS5K instance. That's how random/round-robin works.
- Everything is saved in the project like normal tracks. Deleting the tracks
  deletes the pads; the GUI just mirrors project state.

## Playing

| Action | How |
|---|---|
| Play a pad | Click-hold the pad button, hit the MIDI note, or use the virtual keyboard |
| Add samples by drag & drop | Drag audio files or folders from Explorer/Media Explorer onto a **pad name** (adds to that pad) or the **drop strip at the bottom** (new pad). Folders are scanned; big drops offer a random pick. |
| Note repeat (global) | Toggle **REPEAT**, or **hold `R`** while the PadLab window is focused |
| Repeat rate | The rate dropdown, or keys **1–8** (1/4 … 1/64) — works live mid-roll |
| Repeat per row | The **Rpt** checkbox + rate per row |
| Repeat gate / feel | Right-click a pad → *Repeat gate %* |
| Random sample per hit | Row mode → **Random** |
| Humanize velocity | Right-click a pad → *Vel humanize* |
| Humanize pitch | Right-click a pad → *Pitch humanize* (random detune per hit, up to ±100 cents) |
| Re-roll a pad | Right-click a pad → *Re-roll* — replaces its samples with a fresh random pick from the folder/DB it came from |
| See loaded samples | Right-click a pad → sample list at the bottom |
| Hats that cut off | Right-click a pad → *Choke (obey note-offs)* |
| Troubleshoot | Header → **Doctor** — shows routing/FX diagnostics, one-click routing fix, copy report |
| Sidechain / bus | Row → **Route** (native REAPER routing dialog) |

## MIDI mapping (hardware pads & buttons)

Everything learns from the **last pressed control** on your controller:

- **Pad note per row**: right-click a pad → *Learn pad note* → hit the pad on
  your controller. Two rows may share a note if you want layering.
- **Repeat button** (global, all pads): header → **MIDI Map** → *Repeat* →
  Learn → press a button/pad. Choose **Momentary** (rolls while held, like
  Push) or **Toggle**. Sample-accurate — handled inside the JSFX, not the GUI.
- **Repeat rate ("quantization")**:
  - map *Rate* to a **CC knob/fader** → sweeping it moves 1/4 → 1/64 absolute
  - map *Rate* to a **button** → each press steps faster; map *Rate down* to a
    second button to step slower
- Mappings persist across projects and are auto-applied to new rows.

Under the hood a passthrough `PadLab_Monitor` JSFX on the parent track mirrors
incoming MIDI into shared memory (`gmem`) for the learn UI, and the mapped
controls are executed inside every row's NoteRepeat JSFX at audio-block
accuracy.

When adding a folder or database you're asked how many samples to load — it
random-picks that many (max 64 per row), so a 5,000-file kick database becomes
a 16-sample pad you can re-roll any time.

## MCP / scripting integration

PadLab keeps everything in plain REAPER primitives, so any ReaScript-capable
MCP server can drive it with no special API:

- **Discover**: project ext state `PADLAB` / `state` holds JSON:
  `[{"name","guid","note","samples","mode"}, ...]`
- **Identify tracks**: `P_EXT:PADLAB` is `parent` or `row`; row names are
  `PL: <name>`
- **Trigger pads**: send MIDI note 36+ to the PadLab track (it's record-armed
  with monitoring)
- **Tweak per row** (JSFX param indices):
  - `PadLab_NoteRepeat.jsfx`: 0 = on/off, 1 = rate (0–7), 2 = gate %,
    3 = velocity mode, 4 = fixed velocity, 5 = repeat map (-1 none, 0–127 CC,
    128–255 note+128), 6 = repeat button mode (0 momentary / 1 toggle),
    7 = rate map, 8 = rate-down map
  - `PadLab_Router.jsfx`: 0 = mode (0 normal / 1 random / 2 round-robin),
    1 = sample count, 2 = pad note, 3 = velocity humanize
- **Global mappings** live in persistent ext state: `PADLAB` /
  `map_repeat`, `map_rptmode`, `map_rate`, `map_ratedn`
- **Add/remove pads externally**: manipulate the tracks directly — the GUI
  rescans on every project state change and follows along.

## Notes / limits

- The row FX chains are intentionally "busy" — one RS5K per sample is what
  makes per-hit random selection possible with native samplers. Use the PadLab
  window as the front end; you rarely need to open the chains.
- After updating the JSFX files, restart REAPER (or reload the project) so
  existing instances pick up the new engine.
- Keep row tracks directly under the PadLab folder (don't drag other tracks in
  between).
- Max 64 samples per row (one RS5K each).
- If GUI pad clicks don't make sound, check the PadLab parent track is still
  record-armed with monitoring on, and that the virtual MIDI keyboard device
  isn't disabled in Preferences → MIDI Inputs.
