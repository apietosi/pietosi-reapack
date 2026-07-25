-- @description PietosiKeys ModeHUD - flash the active key-mode on switch
-- @version 0.2.0
-- @author pie
-- @provides [main=main] .
-- @about
--   Background watcher for the PietosiKeys layers. Whenever the main-section
--   override changes (stock / MIX alt-1 / EDIT alt-2 / REC alt-3 / AUTO alt-4)
--   it flashes the mode name in large text near the top of the REAPER window,
--   fading out after about a second. Click-through, no interaction.
--   v0.2: also flashes the grid division (GRID 1/16, 1/8T, 1/8. ...) whenever
--   it changes - pairs with the Num +/-/*// grid keys.
--   Auto-started from Scripts/__startup.lua.

local r = reaper

if not r.ImGui_CreateContext then return end
if not r.APIExists('CF_EnumerateActions') then return end

-- resolve the "toggle override to alt-N" actions by name (never hardcode ids)
local toggles = {} -- { {cmd=..., name='MIX'}, ... }
do
  local want = {
    ['alt-1'] = 'MIX',
    ['alt-2'] = 'EDIT',
    ['alt-3'] = 'REC',
    ['alt-4'] = 'AUTO',
  }
  for i = 0, 200000 do
    local cmd, name = r.CF_EnumerateActions(0, i, '')
    if not cmd or cmd <= 0 then break end
    local l = (name or ''):lower()
    if l:find('main action section', 1, true) and l:find('toggle', 1, true) then
      for tag, label in pairs(want) do
        if l:find(tag, 1, true) then
          toggles[#toggles + 1] = { cmd = cmd, name = label }
        end
      end
    end
  end
end
if #toggles == 0 then return end

local COLORS = {
  MIX   = 0x53E06AFF,
  EDIT  = 0xFFD24AFF,
  REC   = 0xE05353FF,
  AUTO  = 0x5AA7E0FF,
  STOCK = 0xB8B8B8FF,
}

local FLASH_LEN = 1.15 -- seconds
local last_mode = nil  -- nil = not read yet (no flash on script start)
local last_grid = nil
local flash_t0, flash_mode, flash_text = nil, nil, nil
local ctx, font = nil, nil

-- grid division (fraction of a whole note) -> musician-readable label
local function gridLabel(d)
  if not d or d <= 0 then return '?' end
  local function close(a, b) return math.abs(a - b) < b * 1e-6 end
  for n = 1, 256 do
    if close(d, 1 / n) then return '1/' .. n end
    if close(d, 2 / (3 * n)) then return '1/' .. n .. 'T' end
    if close(d, 3 / (2 * n)) then return '1/' .. n .. '.' end
  end
  for m = 2, 16 do
    if close(d, m) then return m .. '/1' end
  end
  return string.format('%.3f', d)
end

local function currentMode()
  for _, t in ipairs(toggles) do
    if r.GetToggleCommandState(t.cmd) == 1 then return t.name end
  end
  return 'STOCK'
end

local function drawFlash()
  if not ctx or not r.ImGui_ValidatePtr(ctx, 'ImGui_Context*') then
    ctx = r.ImGui_CreateContext('PietosiModeHUD')
    -- ReaImGui <=0.9: CreateFont(family, size); 0.10+: CreateFont(family[, flags])
    local ok
    ok, font = pcall(r.ImGui_CreateFont, 'sans-serif', 44)
    if not ok or not font then
      ok, font = pcall(r.ImGui_CreateFont, 'sans-serif', 0)
      if not ok then font = nil end
    end
    if font then pcall(r.ImGui_Attach, ctx, font) end
  end

  local age = os.clock() - flash_t0
  local fade = 1 - math.max(0, (age - 0.45) / (FLASH_LEN - 0.45))
  if fade <= 0 then flash_t0 = nil return end

  local vp = r.ImGui_GetMainViewport(ctx)
  local wx, wy = r.ImGui_Viewport_GetWorkPos(vp)
  local ww = select(1, r.ImGui_Viewport_GetWorkSize(vp))
  r.ImGui_SetNextWindowPos(ctx, wx + ww / 2, wy + 80, r.ImGui_Cond_Always(), 0.5, 0)
  r.ImGui_SetNextWindowBgAlpha(ctx, 0.72 * fade)

  local flags = r.ImGui_WindowFlags_NoDecoration()
    | r.ImGui_WindowFlags_NoInputs()
    | r.ImGui_WindowFlags_NoMove()
    | r.ImGui_WindowFlags_NoSavedSettings()
    | r.ImGui_WindowFlags_AlwaysAutoResize()
    | r.ImGui_WindowFlags_NoDocking()
    | r.ImGui_WindowFlags_NoFocusOnAppearing()
    | r.ImGui_WindowFlags_TopMost()

  local col = COLORS[flash_mode] or 0xFFFFFFFF
  local a = math.floor(0xFF * fade)
  if r.ImGui_Begin(ctx, '##PietosiModeHUD', false, flags) then
    -- ReaImGui 0.10+: PushFont(ctx, font, size); <=0.9: PushFont(ctx, font)
    local pushed = false
    if font then
      pushed = pcall(r.ImGui_PushFont, ctx, font, 44)
      if not pushed then pushed = pcall(r.ImGui_PushFont, ctx, font) end
    end
    r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Text(), (col & ~0xFF) | a)
    r.ImGui_Text(ctx, '  ' .. (flash_text or flash_mode) .. '  ')
    r.ImGui_PopStyleColor(ctx)
    if pushed then r.ImGui_PopFont(ctx) end
    r.ImGui_End(ctx)
  end
end

local function loop()
  local mode = currentMode()
  if last_mode == nil then
    last_mode = mode -- baseline; don't flash on startup
  elseif mode ~= last_mode then
    last_mode = mode
    flash_mode = mode
    flash_text = nil
    flash_t0 = os.clock()
  end

  local _, div = r.GetSetProjectGrid(0, false)
  if last_grid == nil then
    last_grid = div -- baseline; don't flash on startup
  elseif div ~= last_grid then
    last_grid = div
    flash_mode = 'GRID' -- no COLORS entry -> neutral white
    flash_text = 'GRID ' .. gridLabel(div)
    flash_t0 = os.clock()
  end

  if flash_t0 then
    local ok = pcall(drawFlash)
    if not ok then flash_t0 = nil end
  else
    ctx = nil -- idle: no ImGui calls, context is released automatically
  end

  r.defer(loop)
end

r.defer(loop)
