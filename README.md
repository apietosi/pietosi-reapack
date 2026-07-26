# pietosi-reapack

Custom REAPER workflow: grid-aware glitch tools, a Launchpad MK1 control surface with live LED feedback, a mixing/pad workspace, and a JSFX rack.

Installable via **ReaPack** — one URL gets the whole rig onto any machine.

---

## Install

**1. Install the dependencies first.** Several tools won't load without these. All are available through ReaPack's default ReaTeam repositories, except SWS:

| Dependency | Needed by | Where |
|---|---|---|
| **SWS / S&M** | 12 scripts — PietosiPad, PietosiKeys, MixLab, ShotSwap, PGlitchLib | [sws-extension.org](https://www.sws-extension.org/) |
| **ReaImGui** | 6 scripts — MixLab, PadLab, PietosiQuantize, ShotSwap, ModeHUD, Sidechain | ReaPack → ReaTeam Extensions |
| **js_ReaScriptAPI** | PadLab, and the hat RR folder picker | ReaPack → ReaTeam Extensions |

**2. Add this repository.** Extensions → ReaPack → Import a repository:

```
https://github.com/apietosi/pietosi-reapack/raw/main/index.xml
```

**3. Browse packages**, filter for `Pietosi`, install what you want.

> Replace `YOUR-USERNAME`. The URL goes live once you've pushed and the Actions run has generated `index.xml`.

Optional extras: **Python 3** with `pyguitarpro` and `mido` for GP2MIDI (`pip install pyguitarpro mido`), and a Launchpad MK1 for PietosiPad.

---

## What's in here

### PietosiGlitch — grid-aware mangling
`ShuffleSlices` · `ReverseEveryOther` · `TapeStopTail` · `BuildupMachine` · `HalfTimeFlip` · `VocalChopGen` · `808GlideWriter` (MIDI editor) · three wheel gadgets: `WheelStutter`, `WheelPitchLadder`, `WheelGateChop` · shared `PGlitchLib`

The grid is the flavour knob — same action at 1/4 is chunky, at 1/32 it's a granular smear.

### PietosiPad — Launchpad MK1 surface
Four mode pages (MIX / EDIT / REC / AUTO) with live LED state. Pad input is **polled, never routed**, so the Launchpad never records notes and never touches your keymap. LEDs go out over `gmem` → `PietosiPad_Bridge.jsfx` → MIDI hardware out.

Device matching is a case-insensitive substring on `"launchpad"`, so it finds the device on both Windows and macOS without editing anything.

### PietosiKeys — keymap builder and view watchers
`Build` (generates the keymap) · `ModeHUD` · `ViewWatch` · `Sidechain` · send-destination cycling · three view scripts (Playlist / Mixer / MIDI)

### PietosiRudiments — MIDI editor
Nine rudiments (single & double stroke rolls, paradiddles, paradiddle-diddle, flam tap, flamadiddle, single drag tap, flam accent) over a shared `Core`.

### PietosiUtils
`PietosiShotSwap` — rerolls every item's sample from a Media Explorer database, no repeats until the pool runs out · `PietosiWheelSplit` · smart cursor left/right (grid if snap on, else pixel)

### MixLab / PadLab
`MixLab` — unified vertical arranger + mixer with the grid overlay. `PadLab` — pad-style drum sampler, with `Router` / `NoteRepeat` / `Monitor` JSFX.

### PostMix
Instrument and vocal strip appliers, smart-strip-by-name, solo EQ/vocal helpers, kick→808 duck wiring.

### JSFX rack
`BufferGlitch` · `KickChokeCrusher` · `ProbabilityGlitch` · `808Wrecker` · `LeadDrift` · `GhostComp` — each with a MORPH macro, tempo-synced LFO, and sidechain-to-morph.

### Also
`GP2MIDI` — Guitar Pro tab → clean MIDI stems (needs Python) · `TransientGridAlign` · `PietosiQuantize`

---

## Setup that ReaPack can't do for you

### `__startup.lua`

`setup/__startup.lua` launches the three background watchers (`ModeHUD`, `ViewWatch`, `PietosiPad`) when REAPER starts.

It is **deliberately not a ReaPack package**, because it must live at exactly `<resource>/Scripts/__startup.lua` and installing it would clobber any startup script already there. Copy it manually — or if you already have one, paste its contents into yours.

Find your resource folder via **Options → Show REAPER resource path**.

### ShotSwap needs a sample database

ShotSwap reads Media Explorer databases from `<resource>/MediaDB/*.ReaperFileList`. Those files contain **absolute paths**, so they don't transfer between machines.

On a new machine: copy your sample library over, then in Media Explorer add the folder as a database and let it scan. Until you do, ShotSwap runs and swaps nothing — it isn't broken, the pool is just empty.

### Per-machine paths, handled automatically

Two scripts used to hardcode Windows paths. They now detect and remember instead, so each machine keeps its own answer:

- **`Pietosi_HatRandomRR_LoadRS5K`** — asks once for your hat round-robin folder, then remembers it. Files are used in sorted order, so `rr0_`, `rr1_`, `rr2_`… keeps each sample on a predictable note (60, 61, 62…).
- **`GP2MIDI/gp_import`** — auto-detects `python3` / `python`, falls back to asking. Also uses `TMPDIR` on macOS.

---

## Updating

Edit a file, **bump its `@version`**, commit, push. The GitHub Action regenerates `index.xml` and your other machines see the update in ReaPack.

Forgetting the version bump is the one failure mode — ReaPack decides "is there an update" purely from that number, so an edit without a bump is invisible. See `SCRIPT-HEADERS.md`.

---

## Notes

- **JSFX are plain text**, compiled by REAPER at load. The whole rack runs natively on Apple Silicon with nothing to rebuild.
- **Don't commit `reaper.ini` or `reaper-kb.ini`** — both are in `.gitignore`. `reaper.ini` is machine-specific (audio device, plugin paths, MIDI indices). `reaper-kb.ini` mixes keybindings, custom actions and script registrations into one file, so syncing it silently overwrites the other machine's keymap.
- **JSFX presets** live in `<resource>/presets/`, separate from the JSFX. Not tracked here — copy that folder manually if you want your dialled-in settings to travel.
