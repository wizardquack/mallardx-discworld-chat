-- Pure-Lua tests for classifier.parse_group_event.
--
-- Run with: lua tests/classifier_test.lua
--
-- classifier.lua has no host-API dependencies, so a vanilla Lua
-- interpreter is enough. The patterns are Lua patterns (not Rust
-- regex), so the system `lua` evaluates them identically to the
-- plugin sandbox.

package.path = "src/?.lua;" .. package.path
local classifier = require("classifier")

local failures = 0
local function check(label, got, want)
  local ok
  if type(want) == "table" then
    ok = type(got) == "table"
        and got.kind == want.kind
        and got.name == want.name
  else
    ok = got == want
  end
  if ok then
    io.write("ok   " .. label .. "\n")
  else
    failures = failures + 1
    local function show(v)
      if type(v) == "table" then
        return string.format("{kind=%q, name=%q}", tostring(v.kind), tostring(v.name))
      end
      return tostring(v)
    end
    io.write(string.format("FAIL %s\n     got  = %s\n     want = %s\n",
      label, show(got), show(want)))
  end
end

-- Join
check("join: basic",
  classifier.parse_group_event("[Sailors] You have joined the group."),
  { kind = "join", name = "Sailors" })

check("join: short bracket",
  classifier.parse_group_event("[g] You have joined the group."),
  { kind = "join", name = "g" })

check("join: bracket can hold spaces / punctuation",
  classifier.parse_group_event("[Party Boat!] You have joined the group."),
  { kind = "join", name = "Party Boat!" })

-- Leave
check("leave: basic",
  classifier.parse_group_event("[Sailors] You have left the group."),
  { kind = "leave", name = nil })

-- Rename — these are the real wire shapes captured from
-- ~/code/3p/tt_dw/logs/2026/03/{07,10,13}-icefish.lan-quack. Discworld
-- displays the new group name canonicalised in the brackets
-- (auto-capitalised, truncated to ~15 chars with a `...` suffix) but
-- echoes the literal lowercase typed name in the body. Future group
-- says reuse the bracketed form, so the bracketed name is what we
-- must store as group_channel.
check("rename: real log — truncated bracket vs full lowercase body",
  classifier.parse_group_event("[ParanoidSmug...] The group has been renamed to paranoidsmugglers."),
  { kind = "rename", name = "ParanoidSmug..." })

check("rename: real log — case-only delta",
  classifier.parse_group_event("[Sailors] The group has been renamed to sailors."),
  { kind = "rename", name = "Sailors" })

check("rename: real log — punctuation in name",
  classifier.parse_group_event("[PartyBoat!] The group has been renamed to partyboat!."),
  { kind = "rename", name = "PartyBoat!" })

check("rename: spec-doc example",
  classifier.parse_group_event("[group] The group has been renamed to Heroes."),
  { kind = "rename", name = "group" })

-- Non-events
check("non-event: regular group say returns nil",
  classifier.parse_group_event("[Sailors] Lyna: is he coming?"),
  nil)

check("non-event: other-player join not parsed as self-join",
  classifier.parse_group_event("[Sailors] Bob has joined the group."),
  nil)

check("non-event: empty bracket",
  classifier.parse_group_event("[] You have joined the group."),
  nil)

check("non-event: non-string input",
  classifier.parse_group_event(nil),
  nil)

if failures > 0 then
  io.write(string.format("\n%d test(s) failed\n", failures))
  os.exit(1)
end
io.write("\nall tests passed\n")
