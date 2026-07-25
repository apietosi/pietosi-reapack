-- @description PietosiKeys Sidechain - one-key sidechain feed for the selected track
-- @version 0.1.0
-- @author pie
-- @provides [main=main] .
-- @about
--   Ported from MixLab's C key. Opens a type-to-filter track picker; Enter
--   creates the sidechain: source track -> channels 3/4 of the SELECTED track
--   (widened to 4 channels if needed), and the focused FX's aux input pins
--   (3rd/4th input) are pointed at those channels (falls back to the first FX
--   in the chain). You still enable the detector/ext-input inside the plugin.
--   Keyboard: type to filter, up/down select, Enter apply, Esc cancel.

local r = reaper

if not r.ImGui_CreateContext then
  r.MB('Needs the ReaImGui extension (install via ReaPack).', 'Sidechain', 0)
  return
end

local target = r.GetSelectedTrack(0, 0)
if not target then
  r.MB('Select the track that should RECEIVE the sidechain first.', 'Sidechain', 0)
  return
end
local _, tname = r.GetTrackName(target)

local ctx = r.ImGui_CreateContext('PietosiSidechain')
local filter, sel, status = '', 1, nil

local function targetFX()
  -- prefer the focused FX if it lives on the target track
  local ok, retval, tridx, _, _, fxidx = pcall(r.GetTouchedOrFocusedFX, 1)
  if ok and retval and fxidx and tridx then
    local tr = r.GetTrack(0, tridx)
    if tr == target and fxidx >= 0 then return fxidx end
  end
  return 0
end

local function apply(src)
  r.Undo_BeginBlock2(0)
  if r.GetMediaTrackInfo_Value(target, 'I_NCHAN') < 4 then
    r.SetMediaTrackInfo_Value(target, 'I_NCHAN', 4)
  end
  r.CreateTrackSend(src, target)
  local ri = r.GetTrackNumSends(target, -1) - 1
  r.SetTrackSendInfo_Value(target, -1, ri, 'I_SRCCHAN', 0)
  r.SetTrackSendInfo_Value(target, -1, ri, 'I_DSTCHAN', 2)

  local _, srcname = r.GetTrackName(src)
  local msg
  if r.TrackFX_GetCount(target) > 0 then
    local fxidx = targetFX()
    local ok, inpins = pcall(function()
      local _, ip = r.TrackFX_GetIOSize(target, fxidx)
      return ip
    end)
    if ok and inpins and inpins >= 4 then
      r.TrackFX_SetPinMappings(target, fxidx, 0, 2, 1 << 2, 0)
      r.TrackFX_SetPinMappings(target, fxidx, 0, 3, 1 << 3, 0)
      local _, fxname = r.TrackFX_GetFXName(target, fxidx, '')
      msg = ('%s -> ch 3/4. %s aux pins set - enable its detector/ext input.'):format(srcname, fxname)
    else
      msg = ('%s -> ch 3/4. FX has no aux input pins - route inside the plugin.'):format(srcname)
    end
  else
    msg = ('%s -> ch 3/4. No FX on the track yet - add one and set its detector.'):format(srcname)
  end
  r.Undo_EndBlock2(0, 'Sidechain: ' .. srcname .. ' -> ' .. tname, -1)
  return msg
end

local function loop()
  r.ImGui_SetNextWindowSize(ctx, 380, 0)
  local visible, open = r.ImGui_Begin(ctx, 'Sidechain into: ' .. tname .. '###PietosiSC', true,
    r.ImGui_WindowFlags_NoCollapse() | r.ImGui_WindowFlags_TopMost() | r.ImGui_WindowFlags_AlwaysAutoResize())
  if visible then
    if status then
      r.ImGui_TextWrapped(ctx, status)
      r.ImGui_Text(ctx, '')
      r.ImGui_TextColored(ctx, 0x8b95a0FF, 'Enter / Esc to close')
      if r.ImGui_IsKeyPressed(ctx, r.ImGui_Key_Enter(), false)
        or r.ImGui_IsKeyPressed(ctx, r.ImGui_Key_Escape(), false) then open = false end
    else
      if r.ImGui_IsWindowAppearing(ctx) then r.ImGui_SetKeyboardFocusHere(ctx) end
      r.ImGui_SetNextItemWidth(ctx, -1)
      local ch, txt = r.ImGui_InputText(ctx, '##filter', filter)
      if ch then filter = txt; sel = 1 end

      local cands = {}
      local fl = filter:lower()
      for i = 0, r.CountTracks(0) - 1 do
        local t = r.GetTrack(0, i)
        if t ~= target then
          local _, nm = r.GetTrackName(t)
          if fl == '' or nm:lower():find(fl, 1, true) then
            cands[#cands + 1] = { t = t, nm = nm, i = i }
          end
        end
      end
      if r.ImGui_IsKeyPressed(ctx, r.ImGui_Key_UpArrow(), true) then sel = sel - 1 end
      if r.ImGui_IsKeyPressed(ctx, r.ImGui_Key_DownArrow(), true) then sel = sel + 1 end
      if sel < 1 then sel = 1 elseif sel > #cands then sel = math.max(1, #cands) end
      local confirm = r.ImGui_IsKeyPressed(ctx, r.ImGui_Key_Enter(), false)
        or r.ImGui_IsKeyPressed(ctx, r.ImGui_Key_KeypadEnter(), false)

      if r.ImGui_BeginChild(ctx, 'list', 0, 220) then
        for k, c in ipairs(cands) do
          if r.ImGui_Selectable(ctx, string.format('%d  %s###c%d', c.i + 1, c.nm, k), sel == k) then
            sel = k
            confirm = true
          end
        end
        r.ImGui_EndChild(ctx)
      end

      if confirm and cands[sel] then
        status = apply(cands[sel].t)
      elseif r.ImGui_IsKeyPressed(ctx, r.ImGui_Key_Escape(), false) then
        open = false
      end
    end
    r.ImGui_End(ctx)
  end
  if open then r.defer(loop) end
end

r.defer(loop)
