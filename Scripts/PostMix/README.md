# PostMix Toolkit for REAPER

Fast mixing helpers for stem sessions — instruments **and** vocals.

---

## Install locations

| What | Path |
|------|------|
| JSFX | `%APPDATA%\REAPER\Effects\PostMix\` |
| Scripts | `%APPDATA%\REAPER\Scripts\PostMix\` |
| Track templates | `%APPDATA%\REAPER\TrackTemplates\` |
| FX chains | `%APPDATA%\REAPER\FXChains\PostMix\` |

**Restart REAPER** (or re-scan JS) after adding plugins.

### Register scripts (once)

**Actions → Show action list → Load ReaScript…**

| Script | Use |
|--------|-----|
| `PostMix_Apply_Instrument_Strips.lua` | Instruments only (skips vox) |
| `PostMix_Apply_Vocal_Strips.lua` | Vocals only |
| `PostMix_Wire_Kick_to_808_Duck.lua` | Kick → 808 sidechain |
| `PostMix_Solo_EQ_Helper.lua` | Solo + Smart Strip |
| `PostMix_Solo_Vocal_Helper.lua` | Solo + Vocal Strip UI |
| `PostMix_Apply_SmartStrip_By_Name.lua` | All tracks (legacy Smart Strip) |

---

## Vocal JSFX *(new)*

### PostMix Vocal Strip
One-plugin vocal channel:

| Control | Purpose |
|---------|---------|
| **Role** | Lead / Double-Hook / Adlib / Raw-Whisper |
| **Polish %** | Scales EQ character |
| HPF, Mud, Body, Presence, Air | Tone |
| **De-ess %** | Built-in split-band de-ess |
| Soft sat, Mono below | Glue / center lows |
| Preset mode | Auto-load role vs Manual lock |

### PostMix Vocal Comp
Soft-knee vocal compressor: Peak/RMS, SC HPF, auto makeup, dry/wet, light sat.

**Lead starting point:** thresh ~−18, ratio 3:1, aim 3–6 dB GR.

### PostMix De-Esser
Dedicated split-band (or wideband) de-esser with detect/diff listen modes.

**Start:** 6–7 kHz, range 6–10 dB, thresh so GR only on S/T/SH.

---

## Instrument JSFX

| Plugin | Role |
|--------|------|
| Smart Strip | Source EQ (Kick/808/Snare/Hats/Melody/Bus…) |
| Low End | Kick/808 mono, punch, sub weight |
| Kick Duck | Sidechain duck for 808/bass |
| Mud Cut | Low-mid cleanup |
| Bus Glue | Group/bus density |
| Gain Stage | Peak/RMS, target, auto-trim |

---

## Track templates

### Vocals
| Template | Chain |
|----------|--------|
| **PostMix Lead Vocal** | Vocal Strip → Vocal Comp → De-Esser → Gain Stage |
| **PostMix Double Hook** | Same, Double/Hook role + lighter comp |
| **PostMix Adlib** | Same, Adlib role (thinner, more air) |
| **PostMix Vocal Bus** | Smart Strip (Bus) → Bus Glue → De-Esser → Gain Stage |

### Instruments
Kick · 808 · Snare · Hats · Melody · Drum Bus  
(see earlier PostMix templates)

Same chains under **FX → FX chains → PostMix**.

---

## Vocal workflow

1. Name tracks clearly:
   - `Lead Vox`, `Verse Vox`, `Yanno`
   - `Hook`, `Double`, `Harmony`
   - `Adlib`, `Hype`, `Tag`
2. Run **Apply vocal strips** (or insert templates / FX chains)
3. Balance faders against the beat first
4. **Solo Vocal Helper** on problem lines → set Role + Polish
5. When happy: Vocal Strip → **Manual** (locks role reload)
6. Fine-tune **De-Esser** if S’s still poke (Listen detect)
7. Vocal bus: light **Bus Glue** + optional bus De-Esser
8. Gain Stage target ~**−12 dB peak** on tracks, **−6 dB** on bus

### Name → role mapping

| Name contains | Role |
|---------------|------|
| whisper, raw, talk, spoken | Raw/Whisper |
| adlib, yell, hype, tag | Adlib |
| double, hook, stack, harm, choir, bgv | Double/Hook |
| vox, vocal, verse, lead, yanno… (default) | Lead |

---

## Full mix order (typical)

1. **Apply instrument strips** + **Wire Kick→808**
2. **Apply vocal strips**
3. Fader balance
4. Polish instruments, then vocals
5. Drum bus / vocal bus glue
6. Master as usual

---

## Starting ranges (vocals)

| Part | Polish | Comp GR | De-ess |
|------|--------|---------|--------|
| Lead | 45–70% | 3–6 dB | as needed |
| Double/Hook | 40–60% | 2–4 dB | slightly more |
| Adlib | 40–65% | 1–3 dB | watch air band |
| Whisper/Raw | 25–45% | gentle | light |

---

## Notes

- Vocal Strip already de-esses lightly; the extra **De-Esser** is for surgical control.
- Auto-load on Vocal Strip rewrites EQ when Role/Polish change — use **Manual** after dialing.
- All tools are starting points; finish by ear.
