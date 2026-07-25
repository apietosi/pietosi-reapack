-- @description PietosiKeys SendDestPrev - cycle last send's destination channels down
-- @version 0.1.0
-- @author pie
-- @provides [main=main] .
-- @about Counterpart to SendDestNext (MixLab's [ key): previous channel pair.

local r = reaper
local DIR = -1

local tr = r.GetSelectedTrack(0, 0)
if not tr then return end
local ns = r.GetTrackNumSends(tr, 0)
local x, y = r.GetMousePosition()
if ns == 0 then
  r.TrackCtl_SetToolTip('no sends on this track', x, y + 20, true)
  return
end

local i = ns - 1
local cur = r.GetTrackSendInfo_Value(tr, 0, i, 'I_DSTCHAN')
if cur < 0 then cur = 0 end
local new = (math.floor(cur) + DIR * 2) % 8
if new < 0 then new = new + 8 end

if r.APIExists('BR_GetMediaTrackSendInfo_Track') then
  local dst = r.BR_GetMediaTrackSendInfo_Track(tr, 0, i, 1)
  if dst and r.GetMediaTrackInfo_Value(dst, 'I_NCHAN') < new + 2 then
    r.SetMediaTrackInfo_Value(dst, 'I_NCHAN', new + 2)
  end
end
r.SetTrackSendInfo_Value(tr, 0, i, 'I_DSTCHAN', new)

local hwn = r.GetTrackNumSends(tr, 1)
local _, nm = r.GetTrackSendName(tr, hwn + i, '')
r.TrackCtl_SetToolTip(('send "%s"  ->  %d/%d'):format(nm, new + 1, new + 2), x, y + 20, true)
