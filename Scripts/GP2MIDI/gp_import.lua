-- @description gp_import
-- @version 1.0.0
-- @author pie
-- @provides
--   [main=main] .
--   gp_clean.py
--[[
  Import Guitar Pro tab as clean MIDI stems
  ----------------------------------------------------------------------------
  Pick a .gp5/.gp4/.gp3 file; this runs the Python converter (gp_clean.py),
  which strips every pitch-distorting / note-dropping technique, then drops
  each instrument stem onto its own named track aligned to project start.

  Requires: Python 3.x with `pyguitarpro` and `mido` installed.
            (pip install pyguitarpro mido)

  If your Python lives elsewhere, edit PYTHON_EXE below.
--]]

-- ==== config =================================================================
-- Leave blank to auto-detect. If detection fails, the script asks once and
-- remembers your answer per machine -- so the Windows PC and the Mac can each
-- keep their own interpreter without editing this file.
local PYTHON_EXE = ""
-- =============================================================================

local function python_works(exe)
  if not exe or exe == "" then return false end
  local out = reaper.ExecProcess(string.format('"%s" -c "import sys;print(1)"', exe), 5000)
  return out ~= nil and out:match("1")
end

local function resolve_python()
  if PYTHON_EXE ~= "" then return PYTHON_EXE end

  local saved = reaper.GetExtState("GP2MIDI", "python")
  if python_works(saved) then return saved end

  -- macOS/Linux put python3 on PATH; Windows installs expose "python".
  for _, cand in ipairs({ "python3", "python", "/usr/bin/python3",
                          "/usr/local/bin/python3", "/opt/homebrew/bin/python3" }) do
    if python_works(cand) then
      reaper.SetExtState("GP2MIDI", "python", cand, true)
      return cand
    end
  end

  local ok, chosen = reaper.GetUserFileNameForRead("", "Locate your Python 3 executable", "")
  if ok and python_works(chosen) then
    reaper.SetExtState("GP2MIDI", "python", chosen, true)
    return chosen
  end
  return nil
end

local function msg(s) reaper.ShowConsoleMsg(tostring(s) .. "\n") end

local sep    = package.config:sub(1, 1)               -- "\" on Windows
local src    = debug.getinfo(1, "S").source:sub(2)
local script_dir = src:match("^(.*[/\\])") or ".\\"
local converter  = script_dir .. "gp_clean.py"

-- 1) pick the tab ------------------------------------------------------------
local ok, gp_path = reaper.GetUserFileNameForRead("", "Choose a Guitar Pro tab", "gp5")
if not ok then return end

-- 2) output dir in the system temp -------------------------------------------
local tmp = os.getenv("TMPDIR") or os.getenv("TEMP") or os.getenv("TMP") or "/tmp"
local stem = gp_path:match("[^/\\]+$"):gsub("%.%w+$", "")
local outdir = tmp .. sep .. "gp2reaper" .. sep .. stem

-- 3) run the converter, capture manifest -------------------------------------
local PY = resolve_python()
if not PY then
  reaper.MB("No working Python 3 found.\n\nInstall Python 3 and the deps:\npip install pyguitarpro mido", "GP2MIDI", 0)
  return
end

local cmd = string.format('"%s" "%s" "%s" "%s"', PY, converter, gp_path, outdir)
local out = reaper.ExecProcess(cmd, 120000)   -- 120s timeout
if out == nil then
  reaper.MB("Could not launch Python.\n\nTried:\n" .. tostring(PY) ..
            "\n\nEdit PYTHON_EXE at the top of gp_import.lua.", "GP2MIDI", 0)
  return
end

-- ExecProcess returns "<exitcode>\n<combined output>"
local exitcode = tonumber(out:match("^(%-?%d+)")) or -1
local body = out:gsub("^%-?%d+\n", "")

if exitcode ~= 0 then
  reaper.MB("Converter failed (exit " .. exitcode .. "):\n\n" .. body, "GP2MIDI", 0)
  return
end

-- 4) parse manifest: STEM<TAB>label<TAB>path ---------------------------------
local stems = {}
for line in body:gmatch("[^\r\n]+") do
  local kind, label, path = line:match("^(%u+)\t([^\t]+)\t(.+)$")
  if kind == "STEM" then stems[#stems + 1] = { label = label, path = path } end
end

if #stems == 0 then
  reaper.MB("No instrument stems were produced from:\n" .. gp_path, "GP2MIDI", 0)
  return
end

-- 5) import each stem onto its own track at project start ---------------------
reaper.Undo_BeginBlock()
reaper.PreventUIRefresh(1)

for _, s in ipairs(stems) do
  reaper.SetEditCurPos(0, false, false)          -- align every stem to 0
  local before = reaper.CountTracks(0)
  reaper.InsertMedia(s.path, 1)                   -- mode 1 = add to NEW track
  local after = reaper.CountTracks(0)
  if after > before then
    local tr = reaper.GetTrack(0, after - 1)
    reaper.GetSetMediaTrackInfo_String(tr, "P_NAME", s.label, true)
  end
end

reaper.SetEditCurPos(0, false, false)
reaper.PreventUIRefresh(-1)
reaper.TrackList_AdjustWindows(false)
reaper.UpdateArrange()
reaper.Undo_EndBlock("Import Guitar Pro tab as clean MIDI stems", -1)

reaper.MB(string.format("Imported %d stem(s) from:\n%s\n\n%s",
          #stems, stem, table.concat((function()
            local t = {} for _, s in ipairs(stems) do t[#t+1] = "  - " .. s.label end return t
          end)(), "\n")), "GP2MIDI", 0)
