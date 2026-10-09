local here = arg[0]:match("^(.*)/[^/]+$") or "."
local H = dofile(here .. "/harness.lua")
local C = dofile(here .. "/../PStarryCore.lua")

-- pageFor: factory banks
H.eq(C.pageFor(36), 36, "pageFor: first pad of bank A")
H.eq(C.pageFor(51), 36, "pageFor: last pad of bank A")
H.eq(C.pageFor(52), 52, "pageFor: first pad of bank B")
H.eq(C.pageFor(67), 52, "pageFor: last pad of bank B")
H.eq(C.pageFor(68), 68, "pageFor: bank C")
H.eq(C.pageFor(127), 116, "pageFor: top note stays on a 16-note page")
H.eq(C.pageFor(35), nil, "pageFor: below bank A is ignored")
H.eq(C.pageFor(128), nil, "pageFor: out of MIDI range")
H.eq(C.pageFor(nil), nil, "pageFor: nil note")
H.eq(C.pageFor(40, 0, 16), 32, "pageFor: custom base")
H.eq(C.pageFor(40, 36, 8), 36, "pageFor: custom bank size")
H.eq(C.pageFor(45, 36, 8), 44, "pageFor: custom bank size second bank")
H.eq(C.pageFor(40, 36, 0), nil, "pageFor: zero bank size refuses")

-- bankName
H.eq(C.bankName(36), "A", "bankName: A")
H.eq(C.bankName(52), "B", "bankName: B")
H.eq(C.bankName(68), "C", "bankName: C")
H.eq(C.bankName(20), "20", "bankName: below base falls back to the note")

-- nameMatches
H.eq(C.nameMatches("  - STARRYPAD", "starrypad"), true, "nameMatches: CoreMIDI name with leading junk")
H.eq(C.nameMatches("Alesis - V49 - In", "starrypad"), false, "nameMatches: other device")
H.eq(C.nameMatches(nil, "starrypad"), false, "nameMatches: nil name")
H.eq(C.nameMatches("STARRYPAD", ""), false, "nameMatches: empty pattern never matches everything")
H.eq(C.nameMatches("a.b", "."), true, "nameMatches: pattern is plain text, not a lua pattern")
H.eq(C.nameMatches("ab", "."), false, "nameMatches: dot is literal")

-- recInput round trip
H.eq(C.recInput(6, 0), 4096 + (6 << 5), "recInput: device 6 all channels")
H.eq(C.recInput(6, 10), 4096 + 10 + (6 << 5), "recInput: channel 10")
H.eq(C.recInputDevice(C.recInput(6, 0)), 6, "recInputDevice: round trip")
H.eq(C.recInputDevice(C.recInput(63, 0)), C.ALL_INPUTS, "recInputDevice: all inputs")
H.eq(C.recInputDevice(0), nil, "recInputDevice: audio input")
H.eq(C.recInputDevice(-1), nil, "recInputDevice: no input")

-- newestNoteOn
local function on(n, v) return string.char(0x99, n, v or 100) end
local function off(n) return string.char(0x89, n, 0) end
local function ev(seq, msg, dev) return { seq = seq, msg = msg, dev = dev } end

local note, top
note, top = C.newestNoteOn({}, 6, 0)
H.eq(note, nil, "newestNoteOn: empty buffer")
H.eq(top, 0, "newestNoteOn: empty keeps lastSeq")

note, top = C.newestNoteOn({ ev(12, on(53), 6), ev(11, on(40), 6) }, 6, 0)
H.eq(note, 53, "newestNoteOn: newest wins")
H.eq(top, 12, "newestNoteOn: reports newest seq")

note, top = C.newestNoteOn({ ev(12, off(53), 6), ev(11, on(40), 6) }, 6, 0)
H.eq(note, 40, "newestNoteOn: skips note-off to find the last note-on")

note = C.newestNoteOn({ ev(12, on(53, 0), 6), ev(11, on(40), 6) }, 6, 0)
H.eq(note, 40, "newestNoteOn: velocity 0 is a note-off")

note, top = C.newestNoteOn({ ev(12, on(53), 4), ev(11, on(40), 6) }, 6, 0)
H.eq(note, 40, "newestNoteOn: ignores other devices")
H.eq(top, 12, "newestNoteOn: other devices still advance seq")

note, top = C.newestNoteOn({ ev(12, on(53), 6), ev(11, on(40), 6) }, 6, 12)
H.eq(note, nil, "newestNoteOn: never replays seen events")
H.eq(top, 12, "newestNoteOn: seq unchanged when nothing new")

note = C.newestNoteOn({ ev(13, on(60), 6), ev(12, on(53), 6) }, 6, 12)
H.eq(note, 60, "newestNoteOn: only newer than lastSeq")

note = C.newestNoteOn({ ev(12, on(53), 0x10006) }, 6, 0)
H.eq(note, 53, "newestNoteOn: flag bits above the device index are ignored")

note = C.newestNoteOn({ ev(12, string.char(0xB9, 53, 127), 6) }, 6, 0)
H.eq(note, nil, "newestNoteOn: CC is not a note")

H.report()
