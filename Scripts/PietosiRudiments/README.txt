PIETOSI RUDIMENTS for REAPER
============================
Numpad-powered drum rudiment programming for the MIDI editor.

WHAT IT DOES
------------
Select some notes (or make a time selection) in the MIDI editor,
hit a numpad key, and that region fills with a properly-played
rudiment: correct sticking velocities, accents, flams, and drags,
following your current grid setting (16ths, triplets, whatever).


INSTALL (5 minutes, one time)
-----------------------------
1. Open REAPER. Go to:  Options > Show REAPER resource path in
   explorer/finder. A folder window opens.

2. Open the "Scripts" folder inside it.

3. Copy the whole "PietosiRudiments" folder into "Scripts".

4. Back in REAPER, open any MIDI item so the MIDI editor is showing.

5. In the MIDI editor menu:  Actions > Show action list.

6. IMPORTANT: at the top of the Action List, set the "Section"
   dropdown to "MIDI Editor" (not "Main"). This is what makes the
   numpad keys work while you're editing MIDI.

7. Click "New action..." > "Load ReaScript...". Navigate into
   Scripts/PietosiRudiments and select ALL NINE "Rudiment ..." files
   at once (click the first, shift-click the last). Click Open.
   (Do NOT load PietosiRudiments_Core.lua - it's the engine the
   others use.)

8. Now bind the keys. In the action list, find "Rudiment 1 - Single
   Stroke Roll", click it, then click "Add..." under Shortcuts,
   and press Numpad 1. If REAPER says the key is already used,
   choose "Override". Repeat for 2 through 9.

Done. Close the action list.


HOW TO USE
----------
In the MIDI editor:
  - Select the notes you want to replace (they set the region AND
    which drum/pitch gets used), or just make a time selection
    (defaults to snare, note 38).
  - Set your grid to the subdivision you want (16th notes is the
    classic rudiment feel).
  - Hit a numpad key. Boom.
  - Ctrl+Z undoes it like anything else.

DEFAULT LAYOUT
--------------
  Numpad 1  Single Stroke Roll
  Numpad 2  Double Stroke Roll
  Numpad 3  Single Paradiddle
  Numpad 4  Double Paradiddle
  Numpad 5  Paradiddle-Diddle
  Numpad 6  Flam Tap
  Numpad 7  Flamadiddle
  Numpad 8  Single Drag Tap
  Numpad 9  Flam Accent


CUSTOMIZING (no coding needed, just careful typing)
---------------------------------------------------
Open PietosiRudiments_Core.lua in any text editor (Notepad works).

* The SETTINGS block at the top controls velocities, flam spacing,
  note length, and humanization. Change the numbers, save, done.

* The RUDIMENTS block defines every pattern. Each stroke looks like:
      {h="R"}                  right hand tap
      {h="L", a=true}          accented left hand
      {h="R", a=true, g=1}     accented right with a flam
      {h="L", g=2}             left hand with a drag
  Copy an existing rudiment, rename it, change the strokes, and
  make a copy of any "Rudiment ..." file that calls your new name
  in its last line. Load that file in the action list like before.

* Want a different rudiment on a numpad key? Just change which
  script the key is bound to in the action list - no file editing.


TROUBLESHOOTING
---------------
"Nothing happens when I press the key"
  -> The action list Section was probably set to "Main" when you
     bound the shortcut. Redo step 6-8 with "MIDI Editor" selected.

"Open a MIDI editor first"
  -> The script only works inside the MIDI editor, not the arrange
     view.

"Select some notes, or make a time selection first"
  -> It needs to know where to put the rudiment.
