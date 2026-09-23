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
--
-- The verb alone is NOT enough to identify a tell: Discworld picks the say
-- verb from the sentence's punctuation, so a plain question spoken out loud
-- comes back as "You ask: ...?" — and with a language selected, as
--   "You ask in Morporkian: What alternatives did I have?"
-- which is a room say, not a tell. What separates the two is the *target*
-- between the verb and the framing ": ".
--
-- We can't lean on capitalisation to tell a target from a language clause:
-- the outgoing echo reproduces the recipient's name as the user typed it, so
-- "You ask dag: meet at drum?" is a perfectly ordinary tell. What a target
-- can never be is an "in <Language>" clause — a first name of literally "in"
-- followed by a capitalised family word — so that shape, and only that shape,
-- is rejected. Deliberately no list of Discworld languages: "in" plus a
-- capital is the structural marker, and it keeps working when the MUD adds a
-- language. (A lowercase family name after a real "in" — "in the Darrke" —
-- still routes as a tell, since languages are always capitalised.)
--
-- The target must also be name-shaped: word characters, spaces, apostrophes
-- and hyphens, the same free-form family-name charset is_incoming_tell
-- accepts (real examples: "Gin n Tonique", "Dacrian didn't do-it"). That
-- keeps a say whose body happens to contain ": " from looking like a target,
-- and still admits a tell sent in a language ("You tell Bob in Dwarfish:"),
-- whose target begins with the recipient's name rather than "in".
local function target_is_named(rest)
  if rest == nil then return false end
  local target = rest:match("^([%w '%-]+): ")
  if not target then return false end
  if target:match("^in %u") then return false end
  return true
end

local function is_outgoing_tell(line)
  local rest = line:match("^You [Tt]ell (.+)$")
            or line:match("^You %a+ [Tt]ell (.+)$")
            or line:match("^You exclaim to (.+)$")
            or line:match("^You %a+ exclaim to (.+)$")
            or line:match("^You ask (.+)$")
            or line:match("^You %a+ ask (.+)$")
  return target_is_named(rest)
end

-- Incoming tell: "Alice tells you:", "Bob exclaims to you:", "Carol asks you:".
--
-- The speaker is "<FirstName> <family name>", and a player's family name is
-- remarkably free-form: it can be several words, lowercase, and contain
-- apostrophes or hyphens (real examples: "Fenrir the misspeler", "Gnillot in
-- the Darrke", "Being nude in public", "Dacrian didn't do-it", "Gin n
-- Tonique"). So after the first name we accept a lazy run of word chars,
-- spaces, apostrophes and hyphens up to the verb. `.-you: ` then requires the
-- "you:" the MUD frames every directed tell with, which is what keeps this
-- from swallowing unrelated narrative.
--
-- The first name is NOT reliably capitalised either — "sYa" and "badteeth"
-- are real players whose tells this dropped wholesale while their channel
-- chatter came through fine. What carries the discrimination is the bare
-- "you: ", not the case of the first letter: Discworld frames NPC speech
-- directed at you with a language and accent clause first ("Klepton the Fixer
-- asks you in Ephebian with a nautical Ephebian accent: Need any help?"), so
-- room NPCs never produce a bare "you: " and stay out of the tells tab on
-- their own. The `^` anchor does the rest — the worked example in `help tell`
-- ("     Pinkfish tells you: bing") is indented, and so still ignored.
--
-- Keep this in sync with the live `mud.trigger` incoming-tell regex in
-- main.lua — that Rust-regex pre-filter gates whether classify() ever runs,
-- so anything it accepts this must accept too. tests/classifier_test.lua
-- exercises both against the real family-name set.
local function is_incoming_tell(line)
  if line:sub(1, 4) == "You " then return false end
  return line:match("^[A-Za-z][%w '%-]- tells.-you: ")       ~= nil
      or line:match("^[A-Za-z][%w '%-]- exclaims to.-you: ") ~= nil
      or line:match("^[A-Za-z][%w '%-]- asks.-you: ")        ~= nil
end

-- Bracketed channel: "[name] X says: ..." where name is not say/tell/soul/path/empty.
--
-- The body only has to *begin* with a letter. Quow's original demanded three
-- ("pretty much anything in square brackets followed by some letters"), an
-- arbitrary threshold that silently dropped every line whose first body word
-- is one or two letters: a speaker named "M Mirrour", and Discworld's own
-- group announcements ("[Sailors] By the power vested in Lyna, Kiki has been
-- appointed as the new leader of the group."). One letter still earns its
-- keep — the bracketed non-chat the MUD and client listings emit opens on
-- punctuation or a digit ("[1073] : There's Always A Catch.", "[X] 250 bonus
-- fi.un.gr"), so requiring a letter rejects it without guessing at word
-- lengths.
--
-- Known and accepted false positive: the Djelibeybi bazaar renders a market
-- stall inside its room description as "[embroidery] An eye-catching burgundy
-- tent sits boldly here." — same shape, not chat. Two such lines in 2.5M lines
-- of wire log, and nothing separates them structurally from a real group
-- announcement ("[sailing] The current leader has left the group."), which is
-- prose in the same voice. Leaving them in costs a stray Channels line and a
-- junk registry entry; they are not gagged, since new channels default to
-- gag_main = false. That is the cheaper error: every guard that has tried to
-- out-guess this shape so far has silently eaten real chat instead.
local function bracketed_channel(line)
  local ch = line:match("^%[([^%]]+)%] %a")
  if not ch then return nil end
  if ch == "say" or ch == "tell" or ch == "soul" or ch == " " then return nil end
  if ch:sub(1, 1) == "/" then return nil end
  return ch
end

-- Parens channel: "(name) X verb: ..." — same shape as bracketed
-- but with parens. No exclusion list (no `(say)` etc. that we know of).
--
-- One leading letter in the body, for the reasons in bracketed_channel.
-- Talkers are exactly where short first words turn up, because the bots
-- speaking on them are titled: "(Quiz) Mr Quiz wisps: Time's up!" was
-- invisible to the panel under the old three-letter rule. The letter still
-- turns away the inventory listing that shares this shape, since its body
-- opens on a colon ("(under) : a black backpack, ...").
--
-- Skips replayed history: when a player connects, the MUD redisplays
-- recent club chat with a timestamp inside the parens, e.g.
--   "(The Unsinkables May 27 09:10 PDT) aVocado: sol doesnt exist atm"
-- — these are scrollback, not live, and shouldn't be re-posted into
-- the chat panel.
local function parens_channel(line)
  local content = line:match("^%(([^%)]+)%) %a")
  if not content then return nil end
  -- " Mon DD HH:MM TZ" suffix marks a replayed-history line. Day may
  -- be space-padded for single digits ("Jun  4"), so allow ` +`. TZ
  -- may be multi-word (the MUD honours user-configured zones like
  -- "Sweden DST" alongside short codes like "PDT").
  if content:match(" %a+ +%d+ %d+:%d+ %a[%a ]*$") then return nil end
  return content
end

-- True if a channel-tagged line's body starts with "You " (the user's own
-- utterance into a bracketed/parens channel — e.g. "[Wizards] You say:").
-- `prefix_len` is the length of the leading "[name] " or "(name) " tag.
local function channel_body_is_self(line, prefix_len)
  return line:sub(prefix_len + 1, prefix_len + 4) == "You "
end

function M.classify(line, group_channel)
  if type(line) ~= "string" or line == "" then return nil end
  if is_outgoing_tell(line) then
    return { tab = "tells", incoming = false }
  end
  if is_incoming_tell(line) then
    return { tab = "tells", incoming = true }
  end
  local ch = bracketed_channel(line)
  if ch then
    local incoming = not channel_body_is_self(line, #ch + 3)
    if group_channel ~= nil and ch == group_channel then
      return { tab = "group", channel = ch, incoming = incoming }
    end
    return { tab = "channels", channel = ch, incoming = incoming }
  end
  local pch = parens_channel(line)
  if pch then
    -- Parens channels always go to channels tab (never group).
    local incoming = not channel_body_is_self(line, #pch + 3)
    return { tab = "channels", channel = pch, incoming = incoming }
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
  -- Capture the *bracketed* name, not the body. Discworld displays the new
  -- group name in brackets in its canonical form (auto-capitalised, truncated
  -- to ~15 chars with `...`), while the body carries the raw lowercase name
  -- the renamer typed. Future group says reuse the bracketed form, so storing
  -- the body name would orphan the Group tab — e.g. brackets `[ParanoidSmug...]`
  -- vs body `paranoidsmugglers`.
  local new_name = line:match("^%[([^%]]+)%] The group has been renamed to .+%.$")
  if new_name then return { kind = "rename", name = new_name } end
  return nil
end

return M
