-- Tag-colour slot validation for the settings_update boundary.
--
-- Colours are ANSI palette slots (0-15), not hex: the host pushes
-- --ansi-0..15 onto the panel iframe as theme vars, and Discworld's own
-- channel colours are ANSI too, so a slot renders the tag in exactly the
-- shade the main output pane uses -- and follows the user's theme. nil
-- means "no choice made", which the panel draws in --link.
--
-- Pure (no host-API dependencies) so it unit-tests under a vanilla `lua`,
-- same pattern as classifier.lua / flush_gate.lua.

local M = {}

-- The panel sends DEFAULT to clear a choice, since a JSON null can't
-- survive the round trip as a distinct-from-absent table value.
M.DEFAULT = -1

-- A slot in range, or nil for anything else. NaN is rejected explicitly:
-- math.floor(nan) is nan, and every comparison against nan is false, so a
-- plain range check would pass it straight through and we'd store a value
-- that can't be JSON-encoded on the way back out.
function M.sanitise(v)
  if type(v) ~= "number" then return nil end
  if v ~= v then return nil end
  local n = math.floor(v)
  if n < 0 or n > 15 then return nil end
  return n
end

-- Map a `colour` field from a settings_update delta to what should be
-- stored: a slot, or nil to clear. DEFAULT and any invalid value both
-- clear, so a panel that sends garbage resets the row rather than
-- wedging it.
--
-- Callers must test `delta.colour ~= nil` themselves -- an absent field
-- means "leave alone", which is not the same as clearing, and this
-- function can't distinguish the two from the value alone.
function M.resolve(v)
  if v == M.DEFAULT then return nil end
  return M.sanitise(v)
end

return M
