# PietosiGlitch

Glitch gadget drawer for hyper-poppy trap metal. Item scripts install to
`Scripts\PietosiGlitch`, JSFX to `Effects\PietosiGlitch`.

## Wheel gadgets (bind to mousewheel gestures, like WheelSplit)

Bind via Actions → select script → Add shortcut → hold a modifier + roll the
wheel. (Reminder: plain Ctrl+wheel overrides zoom.)

| Script | What scrolling does |
|---|---|
| **WheelStutter** | Final beat of the selected item becomes 2/4/8/16/32 repeats of its own first slice. Wheel down relaxes back to clean. |
| **WheelPitchLadder** | Each tick adds ±1 semitone *per slice* across a chopped item (riser up / collapse down). Auto-chops a whole item into 8. Zero restores. |
| **WheelGateChop** | Splits on the grid and mutes in patterns that densify as you scroll: every 8th → 4th → 2nd → 3-of-4 → 7-of-8. Mute-only, fully reversible. |

## One-key item mutations (bind in EDIT mode / anywhere)

| Script | Effect |
|---|---|
| **ShuffleSlices** | Random reorder of selected slices in their span. Re-run = new roll. |
| **ReverseEveryOther** | Toggle take-reverse on every 2nd slice. Run twice to undo. |
| **TapeStopTail** | Bakes a varispeed tape-stop into the last beat (stretch markers + preserve-pitch off). |
| **BuildupMachine** | Last 4 beats become 1/8 repeats → 1/16 → 1/32 → reversed crash. The pre-drop fill, one key. |
| **HalfTimeFlip** | Toggle half playrate, pitch down an octave (preserve-pitch off). The breakdown button. |
| **VocalChopGen** | Grid-chop + random minor-scale pitch per slice, formants preserved. Hyperpop vocal chops from any take. Re-run = new roll. |
| **808GlideWriter** | *(MIDI editor)* Select an 808 note run: first note extends across the phrase, the rest become pitch-bend glides. **Set `BEND_RANGE` in the script to your sampler's bend range (default 24).** |

## JSFX (FX browser → PietosiGlitch)

| FX | What it does |
|---|---|
| **BufferGlitch Pads** | The centerpiece: constantly records the last 8s; MIDI notes from the base note trigger — stutter loops at 4 rates (+0..+3), reverse (+4), half-speed (+5), 16th gate (+6), tape stop (+7). Put it on a bus or the master, point a PadLab row (or any pads) at it, and finger-drum glitches live. Everything releases cleanly on note-off. |
| **KickChokeCrusher** | Bitcrush/downsample driven *inversely* by a kick sidechain on ch 3/4 (MixLab's sidechain key sets that up): clean on the kick, crunchy between hits. |
| **ProbabilityGlitch** | Every 16th rolls dice: stutter / reverse / crush / gate at your probabilities. 10–20% = a track that never glitches the same way twice. |
| **LeadDrift** | Morphing lofi multi-FX for piano/leads: wow/flutter → stutter injector → crush (with sides-only mode) → Haas + width → tempo delay with the crusher *inside the feedback loop*. Every module rides MORPH. |
| **808Wrecker** | Sub-safe 808 corroder: below the crossover stays mono + clean (drive/level only, glides intact); above it MORPH destroys — crush, gate patterns (incl. tresillo), noise smear keyed to the attack, tape-dive stutters rolled on transients. |
| **GhostComp** | Granular MIDI comping instrument: always records its input; MIDI notes play polyphonic grain clouds from the last N beats, repitched vs. the Reference note — hold a chord and comp with your own guitar as the oscillator. Freeze pad + Live/Auto-hold/Latch modes. Per-grain pan spray. Set Dry 0 for instrument use. |

## The MORPH engine (LeadDrift / 808Wrecker / GhostComp)

All three share one modulation block, so the glitch amount *evolves through
the song*:

- **MORPH base** is the master macro; every module has a `→ morph %` knob
  deciding how hard (or negatively, how *inversely*) it responds.
- **LFO**: tempo-synced, period up to **256 beats (64 bars)** — set a 64-bar
  Ramp or Drift and the sound decomposes across the arrangement. Shapes:
  Sine / Triangle / Ramp / Square / S&H / Drift (slow random walk, never
  repeats). Free-runs at the project tempo when stopped, bar-locked when
  playing.
- **Sidechain → MORPH**: kick on ch 3/4 (MixLab's sidechain key), positive =
  glitch spikes on hits, negative = glitch ducks out of the kick's way.
- MORPH base is still a normal slider — automate it by hand any time.

## Notes

- All item gadgets: one undo step per invocation, and they operate per
  *contiguous selection group*, so multi-track selections stay phase-sane.
- Wheel gadgets remember their state per item-span for 30 s, so scroll
  up/down freely; walk away and they start fresh.
- BufferGlitch/ProbabilityGlitch follow the project tempo live.
