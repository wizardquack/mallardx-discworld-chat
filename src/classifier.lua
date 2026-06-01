-- Discworld chat line classifier + group-event parser.
--
-- Pure Lua, no host-API dependencies. Patterns ported from Quow's
-- QuowMinimap.xml (lines 26575-26617, 26689-26747) with `(?:> )?`
-- prompt prefix removed (Mallard's LineAssembler doesn't carry the
-- prompt onto the next line).
--
-- Lua's built-in `string.match` patterns ARE used here (not Rust
-- regex) — these are pure-Lua tests; the production trigger
-- registrations in main.lua use Rust regex via mud.trigger. The
-- two pattern dialects are kept *behaviorally* in sync by the
-- integration test in Task 12 which exercises the real triggers.

local M = {}

-- Outgoing tell: "You tell Bob:", "You exclaim to Bob:", "You ask Bob:".
-- The `%a+ ` alternative also accepts an adverb modifier Discworld inserts
-- between "You" and the verb in certain states ("You totally tell Bob: ...").
local function is_outgoing_tell(line)
  return line:match("^You [Tt]ell ")        ~= nil
      or line:match("^You %a+ [Tt]ell ")    ~= nil
      or line:match("^You exclaim to ")     ~= nil
      or line:match("^You %a+ exclaim to ") ~= nil
      or line:match("^You ask ")            ~= nil
      or line:match("^You %a+ ask ")        ~= nil
end

-- Incoming tell: "Alice tells you:", "Bob exclaims to you:", "Carol asks you:".
-- The `%a+ ` alternatives also accept either an adverb modifier
-- ("Kiki totally tells you: ...") or a multi-word capitalized speaker name
-- ("Astrum Argenteum tells you: ..."), or both combined
-- ("Kiki Smith totally tells you: ...").
local function is_incoming_tell(line)
  if line:sub(1, 4) == "You " then return false end
  return line:match("^[A-Z]%w+ tells [^:]+: ")         ~= nil
      or line:match("^[A-Z]%w+ %a+ tells [^:]+: ")     ~= nil
      or line:match("^[A-Z]%w+ %a+ %a+ tells [^:]+: ") ~= nil
      or line:match("^[A-Z]%w+ exclaims to ")          ~= nil
      or line:match("^[A-Z]%w+ %a+ exclaims to ")      ~= nil
      or line:match("^[A-Z]%w+ %a+ %a+ exclaims to ")  ~= nil
      or line:match("^[A-Z]%w+ asks ")                 ~= nil
      or line:match("^[A-Z]%w+ %a+ asks ")             ~= nil
      or line:match("^[A-Z]%w+ %a+ %a+ asks ")         ~= nil
end

-- Bracketed channel: "[name] X says: ..." where name is not say/tell/soul/path/empty.
local function bracketed_channel(line)
  local ch = line:match("^%[([^%]]+)%] [A-Za-z][A-Za-z][A-Za-z]")
  if not ch then return nil end
  if ch == "say" or ch == "tell" or ch == "soul" or ch == " " then return nil end
  if ch:sub(1, 1) == "/" then return nil end
  return ch
end

-- Parens channel: "(name) X verb: ..." — same shape as bracketed
-- but with parens. No exclusion list (no `(say)` etc. that we know of).
--
-- Skips replayed history: when a player connects, the MUD redisplays
-- recent club chat with a timestamp inside the parens, e.g.
--   "(The Unsinkables May 27 09:10 PDT) aVocado: sol doesnt exist atm"
-- — these are scrollback, not live, and shouldn't be re-posted into
-- the chat panel.
local function parens_channel(line)
  local content = line:match("^%(([^%)]+)%) [A-Za-z][A-Za-z][A-Za-z]")
  if not content then return nil end
  -- " Mon DD HH:MM TZ" suffix marks a replayed-history line.
  if content:match(" %a+ %d+ %d+:%d+ %a+$") then return nil end
  return content
end

function M.classify(line, group_channel)
  if type(line) ~= "string" or line == "" then return nil end
  if is_outgoing_tell(line) or is_incoming_tell(line) then
    return { tab = "tells" }
  end
  local ch = bracketed_channel(line)
  if ch then
    if group_channel ~= nil and ch == group_channel then
      return { tab = "group", channel = ch }
    end
    return { tab = "channels", channel = ch }
  end
  local pch = parens_channel(line)
  if pch then
    -- Parens channels always go to channels tab (never group).
    return { tab = "channels", channel = pch }
  end
  return nil
end

-- htell replay marker: "** Tue May 26 13:44:57 2026 [PDT] **".
-- htell prints scrollback as marker + tell line pairs; main.lua uses
-- this detector to suppress the *following* line, since the tell itself
-- is indistinguishable in shape from a live tell.
function M.is_htell_marker(line)
  if type(line) ~= "string" then return false end
  return line:match("^%*%* %a+ %a+ %d+ %d+:%d+:%d+ %d%d%d%d %[[^%]]+%] %*%*$") ~= nil
end

function M.parse_group_event(line)
  if type(line) ~= "string" then return nil end
  local name = line:match("^%[([^%]]+)%] You have joined the group%.$")
  if name then return { kind = "join", name = name } end
  if line:match("^%[[^%]]+%] You have left the group%.$") then
    return { kind = "leave" }
  end
  local new_name = line:match("^%[[^%]]+%] The group has been renamed to (.+)%.$")
  if new_name then return { kind = "rename", name = new_name } end
  return nil
end

return M
