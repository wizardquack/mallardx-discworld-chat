-- Discworld Chat — Plan #9 flagship plugin.
--
-- Captures tells, group says, and public channels into a 4-tab
-- custom-HTML panel (All / Tells / Group / Channels). Classification
-- logic lives in src/classifier.lua for unit-testability; this entry
-- wires the classifier into mud.trigger registrations and pushes
-- routed lines to the panel via :post().

local classifier = require("classifier")

local panel = mud.panel("chat")

-- ---------------------------------------------------------------------
-- Outbound: classify the line + post to panel (and persist).
-- ---------------------------------------------------------------------

local function set_group(name)
  if name == nil or name == "" then
    storage.set("group_channel", nil)
  else
    storage.set("group_channel", name)
  end
end

-- ---------------------------------------------------------------------
-- Persistence — 500-entry ring buffer in plugin storage. Replayed when
-- the panel iframe (re-)mounts and posts a "ready" handshake.
-- ---------------------------------------------------------------------

local HISTORY_MAX = 500
local HISTORY_KEY = "chat_history_v1"

local function persist(entry)
  local hist = storage.get(HISTORY_KEY) or {}
  hist[#hist + 1] = entry
  while #hist > HISTORY_MAX do table.remove(hist, 1) end
  storage.set(HISTORY_KEY, hist)
end

local function replay()
  local hist = storage.get(HISTORY_KEY) or {}
  for _, e in ipairs(hist) do
    panel:post("line", e)
  end
end

-- Custom-HTML panels use a non-reserved name for the "iframe ready"
-- handshake; "__ready__" is reserved for the Plan #8a template-panel
-- framework's bundle (template-panel.js).
panel:on_message("ready", function()
  replay()
end)

-- htell replays history as marker + tell line pairs:
--   ** Tue May 26 13:44:57 2026 [PDT] **
--   You tell Dilbo: blah blah blah blah
-- The tell line is shape-identical to a live tell, so we suppress the
-- immediately-following line whenever a marker has just been seen.
local htell_replay_pending = false

local function post_line(line_text)
  if htell_replay_pending then
    htell_replay_pending = false
    return
  end
  local group_channel = storage.get("group_channel")
  local routing = classifier.classify(line_text, group_channel)
  if not routing then return end
  local payload = {
    tab     = routing.tab,
    channel = routing.channel,
    text    = line_text,
    ts      = os.time(),
  }
  panel:post("line", payload)
  persist(payload)
end

-- ---------------------------------------------------------------------
-- Trigger registrations.
--
-- Patterns use Rust regex syntax (mud.trigger compiles via the regex
-- crate per Plan #7b). The patterns mirror Quow's regexes from
-- QuowMinimap.xml lines 26575-26617 and 26689-26747, with the optional
-- `(?:> )?` prompt prefix removed.
--
-- Each trigger calls into the classifier (which uses Lua-pattern
-- matching) — the regex matches "is this kind of line", the classifier
-- decides the routing. The integration test in Task 12 covers the
-- end-to-end behavior; drift between the two pattern dialects shows
-- up there.
-- ---------------------------------------------------------------------

-- htell scrollback marker — arm the suppress flag for the next line.
mud.trigger([==[^\*\* [A-Za-z]+ [A-Za-z]+ \d+ \d+:\d+:\d+ \d{4} \[[^\]]+\] \*\*$]==], function()
  htell_replay_pending = true
end)

-- Outgoing tell / ask / exclaim
mud.trigger([==[^You (?:[A-Za-z]+ )?(?:tell |exclaim to |ask ).+?: ]==], function(m)
  post_line(m.text)
end)

-- Incoming tell / asks / exclaims. The `(?: [A-Z]\w+)*` allows multi-word
-- capitalized speaker names ("Astrum Argenteum tells you: ..."); the
-- optional `(?:[a-z]+ )?` matches adverb modifiers Discworld inserts
-- between the name and verb when the speaker is in a state like
-- drunkenness ("Kiki totally tells you: ...").
mud.trigger([==[^[A-Z]\w+(?: [A-Z]\w+)* (?:[a-z]+ )?(?:tells|exclaims to|asks).+?you: ]==], function(m)
  post_line(m.text)
end)

-- Bracketed channel (any [name] line with letters following)
mud.trigger([==[^\[[^\]]+\] [A-Za-z]{3,}]==], function(m)
  post_line(m.text)
end)

-- Parens channel (talkers like (One), (Two), club channels) — always
-- routes to channels tab. Group says use square brackets per Quow.
mud.trigger([==[^\([^)]+\) [A-Za-z]{3,}]==], function(m)
  post_line(m.text)
end)

-- ---------------------------------------------------------------------
-- Group membership auto-detect
-- ---------------------------------------------------------------------

mud.trigger([==[^\[[^\]]+\] You have joined the group\.$]==], function(m)
  local ev = classifier.parse_group_event(m.text)
  if ev and ev.kind == "join" then set_group(ev.name) end
end)

mud.trigger([==[^\[[^\]]+\] The group has been renamed to .+\.$]==], function(m)
  local ev = classifier.parse_group_event(m.text)
  if ev and ev.kind == "rename" then set_group(ev.name) end
end)

mud.trigger([==[^\[[^\]]+\] You have left the group\.$]==], function()
  set_group(nil)
end)
