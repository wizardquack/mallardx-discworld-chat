# Chat tab keyboard navigation

**Date:** 2026-06-27
**Status:** Design — ready for plan
**Spec for:** let the user jump directly to a chat tab by keyboard (`Ctrl+Shift+<digit>`) instead of clicking, via a plugin-defined, user-rebindable keymap layer.

## Problem

The chat panel renders a horizontal tab strip — `[All, Tells, Group, …pinned channels…, Channels]` — and the only way to switch tabs is clicking (or picking from the overflow `•••` popover when tabs don't fit). There is no keyboard navigation at all (`chat.js` binds exactly one key today: `Enter` to submit the add-channel field). A user watching several pinned channels has to mouse over to the strip and click every time they want to focus a channel, which is slow and breaks flow during active play.

We want a fast, predictable, muscle-memory-friendly way to land on a specific tab from the keyboard.

## Goals

- Press a number-row chord to jump to the Nth tab in the strip.
- Stable enough for muscle memory: the same chord lands on the same tab across a normal session.
- User-rebindable through Mallard's standard Settings → Keymaps UI.
- On out of the box, but trivially switch-off-able.

## Non-goals

- **No new tab-ordering UI.** We key off the strip's existing displayed order; we do not add drag-to-reorder or an explicit order field. (See *Ordering* below — the existing order is effectively stable in practice.)
- **No panel reveal/focus on keypress.** There is no host `panel:focus()` / reveal API today (deferred in `mallard/docs/.../2026-05-17-plugin-webview-rpc-design.md` §7). Switching is internal to the panel; see *Known limitation*.
- **No per-channel "stable slot" pinning.** A digit maps to a *position*, not to a fixed channel identity.

## Decisions & rationale

### Navigation model — full strip, displayed order
A digit maps to a **position in the strip as displayed**, not to pinned-channels-only:

| Chord | Tab |
|-------|-----|
| `Ctrl+Shift+1` | All |
| `Ctrl+Shift+2` | Tells |
| `Ctrl+Shift+3` | Group |
| `Ctrl+Shift+4` | 1st pinned channel |
| `Ctrl+Shift+5` | 2nd pinned channel |
| … | … |
| `Ctrl+Shift+9` | 9th tab in strip |
| `Ctrl+Shift+0` | **last** tab (Channels) |

- One consistent scheme covers every tab kind.
- `Ctrl+Shift+0 → last tab` is browser-idiomatic (cf. `Cmd+9` = last tab) and gives the **Channels** aggregator a stable chord. Channels otherwise floats to a pin-count-dependent position (position `4 + pinCount`) and becomes unreachable by digit once there are ≥ 6 pins.
- Positions beyond the 9th tab are click-only. A digit whose slot has no tab is a **silent no-op**.

### Ordering — existing displayed order (no new concept)
`chat.js` sorts pinned channels by `last_seen` descending, but `renderTabs()` only recomputes on `switchTab`, `openSettings`, a `settings` broadcast, resize, and mount — **not** on incoming lines. So the strip does not reshuffle as messages arrive; the order is stable through normal use and only re-evaluates on those infrequent events. We accept this existing order as the index basis rather than introducing a deliberately-arranged order.

### Combo family — `Ctrl+Shift+<digit>`, rebindable
- `mod+digit` / `Cmd+1..9` and (on non-mac, where `mod`=Ctrl) plain `Ctrl+digit` are **reserved by the host** for main dock-tab switching (`mallard/src-tauri/src/plugins/host.rs` `builtin_shortcut_combos`: `Cmd+1..9`; a plugin binding these is recorded but never fires). `Cmd+Shift+3/4/5` are macOS screenshots. `Alt+digit` emits special characters on macOS and risks inserting garbage when focus is in the input box. F-keys are intercepted by OS/hardware functions on many laptops.
- `Ctrl+Shift+<digit>` is the only family with no known hard conflict on any platform, and `Ctrl` is the same physical key cross-platform. The three-key chord is the cost; users who prefer a two-key chord can rebind.
- Shipped as the **default**; every binding is rebindable in Settings → Keymaps (the layer surfaces there with per-binding labels).

### Activation — auto-on, gated by a host plugin setting
- New `[settings]` entry `tab_keybindings` (bool, default `true`).
- On plugin load, register the command handlers, then `if settings.get("tab_keybindings") then mud.keymap.activate("chat-tab-nav") end`. React to the setting changing (activate / deactivate live).
- **The plugin setting is the source of truth for activation-on-load**, so a plugin reload does not re-enable the layer for a user who turned it off. The host Settings → Keymaps UI is for *rebinding combos and editing the layer*, not the primary on/off switch.

## Architecture & data flow

```
Ctrl+Shift+4
   │  (host keymap layer "chat-tab-nav")
   ▼
command "chat_tab_4"   (mud.command handler in main.lua)
   │
   ▼
panel:post("goto_index", { index = 4 })
   │  (iframe message)
   ▼
chat.js:  id = tabIdForIndex(computeTabOrder(), 4);  if (id) switchTab(id)
```

`Ctrl+Shift+0` follows the same path through `command "chat_tab_last"` → `panel:post("goto_last")`.

### `plugin.toml`
- New `[[keymaps]]` block:
  - `name = "chat-tab-nav"`
  - 10 `[[keymaps.bindings]]`: `Ctrl+Shift+1..9` → `command = "chat_tab_1".."chat_tab_9"`; `Ctrl+Shift+0` → `command = "chat_tab_last"`. Each with a human `label` (e.g. `"Chat: go to tab 4"`, `"Chat: go to last tab (Channels)"`).
- New `[settings]` entry: `tab_keybindings`, bool, default `true`, with a description for the host plugin-settings UI.

### `src/main.lua`
- Register handlers on load (loop): `for i = 1, 9 do mud.command("chat_tab_" .. i, function() panel:post("goto_index", { index = i }) end) end`, plus `mud.command("chat_tab_last", function() panel:post("goto_last") end)`.
- Activation gate driven by `settings.get("tab_keybindings")`; activate/deactivate `"chat-tab-nav"` on load and whenever the setting changes.
- Uses the existing `panel` handle (`local panel = mud.panel("chat")`, `main.lua:15`).

### `ui/chat.js`
- New pure helper `tabIdForIndex(order, index)` — returns `order[index - 1]` or `undefined` when out of range. Unit-testable in isolation.
- `panel.on("goto_index", ({ index }) => { const id = tabIdForIndex(computeTabOrder(), index); if (id) switchTab(id); })`.
- `panel.on("goto_last", () => { const order = computeTabOrder(); switchTab(order[order.length - 1]); })`.
- Reuses the existing `switchTab()`, which already marks the buffer seen, re-renders, and posts `active_tab` for persistence. No change to `switchTab` itself.

## Known limitation (v1 scope)

Switching is **internal to the panel only**. With no host `panel:focus()` / reveal API, a keypress cannot surface the chat panel if it is hidden or sitting in a background dock group — the correct tab is selected, but the user won't *see* it until they surface the panel. In practice the panel defaults to `dock = "below"` (usually visible), so this is an edge case. A host-side reveal API is a possible later follow-up, out of scope here.

A second, smaller note: the chat panel may not be mounted when a chord fires (panel closed). `panel:post` to an unmounted panel is dropped by the host dispatcher; the chord is then a no-op. Acceptable for v1.

## Testing

- **Unit (`ui/`):** `tabIdForIndex(order, index)` — in-range hit, out-of-range → `undefined` (no-op), and `goto_last` resolves to the final element for representative strips (no pins; several pins).
- **Lua:** activation gating — with `tab_keybindings` true the layer activates on load; flipping the setting false deactivates; flipping back re-activates. Command handlers post the expected `goto_index` / `goto_last` payloads.
- **Manual / e2e smoke:** pin two channels; press `Ctrl+Shift+1/4/5/0` and confirm the active tab matches All / 1st pin / 2nd pin / Channels; press a digit past the last slot and confirm nothing happens. Verify chords fire while focus is in the host input box (modifier combos are not suppressed in text fields — confirm in the plan against `userKeymaps.matchCombo` behavior).

## Open questions

None blocking. The one item to confirm during implementation: that a `Ctrl+Shift+<digit>` plugin keymap binding fires while focus is in a text input (expected, since it carries modifiers — `userKeymaps.spec.ts` shows modifier combos matching with `focusInTextInput = true`).
