-- Decide whether the debounced chat-history write should fire on a given tick.
--
-- The scrollback is persisted as a single storage blob (a ~500-entry ring).
-- Rewriting that whole blob on every tick that saw a chat line is O(history)
-- work to save O(1) new entries — cheap per write, but it recurs every few
-- seconds for the life of the session and occasionally stalls tens of ms on a
-- SQLite checkpoint. Coalescing cuts the number of full-blob writes without
-- changing what ends up persisted.
--
-- Pure (no host-API dependencies) so it unit-tests under a vanilla `lua`,
-- same pattern as classifier.lua.

local M = {}

-- Returns true when the history blob should be written now.
--   o.dirty       — are there unwritten history changes?
--   o.force       — bypass coalescing (disconnect / plugin reload): never lose data
--   o.pending     — new entries queued since the last write
--   o.elapsed_s   — seconds since the last write
--   o.line_budget — write once this many entries have queued
--   o.max_age_s   — ...or once the oldest unwritten change is this old
function M.history_due(o)
  if not o.dirty then return false end
  if o.force then return true end
  if o.pending >= o.line_budget then return true end
  if o.elapsed_s >= o.max_age_s then return true end
  return false
end

return M
