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
-- Storage keys + module-scope caches.
--
-- Field timings showed route_line() doing 2–6 SQLite round-trips per chat
-- line (p50 22ms, p99 114ms). Every mutable storage value is now mirrored
-- in a module-scope Lua local: hot paths read/write the cache, and a
-- debounced timer flushes dirty caches to disk every 5s. User-initiated
-- changes (settings toggles, group join/leave) flush eagerly so they
-- survive a crash; background bookkeeping (last_seen / count bumps,
-- scrollback append) rides the debounce. See
-- docs/specs/2026-06-14-route-line-perf-design.md.
-- ---------------------------------------------------------------------

local HISTORY_MAX    = 500
local HISTORY_KEY    = "chat_history_v1"
local CHANNELS_KEY   = "channel_settings_v1"
local SOURCES_KEY    = "source_settings_v1"
local ACTIVE_TAB_KEY = "active_tab_v1"
local GROUP_KEY      = "group_channel"

local PERSIST_DEBOUNCE_MS = 5000

local function init_sources()
  local s = storage.get(SOURCES_KEY)
  if not s then s = {} end
  if not s.tells then s.tells = {} end
  if not s.group then s.group = {} end
  if s.tells.gag_main == nil then s.tells.gag_main = false end
  if s.tells.sound    == nil then s.tells.sound    = false end
  if s.group.gag_main == nil then s.group.gag_main = false end
  if s.group.sound    == nil then s.group.sound    = false end
  return s
end

local channels_cache = storage.get(CHANNELS_KEY) or {}
local sources_cache  = init_sources()
local group_channel  = storage.get(GROUP_KEY)
local history_buf    = storage.get(HISTORY_KEY) or {}

local channels_dirty = false
local history_dirty  = false

local function flush()
  if history_dirty then
    storage.set(HISTORY_KEY, history_buf)
    history_dirty = false
  end
  if channels_dirty then
    storage.set(CHANNELS_KEY, channels_cache)
    channels_dirty = false
  end
end

-- ---------------------------------------------------------------------
-- Scrollback — 500-entry ring buffer in plugin storage. Replayed when
-- the panel iframe (re-)mounts and posts a "ready" handshake.
-- ---------------------------------------------------------------------

local function persist(entry)
  history_buf[#history_buf + 1] = entry
  while #history_buf > HISTORY_MAX do table.remove(history_buf, 1) end
  history_dirty = true
end

local function replay()
  for _, e in ipairs(history_buf) do
    panel:post("line", e)
  end
end

-- ---------------------------------------------------------------------
-- Settings — per-channel registry + per-source toggles.
-- ---------------------------------------------------------------------

local function full_settings()
  return {
    channels   = channels_cache,
    sources    = sources_cache,
    active_tab = storage.get(ACTIVE_TAB_KEY),
  }
end

local function broadcast_settings()
  panel:post("settings", full_settings())
end

-- Mark a channel as seen — creates a default entry on first sighting,
-- bumps last_seen + count on every observation. Rides the debounce: a
-- per-match write of the channels map would re-encode the whole table
-- and was a large fraction of the p50 cost.
local function ensure_channel_entry(name)
  local entry = channels_cache[name]
  if not entry then
    entry = { listen = true, gag_main = false, pinned = false, sound = false, count = 0 }
    channels_cache[name] = entry
  end
  -- Defensive: backfill `sound` on pre-existing entries written before
  -- the field was added so chime decisions don't dereference nil.
  if entry.sound == nil then entry.sound = false end
  entry.last_seen = os.time()
  entry.count = (entry.count or 0) + 1
  channels_dirty = true
  return entry
end

local function set_group(name)
  if name == nil or name == "" then
    group_channel = nil
    storage.set(GROUP_KEY, nil)
  else
    group_channel = name
    storage.set(GROUP_KEY, name)
    -- A bracketed-channel trigger can race the group-join trigger on
    -- the very first "[name] You have joined the group." line and
    -- stamp `name` into the channel registry before we knew it was a
    -- group. Clean it up so it doesn't surface as a regular channel.
    if channels_cache[name] then
      channels_cache[name] = nil
      -- User-visible state change (the channel disappears from the
      -- settings list) — flush immediately rather than waiting on the
      -- debounce, and clear the dirty flag along with it.
      storage.set(CHANNELS_KEY, channels_cache)
      channels_dirty = false
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
-- dedupe by the iframe's `session` token so retries within a single
-- mount don't double-replay, but a fresh mount (clicking the tray icon
-- to remount, plugin reload, etc.) gets its history replayed every
-- time. Settings can be re-broadcast freely.
local last_replay_session = nil
panel:on_message("ready", function(payload)
  local session = type(payload) == "table" and payload.session or nil
  if session == nil or session ~= last_replay_session then
    replay()
    last_replay_session = session
  end
  broadcast_settings()
end)

-- Delta shape (any field optional):
--   { channel = { name = "foo", listen = bool, gag_main = bool, pinned = bool, remove = bool },
--     source  = { tells = { gag_main = bool }, group = { gag_main = bool } } }
panel:on_message("settings_update", function(delta)
  if type(delta) ~= "table" then return end

  if type(delta.channel) == "table" and type(delta.channel.name) == "string" then
    local name = delta.channel.name
    if delta.channel.remove then
      channels_cache[name] = nil
    else
      local entry = channels_cache[name] or { listen = true, gag_main = false, pinned = false, sound = false, count = 0 }
      if delta.channel.listen   ~= nil then entry.listen   = delta.channel.listen   and true or false end
      if delta.channel.gag_main ~= nil then entry.gag_main = delta.channel.gag_main and true or false end
      if delta.channel.pinned   ~= nil then entry.pinned   = delta.channel.pinned   and true or false end
      if delta.channel.sound    ~= nil then entry.sound    = delta.channel.sound    and true or false end
      channels_cache[name] = entry
    end
    -- User toggled a checkbox; flush eagerly so the change survives a
    -- crash within the next 5s. Clears the dirty flag because the
    -- write also persists any debounced bumps that piggybacked on it.
    storage.set(CHANNELS_KEY, channels_cache)
    channels_dirty = false
  end

  if type(delta.source) == "table" then
    if type(delta.source.tells) == "table" then
      if delta.source.tells.gag_main ~= nil then sources_cache.tells.gag_main = delta.source.tells.gag_main and true or false end
      if delta.source.tells.sound    ~= nil then sources_cache.tells.sound    = delta.source.tells.sound    and true or false end
    end
    if type(delta.source.group) == "table" then
      if delta.source.group.gag_main ~= nil then sources_cache.group.gag_main = delta.source.group.gag_main and true or false end
      if delta.source.group.sound    ~= nil then sources_cache.group.sound    = delta.source.group.sound    and true or false end
    end
    storage.set(SOURCES_KEY, sources_cache)
  end

  broadcast_settings()
end)

-- Persist the user's last-viewed chat tab so a fresh iframe (Mallard
-- restart, plugin reload, tray icon click) can restore it. No need to
-- broadcast back — the iframe already knows what it just sent.
panel:on_message("active_tab", function(payload)
  if type(payload) ~= "table" then return end
  if type(payload.tab) == "string" then
    storage.set(ACTIVE_TAB_KEY, payload.tab)
  end
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

-- Chime debounce: leading-edge throttle. First chime in a burst plays
-- immediately, subsequent ones within CHIME_DEBOUNCE_S are suppressed.
-- os.time() is seconds-precision (no millisecond wall clock available
-- in the plugin Lua sandbox), so the floor of the actual gap can be
-- one second smaller than the constant — set to 2s so the effective
-- minimum gap is ≥1s.
local CHIME_DEBOUNCE_S = 2
local last_chime_ts = 0

-- Cached character name from GMCP Char.Info, used to detect the user's
-- own channel utterances (Discworld echoes them as "[Channel] CapName:
-- ..." rather than "[Channel] You ..."). Populated on every Char.Info
-- push — gmcp.on lowercases the prefix at registration, so this works
-- regardless of the server's wire case for the package name.
--
-- On plugin reload mid-session, gmcp.on won't replay the char.info frame
-- the server already pushed, so we'd be stuck without self_capname until
-- the next push (which may never come if the player isn't doing anything
-- that re-triggers it). Read the GMCP mirror directly via gmcp.get to
-- self-heal — the live gmcp.on handler keeps it fresh after that.
local self_capname = nil
gmcp.on("char.info", function(_, data)
  if type(data) == "table" and type(data.capname) == "string" then
    self_capname = data.capname
  end
end)
local cached_capname = gmcp.get("char.info.capname")
if type(cached_capname) == "string" and cached_capname ~= "" then
  self_capname = cached_capname
end

-- Returns true if the line should be gagged from the main output pane.
-- Also posts to the panel (and persists) when the relevant `listen` is on.
local function route_line(line_text)
  if htell_replay_pending then
    htell_replay_pending = false
    return false
  end
  local routing = classifier.classify(line_text, group_channel)
  if not routing then return false end

  -- Discworld echoes the user's own channel talk in two shapes: the
  -- legacy "[ChannelName] You say: ..." (caught by the classifier's
  -- "You " body check) and the modern "[ChannelName] CapName: ..."
  -- form (which classifier can't recognize without the player's name).
  -- `self_capname` is populated by the gmcp.on subscription above; it
  -- stays nil until the first Char.Info frame, after which we override
  -- routing.incoming when the body begins with the player's capname.
  if routing.incoming and routing.channel and self_capname then
    local body_start = #routing.channel + 4
    local end_idx = body_start + #self_capname - 1
    if line_text:sub(body_start, end_idx) == self_capname then
      local next_char = line_text:sub(end_idx + 1, end_idx + 1)
      if next_char == ":" or next_char == " " then
        routing.incoming = false
      end
    end
  end

  local gag = false
  local tab = routing.tab
  local listen = true
  -- Chime only fires for traffic the user didn't originate (classifier
  -- marks `incoming=false` for outgoing tells and any channel/group line
  -- whose body starts with "You ").
  local should_chime = false

  if routing.tab == "tells" then
    gag = sources_cache.tells.gag_main and true or false
    if routing.incoming then should_chime = sources_cache.tells.sound and true or false end
  elseif routing.tab == "group" then
    gag = sources_cache.group.gag_main and true or false
    if routing.incoming then should_chime = sources_cache.group.sound and true or false end
  elseif routing.tab == "channels" then
    -- "[name] You have joined the group." fires both the bracketed-
    -- channel trigger and the group-event trigger. Trigger order isn't
    -- guaranteed — if the channel trigger lands first, classifier
    -- doesn't know `name` is a group yet. Detect group events here
    -- and route them to the group tab (and group's gag setting) so a
    -- freshly-formed group can't slip into the channel registry.
    if classifier.parse_group_event(line_text) then
      tab = "group"
      gag = sources_cache.group.gag_main and true or false
      -- Group join/leave/rename events all start with "You ", so
      -- routing.incoming is false and no chime fires regardless.
    else
      local entry = ensure_channel_entry(routing.channel)
      gag = entry.gag_main and true or false
      listen = entry.listen and true or false
      if entry.pinned then
        tab = "channel:" .. routing.channel
      end
      if routing.incoming then should_chime = entry.sound and true or false end
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
    if should_chime then
      local now = os.time()
      if now - last_chime_ts >= CHIME_DEBOUNCE_S then
        mud.play_sound("mallard:chime-high")
        last_chime_ts = now
      end
    end
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

-- ---------------------------------------------------------------------
-- Debounced flush + disconnect flush.
--
-- Both dirty buffers ride a single 5s timer. `world.on("disconnect")`
-- also fires on plugin reload (see mallard host.rs dispatch_lifecycle),
-- so a fresh code drop won't lose the in-flight buffers either.
-- ---------------------------------------------------------------------

mud.every(PERSIST_DEBOUNCE_MS, flush)
world.on("disconnect", flush)
