-- Discworld Chat — Plan #9 flagship plugin.
--
-- Captures tells, group says, and public channels into a tabbed custom-HTML
-- panel. Tabs: All / Tells / Group / <user-pinned channels...> / Channels.
-- Classification logic lives in src/classifier.lua for unit-testability;
-- this entry wires the classifier into mud.trigger registrations and pushes
-- routed lines to the panel via :post().
--
-- Per-channel user settings (listen / gag-main / pin-as-tab) are managed
-- from an in-panel settings view; the iframe sends `settings_update`
-- deltas which we persist and echo back as a full `settings` blob.

local classifier = require("classifier")

local panel = mud.panel("chat")

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

-- ---------------------------------------------------------------------
-- Settings — per-channel registry + per-source toggles.
-- ---------------------------------------------------------------------

local CHANNELS_KEY = "channel_settings_v1"
local SOURCES_KEY  = "source_settings_v1"

local function load_channels()
  return storage.get(CHANNELS_KEY) or {}
end

local function load_sources()
  local s = storage.get(SOURCES_KEY)
  if not s then s = {} end
  if not s.tells then s.tells = { gag_main = false } end
  if not s.group then s.group = { gag_main = false } end
  return s
end

local function save_channels(c) storage.set(CHANNELS_KEY, c) end
local function save_sources(s)  storage.set(SOURCES_KEY,  s) end

local function full_settings()
  return { channels = load_channels(), sources = load_sources() }
end

local function broadcast_settings()
  panel:post("settings", full_settings())
end

-- Mark a channel as seen — creates a default entry on first sighting,
-- bumps last_seen + count on every observation.
local function ensure_channel_entry(name)
  local channels = load_channels()
  local entry = channels[name]
  if not entry then
    entry = { listen = true, gag_main = false, pinned = false, count = 0 }
    channels[name] = entry
  end
  entry.last_seen = os.time()
  entry.count = (entry.count or 0) + 1
  save_channels(channels)
  return entry
end

local function set_group(name)
  if name == nil or name == "" then
    storage.set("group_channel", nil)
  else
    storage.set("group_channel", name)
    -- A bracketed-channel trigger can race the group-join trigger on
    -- the very first "[name] You have joined the group." line and
    -- stamp `name` into the channel registry before we knew it was a
    -- group. Clean it up so it doesn't surface as a regular channel.
    local channels = load_channels()
    if channels[name] then
      channels[name] = nil
      save_channels(channels)
      broadcast_settings()
    end
  end
end

-- ---------------------------------------------------------------------
-- Handshake + settings updates.
-- ---------------------------------------------------------------------

-- Custom-HTML panels use a non-reserved name for the "iframe ready"
-- handshake; "__ready__" is reserved for the Plan #8a template-panel
-- framework's bundle (template-panel.js).
--
-- The iframe may retry "ready" if its first attempt raced the plugin's
-- top-level code (Mallard's panel dispatcher drops messages when no
-- listener is registered yet — see host.rs panel_dispatch_post). We
-- only replay history once per plugin instance to avoid duplicating
-- the scrollback; settings can be re-broadcast freely.
local replayed = false
panel:on_message("ready", function()
  if not replayed then
    replay()
    replayed = true
  end
  broadcast_settings()
end)

-- Delta shape (any field optional):
--   { channel = { name = "foo", listen = bool, gag_main = bool, pinned = bool, remove = bool },
--     source  = { tells = { gag_main = bool }, group = { gag_main = bool } } }
panel:on_message("settings_update", function(delta)
  if type(delta) ~= "table" then return end

  if type(delta.channel) == "table" and type(delta.channel.name) == "string" then
    local channels = load_channels()
    local name = delta.channel.name
    if delta.channel.remove then
      channels[name] = nil
    else
      local entry = channels[name] or { listen = true, gag_main = false, pinned = false, count = 0 }
      if delta.channel.listen   ~= nil then entry.listen   = delta.channel.listen   and true or false end
      if delta.channel.gag_main ~= nil then entry.gag_main = delta.channel.gag_main and true or false end
      if delta.channel.pinned   ~= nil then entry.pinned   = delta.channel.pinned   and true or false end
      channels[name] = entry
    end
    save_channels(channels)
  end

  if type(delta.source) == "table" then
    local sources = load_sources()
    if type(delta.source.tells) == "table" and delta.source.tells.gag_main ~= nil then
      sources.tells.gag_main = delta.source.tells.gag_main and true or false
    end
    if type(delta.source.group) == "table" and delta.source.group.gag_main ~= nil then
      sources.group.gag_main = delta.source.group.gag_main and true or false
    end
    save_sources(sources)
  end

  broadcast_settings()
end)

-- ---------------------------------------------------------------------
-- Line dispatch.
-- ---------------------------------------------------------------------

-- htell replays history as marker + tell line pairs:
--   ** Tue May 26 13:44:57 2026 [PDT] **
--   You tell Dilbo: blah blah blah blah
-- The tell line is shape-identical to a live tell, so we suppress the
-- immediately-following line whenever a marker has just been seen.
local htell_replay_pending = false

-- Returns true if the line should be gagged from the main output pane.
-- Also posts to the panel (and persists) when the relevant `listen` is on.
local function route_line(line_text)
  if htell_replay_pending then
    htell_replay_pending = false
    return false
  end
  local group_channel = storage.get("group_channel")
  local routing = classifier.classify(line_text, group_channel)
  if not routing then return false end

  local sources = load_sources()
  local gag = false
  local tab = routing.tab
  local listen = true

  if routing.tab == "tells" then
    gag = sources.tells.gag_main and true or false
  elseif routing.tab == "group" then
    gag = sources.group.gag_main and true or false
  elseif routing.tab == "channels" then
    -- "[name] You have joined the group." fires both the bracketed-
    -- channel trigger and the group-event trigger. Trigger order isn't
    -- guaranteed — if the channel trigger lands first, classifier
    -- doesn't know `name` is a group yet. Detect group events here
    -- and route them to the group tab (and group's gag setting) so a
    -- freshly-formed group can't slip into the channel registry.
    if classifier.parse_group_event(line_text) then
      tab = "group"
      gag = sources.group.gag_main and true or false
    else
      local entry = ensure_channel_entry(routing.channel)
      gag = entry.gag_main and true or false
      listen = entry.listen and true or false
      if entry.pinned then
        tab = "channel:" .. routing.channel
      end
    end
  end

  if listen then
    local payload = {
      tab     = tab,
      channel = routing.channel,
      text    = line_text,
      ts      = os.time(),
    }
    panel:post("line", payload)
    persist(payload)
  end

  return gag
end

-- ---------------------------------------------------------------------
-- Trigger registrations.
--
-- Patterns use Rust regex syntax (mud.trigger compiles via the regex
-- crate per Plan #7b). The patterns mirror Quow's regexes from
-- QuowMinimap.xml lines 26575-26617 and 26689-26747, with the optional
-- `(?:> )?` prompt prefix removed.
-- ---------------------------------------------------------------------

-- htell scrollback marker — arm the suppress flag for the next line.
mud.trigger([==[^\*\* [A-Za-z]+ [A-Za-z]+ \d+ \d+:\d+:\d+ \d{4} \[[^\]]+\] \*\*$]==], function()
  htell_replay_pending = true
end)

-- Outgoing tell / ask / exclaim
mud.trigger([==[^You (?:[A-Za-z]+ )?(?:tell |exclaim to |ask ).+?: ]==], function(m)
  if route_line(m.text) then m:gag() end
end)

-- Incoming tell / asks / exclaims. The `(?: [A-Z]\w+)*` allows multi-word
-- capitalized speaker names ("Astrum Argenteum tells you: ..."); the
-- optional `(?:[a-z]+ )?` matches adverb modifiers Discworld inserts
-- between the name and verb when the speaker is in a state like
-- drunkenness ("Kiki totally tells you: ...").
mud.trigger([==[^[A-Z]\w+(?: [A-Z]\w+)* (?:[a-z]+ )?(?:tells|exclaims to|asks).+?you: ]==], function(m)
  if route_line(m.text) then m:gag() end
end)

-- Bracketed channel (any [name] line with letters following)
mud.trigger([==[^\[[^\]]+\] [A-Za-z]{3,}]==], function(m)
  if route_line(m.text) then m:gag() end
end)

-- Parens channel (talkers like (One), (Two), club channels) — always
-- routes to channels tab. Group says use square brackets per Quow.
mud.trigger([==[^\([^)]+\) [A-Za-z]{3,}]==], function(m)
  if route_line(m.text) then m:gag() end
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
