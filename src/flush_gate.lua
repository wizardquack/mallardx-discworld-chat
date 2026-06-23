-- Decide whether a debounced full-blob storage write should fire on a tick.
--
-- Both blobs this guards — the ~500-entry scrollback ring and the channel
-- registry — are persisted as single storage blobs. Rewriting a whole blob on
-- every tick that touched it is O(blob) work to save O(1) new changes: cheap
-- per write, but it recurs every few seconds for the life of the session and
-- occasionally stalls tens of ms on a SQLite checkpoint. Coalescing cuts the
-- number of full-blob writes without changing what ends up persisted.
--
-- Pure (no host-API dependencies) so it unit-tests under a vanilla `lua`,
-- same pattern as classifier.lua.

local M = {}

-- Returns true when the blob should be written now.
--   o.dirty       — are there unwritten changes?
--   o.force       — bypass coalescing (disconnect / plugin reload): never lose data
--   o.pending     — new entries queued since the last write
--   o.elapsed_s   — seconds since the last write
--   o.line_budget — write once this many entries have queued
--   o.max_age_s   — ...or once the oldest unwritten change is this old
function M.write_due(o)
  if not o.dirty then return false end
  if o.force then return true end
  if o.pending >= o.line_budget then return true end
  if o.elapsed_s >= o.max_age_s then return true end
  return false
end

return M
