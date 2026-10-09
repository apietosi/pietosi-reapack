-- @description PietosiKeys - mirror the Main numpad grid keys into the MIDI editor
-- @version 0.1.0
-- @author pie
-- @provides [main=main] .
-- @about
--   The MIDI editor has its own action section (32060), so the numpad grid
--   keys bound in Main never reach it. This resolves the MIDI-editor
--   equivalents BY NAME on this machine and writes a minimal keymap
--   containing only those six bindings - nothing else is touched.
--
--   Main uses  "Grid: Adjust by X"
--   MIDI uses  "Grid: Multiply grid size by X"
--
--   Run this, then: Actions window > Key map... (bottom left) >
--   Import... > KeyMaps/PietosiKeys_MidiGrid.ReaperKeyMap

local r = reaper

if not r.APIExists('CF_EnumerateActions') then
  r.MB('This needs the SWS extension (CF_EnumerateActions).', 'PietosiKeys MidiGrid', 0)
  return
end

local function log(s) r.ShowConsoleMsg(s .. '\n') end
r.ClearConsole()
log('PietosiKeys - MIDI grid match v0.1')
log('==================================')

local MIDI_SEC = 32060

local function scanSection(section)
  local t = {}
  for i = 0, 200000 do
    local cmd, name = r.CF_EnumerateActions(section, i, '')
    if not cmd or cmd <= 0 then break end
    t[#t + 1] = { cmd = cmd, name = name, l = (name or ''):lower() }
  end
  return t
end

local midiacts = scanSection(MIDI_SEC)
log(('scanned %d MIDI editor actions'):format(#midiacts))

local unresolved = {}
local function resolve(label, patternsets)
  for _, set in ipairs(patternsets) do
    if #set == 1 then
      for _, a in ipairs(midiacts) do
        if a.l == set[1] then return a end
      end
    end
    local best
    for _, a in ipairs(midiacts) do
      local ok = true
      for _, p in ipairs(set) do
        if not a.l:find(p, 1, true) then ok = false break end
      end
      if ok then best = best or a end
    end
    if best then return best end
  end
  unresolved[#unresolved + 1] = label
  return nil
end

-- vk, label, and the name patterns to try in order.
-- Main "Adjust by N" == MIDI "Multiply grid size by N".
local MOD = 1 -- same modifier flag the Main numpad bindings use

local MAP = {
  { vk = 96,  key = 'NumPad 0', main = 'Grid: Adjust by 1/1.5',
    pats = { { 'multiply grid size by 1/1.5' }, { 'grid', 'adjust by 1/1.5' }, { 'grid', '1/1.5' } } },
  { vk = 107, key = 'NumPad +', main = 'Grid: Adjust by 1/2',
    pats = { { 'multiply grid size by 1/2' }, { 'grid', 'adjust by 1/2' }, { 'grid', '1/2' } } },
  { vk = 111, key = 'NumPad /', main = 'Grid: Adjust by 1/3',
    pats = { { 'multiply grid size by 1/3' }, { 'grid', 'adjust by 1/3' }, { 'grid', '1/3' } } },
  { vk = 110, key = 'NumPad .', main = 'Grid: Adjust by 1.5',
    pats = { { 'multiply grid size by 1.5' }, { 'grid', 'adjust by 1.5' } } },
  { vk = 109, key = 'NumPad -', main = 'Grid: Adjust by 2',
    pats = { { 'multiply grid size by 2' }, { 'grid', 'adjust by 2' } } },
  { vk = 106, key = 'NumPad *', main = 'Grid: Adjust by 3',
    pats = { { 'multiply grid size by 3' }, { 'grid', 'adjust by 3' } } },
}

local out = {}
log('')
log('key         main action                  -> MIDI editor action (cmd)')
log('---------------------------------------------------------------------')

for _, m in ipairs(MAP) do
  local a = resolve(m.key .. ' / ' .. m.main, m.pats)
  if a then
    out[#out + 1] = ('KEY %d %d %d %d'):format(MOD, m.vk, a.cmd, MIDI_SEC)
    log(('%-11s %-28s -> %s (%d)'):format(m.key, m.main, a.name, a.cmd))
  else
    log(('%-11s %-28s -> NOT FOUND'):format(m.key, m.main))
  end
end

------------------------------------------------------------------ write out

local dir = r.GetResourcePath() .. '/KeyMaps'
r.RecursiveCreateDirectory(dir, 0)
local path = dir .. '/PietosiKeys_MidiGrid.ReaperKeyMap'
local fh = io.open(path, 'wb')
if not fh then
  r.MB('Could not write ' .. path, 'PietosiKeys MidiGrid', 0)
  return
end
fh:write(table.concat(out, '\n') .. '\n')
fh:close()

log('')
log(('wrote %d binding(s):'):format(#out))
log('  ' .. path)
if #unresolved > 0 then
  log('')
  log('unresolved (bind these by hand in the MIDI Editor section):')
  for _, u in ipairs(unresolved) do log('  - ' .. u) end
end
log('')
log('next: Actions window > Key map... > Import... > PietosiKeys_MidiGrid.ReaperKeyMap')
