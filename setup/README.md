# Manual setup

## `__startup.lua`

Copy `__startup.lua` to `<REAPER resource path>/Scripts/__startup.lua`.

Find that folder via **Options -> Show REAPER resource path**.

It starts three background watchers when REAPER launches:

- `PietosiKeys_ModeHUD`  -- flashes the active mode on switch
- `PietosiKeys_ViewWatch` -- EDIT mode minimises trackless lanes
- `PietosiPad`            -- the Launchpad MK1 surface

**If you already have a `__startup.lua`**, don't overwrite it -- paste the
contents of this one into yours instead.

This file is intentionally not a ReaPack package, precisely so installing
the repo can never clobber an existing startup script.
