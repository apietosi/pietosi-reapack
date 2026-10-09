-- Minimal assert harness. No dependencies; runs under stock Lua 5.4.
local H = {}
local passed, failed = 0, 0
local failures = {}

local function record(ok, msg)
  if ok then
    passed = passed + 1
  else
    failed = failed + 1
    failures[#failures + 1] = msg
  end
end

function H.eq(actual, expected, label)
  record(actual == expected, string.format(
    "%s: expected %s, got %s", label, tostring(expected), tostring(actual)))
end

function H.near(actual, expected, tol, label)
  local ok = type(actual) == "number" and math.abs(actual - expected) <= tol
  record(ok, string.format(
    "%s: expected %s +/- %s, got %s",
    label, tostring(expected), tostring(tol), tostring(actual)))
end

function H.report()
  for _, f in ipairs(failures) do print("FAIL  " .. f) end
  print(string.format("%d passed, %d failed", passed, failed))
  os.exit(failed == 0 and 0 or 1)
end

return H
