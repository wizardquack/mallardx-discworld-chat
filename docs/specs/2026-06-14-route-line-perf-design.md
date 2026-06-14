# `route_line` perf — drop per-match storage I/O

**Date:** 2026-06-14
**Status:** Design — ready for plan
**Spec for:** reduce `discworld-chat`'s per-chat-line cost from ~22ms to <1ms by caching mutable state in module scope and debouncing history persistence.

## Problem

Field-observed timings from Mallard's Diagnostics report (session 2026-06-14, 57 min wallclock, 109 chat-line matches):

```
discworld-chat  engine.action
  n=109   fast_path_n=0
  p50 = 22.3 ms   p95 = 72.8 ms   p99 = 113.7 ms   max = 130.5 ms
```

Every single chat-line match takes ≥100µs (no fast-path hits) and the median is 22ms — more than one 60Hz frame's budget on its own. p99 of 114ms is genuinely user-noticeable hitch territory. Chat is an order-of-magnitude outlier among installed plugins; the next-worst engine.action `max_us` (sailing) is 11ms.

## Root cause

`route_line()` in `src/main.lua` does **2–6 SQLite round-trips per chat line**, plus full encode/decode of a ~50KB history blob on every match:

| Call | When | Cost |
|---|---|---|
| `storage.get("group_channel")` | every match | 1 small read |
| `load_sources()` → `storage.get(SOURCES_KEY)` | every match | 1 small read |
| `load_channels()` → `storage.get(CHANNELS_KEY)` | every channel-tab match | 1 read (channels map) |
| `save_channels()` → `storage.set(CHANNELS_KEY, …)` | every channel-tab match | 1 read + 1 write (size accounting) |
| `persist()` → `storage.get(HISTORY_KEY)` | every match | 1 read of 500-entry blob |
| `persist()` → `storage.set(HISTORY_KEY, …)` | every match | 1 read + 1 write of 500-entry blob |

Mallard's `host.storage_set` internally re-reads the old value for byte-quota accounting before writing, so every `set` is **a read + a write**. Combined with the JSON encode/decode in both directions (`lua_to_json` + `serde_json::to_string` on encode; mirror image on decode), a single channel-line match performs 2 reads + 1 write of a 61KB JSON blob, plus 2–4 small reads/writes of smaller blobs.

Isolated microbench (`src-tauri/tests/chat_persist_hypothesis.rs`) measures `persist()` alone at 4.8ms p50 on a clean idle SQLite db. The remaining ~17ms of field-observed median comes from:
- the other 4–5 small storage calls (~1ms each),
- Lua ↔ JSON conversion of a 500-entry table (`lua_to_json` walks the whole table recursively),
- shared SQLite-pool contention with the connection task, WorldLogger, and other plugins' storage ops.

The fix removes all per-match storage I/O.

## Approach summary

Cache every mutable state value in module-scope Lua locals. Only write to `storage` when the user changes settings (handled inside the existing `panel:on_message("settings_update", …)` handler) or on a debounced timer for the chat-line history. On disconnect / plugin teardown, flush the in-memory buffer one last time.

Three caches, three persist points:

1. **`channels` cache** — loaded once at module init; mutated in-place by `ensure_channel_entry()` (the `last_seen` / `count` bumps) and by `settings_update` deltas. Flushed on the same debounced timer as history, plus eagerly when a user-visible field (`listen` / `gag_main` / `pinned` / `sound`) changes.
2. **`sources` cache** — loaded once at module init; written-through whenever `settings_update` mutates a `tells` or `group` field. Small enough that write-through is cheap.
3. **`group_channel` cache** — loaded once at module init; invalidated/refreshed inside `set_group()`.
4. **`history` buffer** — loaded once at module init; appended in-memory by `persist()`; flushed every 5s by a `mud.schedule` timer and on `lifecycle.disconnect`.

## Approaches considered and rejected

- **Async-write `persist()`** (use `mud.schedule(0, …)` to defer the storage call off the trigger path). Doesn't help — the host API is synchronous, so `mud.schedule` just moves the latency to a different frame, not off it.
- **Sharded history keys** (one storage key per N entries). Reduces single-blob size but adds key-management complexity and doesn't help the small storage calls. YAGNI.
- **Drop history persistence entirely** (in-memory only). Loses scrollback across plugin reload and Mallard restart, which is a real feature. The 5s debounce is the right tradeoff.

## Architecture

All changes live in `src/main.lua`. The three caches plus the dirty-bit pattern look like this:

```lua
-- Module-scope caches, loaded once at top-level (before triggers register).
local channels_cache = storage.get(CHANNELS_KEY) or {}
local sources_cache  = load_sources()  -- existing function handles defaults
local group_channel  = storage.get("group_channel")
local history_buf    = storage.get(HISTORY_KEY) or {}

-- Dirty bits — drive the debounced flush.
local channels_dirty = false
local history_dirty  = false

local PERSIST_DEBOUNCE_MS = 5000
```

### `route_line()` after the fix

Pure cache reads on the hot path. The function no longer touches `storage` for the read side of:
- `group_channel` (uses cached local)
- `load_sources()` (returns `sources_cache`)
- `ensure_channel_entry()` (mutates `channels_cache` in-place, sets `channels_dirty = true`)
- `persist()` (appends to `history_buf`, sets `history_dirty = true`)

`panel:post("line", payload)` and `mud.play_sound(...)` remain unchanged — they're not storage calls.

### `settings_update` handler

When the user toggles a checkbox in the chat settings panel:
- For `delta.channel.*` fields (visible config: `listen` / `gag_main` / `pinned` / `sound` / `remove`): mutate `channels_cache`, then **flush eagerly** (`storage.set` + clear `channels_dirty`). User-initiated changes must survive a crash within the next 5s.
- For `delta.source.*` fields (`tells.gag_main`, `tells.sound`, `group.gag_main`, `group.sound`): mutate `sources_cache`, write-through to storage.

Both cases call `broadcast_settings()` as today.

### Background-mutation flush

`ensure_channel_entry()` bumps `last_seen` and `count` on every channel sighting. These aren't user-visible enough to justify a write per match, but losing them entirely on crash would degrade the per-channel stats. So they ride the 5s timer:

```lua
mud.schedule(PERSIST_DEBOUNCE_MS, function()
  if history_dirty then
    storage.set(HISTORY_KEY, history_buf)
    history_dirty = false
  end
  if channels_dirty then
    storage.set(CHANNELS_KEY, channels_cache)
    channels_dirty = false
  end
end, { repeat_ = true })
```

### Disconnect flush

`events.on("lifecycle.disconnect", flush)` covers clean disconnect (user clicks Disconnect, world drops the connection cleanly). A hard process crash within 5s of the last write still loses those writes — accepted tradeoff. See "Out of scope" below.

### `set_group()` cache invalidation

`set_group(name)` already writes `storage.set("group_channel", name_or_nil)`; now also updates `group_channel = name_or_nil` so subsequent matches see the new value without a re-read. Same call site, one extra line.

## Data flow on a chat line (after fix)

```
incoming line → mud.trigger fires → route_line() runs:
  1. read group_channel (cached local, O(1))
  2. classifier.classify(text, group_channel)  -- pure Lua
  3. read sources_cache (Lua table read, O(1))
  4. (if channels tab) mutate channels_cache[name].last_seen / count
                       set channels_dirty = true
  5. panel:post("line", payload)  -- Tauri emit, ~50µs
  6. push to history_buf, set history_dirty = true
  7. (if should_chime) mud.play_sound(...)
return gag bool

ZERO storage I/O on this path.

Every 5s:
  - if history_dirty:    one storage.set of 500-entry blob (~5ms)
  - if channels_dirty:   one storage.set of channels map (~1ms)

On settings_update:
  - eager flush of changed cache

On disconnect:
  - final flush of both dirty buffers
```

## Crash-loss tradeoffs

| Data | Before | After | Worst-case loss |
|---|---|---|---|
| Chat scrollback (`history`) | every match | every 5s + on disconnect | ≤5s of chat lines |
| Channel `last_seen` / `count` | every match | every 5s + on disconnect | ≤5s of bumps |
| User checkbox changes (`channels` visible fields, `sources`) | immediate | immediate (write-through) | 0 |
| Group membership (`group_channel`) | immediate | immediate (write-through via `set_group`) | 0 |

The asymmetry is deliberate: user actions persist immediately, automatic bookkeeping rides the debounce.

## Expected performance impact

From the isolated microbench:

| Metric | Before (per match) | After (per match) | After (per flush) |
|---|---|---|---|
| Storage round-trips | 2–6 reads + 1–2 writes | 0 | 1–2 writes |
| Median latency | 4.8ms (`persist` alone) | <10µs | ~5ms |
| Effective per-match (amortised over 5s window) | 4.8ms+ | <10µs + (5ms/N matches) | — |

For the field-observed 109 matches over 57 min: 12 flushes × 5ms = 60ms total flush cost, vs. 109 × ~22ms = ~2400ms today. **~40× less time spent in chat triggers.**

`engine.action` p50 should drop from 22ms to well under 1ms; `max_us` should drop to single-digit milliseconds (one match unlucky enough to land on a flush tick). `fast_path_n / n` should approach 100% — most calls return in <100µs.

## Out of scope

- **Zero-loss crash recovery.** A 500ms debounce or smaller would tighten the loss window. Not worth it: chat scrollback isn't load-bearing, and a process-crash mid-session is rare. The host's WorldLogger already captures every line to disk independently for the main output pane — chat's plugin storage is just a UI convenience.
- **Per-channel sub-tables.** The history blob carries `{tab, channel, text, ts}` per entry; splitting by `tab` or `channel` would reduce blob size but add cache-coherence complexity. The 50KB-blob cost is already eliminated by removing per-match writes; further sharding is YAGNI.
- **Migrating older entries off-disk.** Existing 500-entry storage values remain compatible; no schema change.
- **Optimising the small storage calls in other plugins.** Vitals, sailing, vault-tracker have lower-but-nonzero `engine.action` times that probably have the same shape; a follow-up plan can sweep them. Each plugin gets its own spec.

## Testing

`tests/route_line_test.lua` (or wherever the existing Lua tests run, if any). Three new cases:

1. **Cache invariants.** After a sequence of `route_line(line)` calls, the cached state matches what `storage.get(...)` would return after a flush.
2. **Debounced flush behaviour.** Two matches within 5s produce one flush; a `lifecycle.disconnect` between them produces an immediate flush.
3. **Settings update eagerness.** `settings_update` for a visible field triggers an immediate storage write; for a background-only field, it rides the debounce.

If the Lua test harness doesn't expose a fake `storage` shim, the test can stub it with a Lua table that records calls. The classifier already has unit tests in `tests/classifier_test.lua` — same pattern.

## Migration

None. Storage keys (`CHANNELS_KEY`, `SOURCES_KEY`, `ACTIVE_TAB_KEY`, `HISTORY_KEY`, `group_channel`) and value shapes are unchanged. A plugin upgrade picks up the new code; the next session loads the existing on-disk values into module-scope caches as normal.

Bump `version = "0.2.3"` in `plugin.toml`. CHANGELOG entry: "perf: cache mutable state in-memory; per-chat-line cost drops from ~22ms to <1ms (field-observed Mallard perf report, 2026-06-14)."

## Files

Modified:
- `src/main.lua` — all changes here.
- `plugin.toml` — version bump.
- `CHANGELOG.md` — release entry.

New:
- `tests/route_line_test.lua` — three new test cases (only if the existing tests already run from a harness; otherwise inline assertions in classifier_test.lua's spirit).
- `docs/specs/2026-06-14-route-line-perf-design.md` — this spec.
