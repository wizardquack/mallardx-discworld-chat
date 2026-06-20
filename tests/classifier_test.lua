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

-- Incoming tells. classifier.classify routes these to the tells tab; the
-- live `mud.trigger` in main.lua pre-filters with a Rust regex that MUST
-- accept the same shapes (it gates whether route_line/classify ever runs).
-- The lowercase-title case below is the Fenrir regression: htell scrollback
-- showed "Fenrir the misspeler tells you: ...", the classifier matched it,
-- but the old trigger regex (`(?: [A-Z]\w+)*`) required every word past the
-- name to be Capitalized and dropped the line before classify saw it.
local function check_tell(label, line, want_incoming)
  local r = classifier.classify(line, nil)
  local ok = type(r) == "table" and r.tab == "tells" and r.incoming == want_incoming
  if ok then
    io.write("ok   " .. label .. "\n")
  else
    failures = failures + 1
    local got = type(r) == "table"
      and string.format("{tab=%q, incoming=%s}", tostring(r.tab), tostring(r.incoming))
      or tostring(r)
    io.write(string.format("FAIL %s\n     got  = %s\n     want = {tab=\"tells\", incoming=%s}\n",
      label, got, tostring(want_incoming)))
  end
end

check_tell("incoming tell: bare name",
  "Fenrir tells you: hi", true)

check_tell("incoming tell: multi-word capitalized name",
  "Astrum Argenteum tells you: hi", true)

check_tell("incoming tell: name + lowercase adverb (drunk state)",
  "Kiki totally tells you: hi", true)

check_tell("incoming tell: lowercase title — Fenrir regression",
  "Fenrir the misspeler tells you: how can i help.", true)

check_tell("incoming asks: lowercase title — Fenrir regression",
  "Fenrir the misspeler asks you: most important room is the water room.", true)

check_tell("incoming exclaims: lowercase title",
  "Fenrir the misspeler exclaims to you: hi!", true)

check_tell("incoming tell: three-word family name",
  "Gnillot in the Darrke tells you: over here", true)

check_tell("incoming tell: lowercase three-word family name",
  "Being nude in public asks you: where to?", true)

check_tell("incoming tell: apostrophe + hyphen in family name",
  "Dacrian didn't do-it exclaims to you: oops!", true)

check_tell("incoming tell: single-letter family word",
  "Gin n Tonique tells you: cheers", true)

check_tell("incoming tell: outgoing echo is not incoming",
  "You tell Fenrir the misspeler: Hi!", false)

-- Data-driven coverage against the live family-name roster (captured from
-- the MUD's "<family> was founded by <Founder> with <N> member(s)." listing).
-- The wire speaker token is "<Founder> <family>"; every family must route a
-- tells/asks/exclaims line to the tells tab. This guards against any future
-- tightening of is_incoming_tell that would drop free-form family names.
local FAMILY_ROSTER = [[
accidentally was founded by Ratman with one member.
al'Nighter was founded by Nayeli with four members.
al-Mu'aqqibat was founded by Iblis with two members.
allegedly was founded by Aslo with one member.
Argenteum was founded by Astrum with one member.
b'Nanerz was founded by Hannerz with one member.
Bell was founded by Quow with two members.
Boborgle was founded by Zorgle with one member.
Boltzmann was founded by Bosse with one member.
Brynhildr was founded by Valkyrie with one member.
Cellery was founded by Antonio with one member.
CodeBreaker was founded by Osore with one member.
con Pollo was founded by Arroz with one member.
con Queso was founded by Pollo with one member.
Crowforge was founded by Zidane with one member.
D'Aquitaine was founded by Kalexys with one member.
d'Ardoise was founded by Elauna with one member.
d'Groggy was founded by Arwyn with one member.
d'Immortal was founded by Ceres with one member.
d'Licious was founded by Taffyd with five members.
D'man was founded by Joker with one member.
d'Mycroft was founded by Huff with two members.
d'Parranoid was founded by Dextar with thirteen members.
da'Barbarian was founded by Fernir with one member.
Da'Modred was founded by Mori with one member.
Daluka was founded by Talven with eighteen members.
de Nerde was founded by Sugendran with one member.
Demente was founded by Akera with one member.
Demonwright was founded by Mythica with nine members.
Den Garran was founded by Stamen with one member.
DeSade was founded by Miki with one member.
Deus Ex was founded by Exalted with one member.
didn't do-it was founded by Dacrian with one member.
Dom Perignon was founded by Mysteriis with one member.
Dreamqvist was founded by Kadath with one member.
Faelix was founded by Arienne with one member.
Faintly was founded by Tremulo with one member.
Fallstar was founded by Ordeith with twenty-four members.
Featherhead was founded by Ignoramus with one member.
Forestweaver was founded by Twiggy with two members.
Frostholme was founded by Acalyn with two members.
Fury was founded by Utous with one member.
Girls was founded by Spice with four members.
GlitterZ was founded by Glitzi with one member.
GPT was founded by Reva with zero member.
Grolschdrinker was founded by Zuipschuit with five members.
Hsauce was founded by Hsoy with one member.
Hugglesome was founded by Hagatha with one member.
Illusione was founded by Armando with three members.
in the Darrke was founded by Gnillot with one member.
inator was founded by Woom with one member.
Innocent was founded by Oyhs with one member.
is pro-skub was founded by Vyre with one member.
is Transparent was founded by Turvity with one member.
Jiggles was founded by Julie with one member.
Joke was founded by Inside with one member.
Kimura was founded by Sato with one member.
L'Reaux was founded by Aimi with twenty-four members.
Le'Zatapathique was founded by Amaranth with six members.
LekkerDing was founded by Haloj with one member.
Licious was founded by Lala with one member.
Lockhart was founded by Asha with one member.
Luvmussel was founded by Leeroy with one member.
MacKill was founded by Sneeky with one member.
Maleficarum was founded by Malleus with one member.
Marshmallow was founded by Mauve with nine members.
Masala was founded by Rauna with one member.
Minamoto was founded by Ayoda with one member.
Missile was founded by Scud with one member.
Mistblade was founded by Shimodo with three members.
n Tonique was founded by Gin with one member.
NaSSaH was founded by Hassan with one member.
Necessities was founded by Braebear with one member.
Nightingale was founded by Kyja with three members.
Northstar was founded by Myrin with five members.
Nosferatu was founded by Precious with one member.
nude in public was founded by Being with two members.
O'Lalah was founded by Nuala with one member.
o'rock was founded by Ragn with thirteen members.
of Bingin' was founded by Arwyn with one member.
of Imagination was founded by Realm with one member.
Omega was founded by Aureole with one member.
Patch was founded by Buttercup with one member.
PieEater was founded by Nevvyn with one member.
Pott was founded by Quack with one member.
pteh Pterrible was founded by Ptoley with fourteen members.
Pturvy was founded by Ptopsy with one member.
Raffe was founded by Dji with one member.
Raft was founded by Airk with one member.
Rehevkor was founded by Lexx with eleven members.
Rove was founded by Deneb with one member.
Sanguina was founded by Carmine with one member.
Shinguji was founded by Xuron with one member.
Sinensis was founded by Camelion with two members.
Solari was founded by Archoplytes with one member.
Soxx was founded by Whompy with one member.
Spoonalicious was founded by Soothsayer with one member.
Starwhisper was founded by Lyra with five members.
Tality was founded by Fae with one member.
The Almighty was founded by Kalizkan with one member.
the Flame was founded by Venia with one member.
the Fluffy was founded by Phantomracer with twenty members.
the Hero was founded by Zero with one member.
the misspeler was founded by Fenrir with one member.
the Pooh was founded by Elistan with one member.
the Tyger was founded by Cyclo with five members.
TiME was founded by Grime with one member.
totally was founded by Kiki with two members.
Ultion was founded by Umiven with one member.
Viras was founded by Jerec with fifteen members.
von Brassbridge was founded by Appelhof with twenty-one members.
von Glitz was founded by Aell with one member.
von Schaf was founded by Emily with two members.
Von Vivisector was founded by Vviciousvv with one member.
Wibblesworth was founded by Eldermeer with one member.
Willowstaff was founded by Brunswick with one member.
Wollstonecraft was founded by Natalolly with three members.
Womblesworth was founded by Geryon with sixty-one members.
Yatsu was founded by Yabai with one member.
]]

local roster_count = 0
for family, founder in FAMILY_ROSTER:gmatch("([^\n]-) was founded by (%a+) with") do
  roster_count = roster_count + 1
  local speaker = founder .. " " .. family
  check_tell("roster tells: " .. speaker, speaker .. " tells you: hi", true)
  check_tell("roster asks: " .. speaker, speaker .. " asks you: hi?", true)
  check_tell("roster exclaims: " .. speaker, speaker .. " exclaims to you: hi!", true)
end
check("roster: parsed expected number of families", roster_count, 119)

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
