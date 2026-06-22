-- Pure-Lua tests for flush_gate.history_due.
--
-- Run with: lua tests/flush_gate_test.lua
--
-- flush_gate.lua has no host-API dependencies, so a vanilla Lua interpreter
-- is enough (same pattern as classifier_test.lua).

package.path = "src/?.lua;" .. package.path
local flush_gate = require("flush_gate")

local failures = 0
local function check(label, got, want)
  if got ~= want then
    failures = failures + 1
    print(string.format("FAIL: %s — got %s, want %s", label, tostring(got), tostring(want)))
  else
    print("ok: " .. label)
  end
end

local function opts(o)
  return {
    dirty       = o.dirty,
    force       = o.force or false,
    pending     = o.pending or 0,
    elapsed_s   = o.elapsed_s or 0,
    line_budget = o.line_budget or 50,
    max_age_s   = o.max_age_s or 30,
  }
end

-- Clean state: nothing queued → never writes.
check("not dirty never writes", flush_gate.history_due(opts({ dirty = false, force = true, pending = 999, elapsed_s = 999 })), false)

-- Dirty but under both thresholds → coalesce (skip this tick).
check("dirty under thresholds waits", flush_gate.history_due(opts({ dirty = true, pending = 1, elapsed_s = 5 })), false)

-- Force always writes when dirty (disconnect / reload).
check("force writes when dirty", flush_gate.history_due(opts({ dirty = true, force = true, pending = 0, elapsed_s = 0 })), true)
-- ...but force on a clean buffer still writes nothing.
check("force on clean writes nothing", flush_gate.history_due(opts({ dirty = false, force = true })), false)

-- Line budget reached → write.
check("line budget triggers", flush_gate.history_due(opts({ dirty = true, pending = 50, elapsed_s = 1 })), true)
check("just under line budget waits", flush_gate.history_due(opts({ dirty = true, pending = 49, elapsed_s = 1 })), false)

-- Max age reached → write even with few lines.
check("max age triggers", flush_gate.history_due(opts({ dirty = true, pending = 1, elapsed_s = 30 })), true)
check("just under max age waits", flush_gate.history_due(opts({ dirty = true, pending = 1, elapsed_s = 29 })), false)

if failures == 0 then
  print("all flush_gate tests passed")
else
  print(failures .. " failure(s)")
  os.exit(1)
end
