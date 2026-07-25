# @noindex
#!/usr/bin/env python
"""
gp_clean: convert one Guitar Pro tab (.gp3/.gp4/.gp5) to harmonically clean
MIDI stems, for the REAPER import action (gp_import.lua).

Usage:  python gp_clean.py "<input.gp5>" "<output_dir>"

Writes one MIDI per instrument track plus master.mid into <output_dir>, then
prints a manifest to stdout, one line per file:

    STEM<TAB><label><TAB><abs_path>      (instrument track -> own REAPER track)
    MASTER<TAB>master<TAB><abs_path>     (all tracks together; ignored by Lua)

All pitch-distorting / note-dropping techniques are neutralized so the MIDI is
a literal transcription of the written harmony:
  bend / slide / vibrato / whammy -> no pitch-wheel emitted
  hammer / pull / tapping         -> every note sounds at full velocity
  trill / tremolo-pick / grace    -> collapsed to the written note
  tied notes                      -> folded into the previous note's duration
  dead/muted notes                -> dropped (no real pitch)
  ghost notes                     -> raised to normal velocity
"""
import sys, os, re
import guitarpro as gp
import mido

PPQ = gp.Duration.quarterTime  # 960
DEFAULT_VEL = 95

GM_FAMILY = {
    0: "piano", 1: "chromatic", 2: "organ", 3: "guitar", 4: "bass",
    5: "strings", 6: "ensemble", 7: "brass", 8: "reed", 9: "pipe",
    10: "synth-lead", 11: "synth-pad", 12: "synth-fx", 13: "ethnic",
    14: "percussion", 15: "sfx",
}


def sanitize(name, default):
    name = re.sub(r'[<>:"/\\|?*\x00-\x1f]', "", (name or "")).strip().strip(".")
    return name or default


def stem_label(track, used):
    if track.isPercussionTrack:
        base = "drums"
    else:
        nm = sanitize(track.name, "").lower()
        if not nm or re.match(r"^track[\s_-]*\d+$", nm):
            base = GM_FAMILY.get(track.channel.instrument // 8, "track")
        else:
            base = re.sub(r"\s+", "-", nm)
    label, i = base, 2
    while label in used:
        label, i = f"{base}-{i}", i + 1
    used.add(label)
    return label


def build_track_midi(track):
    ch = 9 if track.isPercussionTrack else (track.channel.channel & 0x0F)
    mt = mido.MidiTrack()
    if not track.isPercussionTrack:
        prog = max(0, min(127, track.channel.instrument))
        mt.append(mido.Message("program_change", channel=ch, program=prog, time=0))

    events, active = [], {}
    measure_start = 0
    for m in track.measures:
        num, den = m.timeSignature.numerator, m.timeSignature.denominator.value
        measure_len = int(round(num * (PPQ * 4 / den)))
        for v in m.voices:
            t = measure_start
            for b in v.beats:
                dur = b.duration.time
                if b.status == gp.BeatStatus.rest or not b.notes:
                    t += dur
                    continue
                for n in b.notes:
                    if n.type == gp.NoteType.dead:
                        continue
                    if n.type == gp.NoteType.tie:
                        off = active.get(n.string)
                        if off is not None:
                            off[0] = t + dur
                            continue
                    pitch = max(0, min(127, n.realValue))
                    vel = DEFAULT_VEL if n.effect.ghostNote else n.velocity
                    vel = max(1, min(127, vel))
                    on = [t, "on", ch, pitch, vel]
                    off = [t + dur, "off", ch, pitch, 0]
                    events += [on, off]
                    active[n.string] = off
                t += dur
        measure_start += measure_len

    events.sort(key=lambda e: (e[0], 0 if e[1] == "off" else 1))
    last = 0
    for tick, kind, c, pitch, vel in events:
        tick = int(round(tick))
        delta, last = tick - last, tick
        mt.append(mido.Message("note_on" if kind == "on" else "note_off",
                               channel=c, note=pitch, velocity=vel, time=delta))
    return mt


def tempo_track(song):
    changes = {0: song.tempo}
    if song.tracks:
        tr = song.tracks[0]
        ms = 0
        for m in tr.measures:
            num, den = m.timeSignature.numerator, m.timeSignature.denominator.value
            mlen = int(round(num * (PPQ * 4 / den)))
            for v in m.voices:
                t = ms
                for b in v.beats:
                    mtc = b.effect.mixTableChange
                    if mtc and mtc.tempo is not None:
                        changes[t] = mtc.tempo.value
                    t += b.duration.time
            ms += mlen
    meta = mido.MidiTrack()
    last = 0
    for tick in sorted(changes):
        itick = int(round(tick))
        meta.append(mido.MetaMessage("set_tempo", tempo=mido.bpm2tempo(changes[tick]),
                                     time=itick - last))
        last = itick
    return meta


def write_midi(path, song, instrument_tracks):
    mid = mido.MidiFile(ticks_per_beat=PPQ)
    mid.tracks.append(tempo_track(song))
    for mt in instrument_tracks:
        mid.tracks.append(mt)
    mid.save(path)


def main(argv):
    if len(argv) < 3:
        print("usage: gp_clean.py <input.gp5> <output_dir>", file=sys.stderr)
        return 2
    src, outdir = argv[1], argv[2]
    os.makedirs(outdir, exist_ok=True)
    song = gp.parse(src)

    built, used = [], set()
    for tr in song.tracks:
        mt = build_track_midi(tr)
        if len(mt) <= (0 if tr.isPercussionTrack else 1):
            continue  # empty track
        label = stem_label(tr, used)
        path = os.path.abspath(os.path.join(outdir, label + ".mid"))
        write_midi(path, song, [mt])
        built.append((label, mt, path))
        print(f"STEM\t{label}\t{path}")

    master = os.path.abspath(os.path.join(outdir, "master.mid"))
    write_midi(master, song, [mt for _, mt, _ in built])
    print(f"MASTER\tmaster\t{master}")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv))
    except Exception as e:
        print(f"ERR\t{type(e).__name__}: {e}", file=sys.stderr)
        sys.exit(1)
