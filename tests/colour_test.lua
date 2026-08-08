-- Pure-Lua tests for colour.sanitise / colour.resolve.
--
-- Run with: lua tests/colour_test.lua
--
-- colour.lua has no host-API dependencies, so a vanilla Lua interpreter
-- is enough — same pattern as classifier_test.lua / flush_gate_test.lua.
--
-- This is the settings_update trust boundary: everything here arrives from
-- the panel iframe as decoded JSON, so the point of these cases is that
-- nothing but an in-range integer ever reaches storage.

package.path = "src/?.lua;" .. package.path
local colour = require("colour")

local failures = 0
local function check(label, got, want)
  if got == want then
    print("ok   " .. label)
  else
    failures = failures + 1
    print("FAIL " .. label .. " — got " .. tostring(got) .. ", want " .. tostring(want))
  end
end

-- sanitise: the valid range, inclusive at both ends.
check("sanitise 0 (Black)",   colour.sanitise(0),  0)
check("sanitise 7",           colour.sanitise(7),  7)
check("sanitise 15 (last)",   colour.sanitise(15), 15)

-- sanitise: out of range.
check("sanitise -1",          colour.sanitise(-1),  nil)
check("sanitise 16",          colour.sanitise(16),  nil)
check("sanitise -100",        colour.sanitise(-100), nil)

-- sanitise: floats truncate toward the floor rather than being rejected,
-- so a JSON number that decoded as 3.0 still works.
check("sanitise 3.0",         colour.sanitise(3.0), 3)
check("sanitise 3.7 floors",  colour.sanitise(3.7), 3)
check("sanitise -0.5 floors out of range", colour.sanitise(-0.5), nil)

-- sanitise: non-numbers.
check("sanitise nil",         colour.sanitise(nil),      nil)
check("sanitise string",      colour.sanitise("3"),      nil)
check("sanitise bool",        colour.sanitise(true),     nil)
check("sanitise table",       colour.sanitise({}),       nil)

-- sanitise: NaN. Every comparison against NaN is false, so a plain range
-- check passes it through; it must be rejected explicitly or we store a
-- value that can't be JSON-encoded on the way back to the panel.
local nan = 0 / 0
check("sanitise NaN",         colour.sanitise(nan),  nil)
check("sanitise +inf",        colour.sanitise(math.huge),  nil)
check("sanitise -inf",        colour.sanitise(-math.huge), nil)

-- resolve: the DEFAULT sentinel clears, and so does anything invalid —
-- garbage resets the row rather than wedging it.
check("resolve DEFAULT clears",  colour.resolve(colour.DEFAULT), nil)
check("resolve -1 is DEFAULT",   colour.resolve(-1),   nil)
check("resolve valid slot",      colour.resolve(9),    9)
check("resolve slot 0",          colour.resolve(0),    0)
check("resolve out of range",    colour.resolve(99),   nil)
check("resolve string",          colour.resolve("red"), nil)
check("resolve NaN",             colour.resolve(nan),  nil)

-- Guards the `and`/`or` trap the original inline version relied on: slot 0
-- is falsy in most languages but truthy in Lua, so it must survive resolve
-- as 0 and not collapse to nil.
check("slot 0 survives resolve (not nil)", colour.resolve(0) ~= nil, true)

if failures == 0 then
  print("all colour tests passed")
else
  print(failures .. " failure(s)")
  os.exit(1)
end
