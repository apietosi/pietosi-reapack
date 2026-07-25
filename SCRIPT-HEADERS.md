# Metadata headers

The GitHub Action reads these headers to build `index.xml`. **A file with no `@version` is skipped entirely** — that's the one mistake that makes a package silently fail to appear in ReaPack.

You don't need to understand the XML. You just need these comment lines at the very top of each file.

---

## For a Lua script (`Scripts/Pietosi/*.lua`)

Comment lines start with `--`:

```lua
-- @description PietosiWheelStutter
-- @version 1.0.0
-- @author pie
-- @provides [main=main] .
-- @changelog
--   Initial release.
-- @about
--   One-line summary of what it does, shown in ReaPack's package browser.
```

## For a JSFX effect (`Effects/Pietosi/*`)

JSFX comment lines start with `//`, and the effect's own `desc:` line stays where it is:

```
desc: BufferGlitch Pads

// @description BufferGlitch Pads
// @version 1.0.0
// @author pie
// @provides [effect] .
// @changelog
//   Initial release.
// @about
//   8 MIDI pads on a bus: 4 stutter rates, reverse, half-speed, gate,
//   tape-dive. Tempo-synced 8 s ring buffer.
```

---

## The rules that matter

**`@version` must increase** for ReaPack to offer an update. `1.0.0` → `1.0.1` for a fix, `1.1.0` for a new feature. If you edit a file and forget to bump this, your other machine will never see the change — and it'll look like sync is broken when it isn't.

**`@provides`** tells ReaPack what kind of thing this is and where it goes:

| Line | Use for |
|---|---|
| `@provides [main=main] .` | a script that runs from the Actions list (Main section) |
| `@provides [main=midi_editor] .` | a MIDI editor script — your rudiments, 808 glide writer |
| `@provides [main=main,midi_editor] .` | available in both sections |
| `@provides [effect] .` | a JSFX |
| `@provides [nomain] .` | a helper library another script loads, not run directly |

The `.` means "this file itself." If a script needs extra files alongside it, list them on their own indented lines:

```lua
-- @provides
--   [main=main] .
--   Pietosi/grooves/trap.rgt
--   Pietosi/lib/pad_bridge.lua
```

**`@changelog`** shows up in ReaPack when an update is offered. Worth writing honestly — six months from now it's the only record of why something changed.

---

## Section matters for your MIDI editor tools

From your PietosiKeys sheet, these live in the **MIDI editor** section, not Main:

- PietosiRudiments (`Num 1`–`9`)
- 808 Glide Writer (`8`)
- Humanize (`H`), legato (`L`), FNG groove (`G`)

Tag them `[main=midi_editor]` or they'll install into the wrong section and appear unbindable where you actually need them.

---

## Quick check before pushing

- [ ] Every script and JSFX has `@version`
- [ ] `@provides` section matches where you actually use the tool
- [ ] Version bumped on anything you edited
- [ ] Pushed to `main`, and the **Actions** tab shows a green tick
