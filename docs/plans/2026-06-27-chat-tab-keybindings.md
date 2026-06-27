# Chat Tab Keyboard Navigation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let the user jump directly to a chat tab with `Ctrl+Shift+<digit>` via a plugin-defined, user-rebindable keymap layer.

**Architecture:** A manifest `[[keymaps]]` layer (`chat-tab-nav`) binds `Ctrl+Shift+1..9`/`Ctrl+Shift+0` to `mud.command` handlers in `main.lua`. Each handler `panel:post`s a `goto_index`/`goto_last` message to the chat iframe, which resolves the position against the current tab order and calls the existing `switchTab()`. Activation is gated by a `tab_keybindings` plugin setting (default on).

**Tech Stack:** Lua (plugin host runtime, Lua 5.4+), vanilla browser JS (`ui/chat.js`, classic `<script>`, no bundler/modules), TOML manifest. Tests: `node` for the pure JS helper, `lua` for existing pure-module tests.

## Global Constraints

- Plugin id `net.mallard.discworld-chat`; commits authored as `Wizard Quack <wizardquack@fastmail.com>` (repo-local git identity is already set).
- **No `Co-Authored-By` trailers** on commits.
- Default combo family is `Ctrl+Shift+<digit>` (the only cross-platform-safe family; `mod/Cmd/Ctrl+digit` is reserved by the host for main dock-tab switching). Combos are user-rebindable in Settings → Keymaps.
- Digit → **1-based strip position** in displayed order `[all, tells, group, …pins…, channels]`. `Ctrl+Shift+0` = last tab. Out-of-range = silent no-op.
- Activation source of truth is the `tab_keybindings` setting (so a reload never re-enables a layer the user turned off). Host Keymaps UI is for rebinding only.
- `chat.js` is a classic script using the global `panel` SDK (`panel.on` / `panel.post`); the panel handle in `main.lua` is `local panel = mud.panel("chat")` (`src/main.lua:15`), called with colon syntax (`panel:post`).
- Lua numeric `for` loop variables are per-iteration locals in Lua 5.4, so closures capture the correct value (no JS-style late-binding); do **not** reassign the loop variable.

---

### Task 1: Pure `tabIdForIndex` helper + node test

**Files:**
- Create: `ui/tab_index.js`
- Create: `tests/tab_index_test.js`

**Interfaces:**
- Produces: `tabIdForIndex(order: string[], index: number) → string | undefined`. Returns `order[index - 1]` for a 1-based `index` in `[1, order.length]`; returns `undefined` for a non-array `order`, a non-number `index`, or an out-of-range `index`. Exposed as a browser global (classic-script function declaration) **and** as `module.exports` for `node`/`require` via the `typeof module` dual-export idiom.

- [ ] **Step 1: Write the failing test**

Create `tests/tab_index_test.js` (hand-rolled harness mirroring the style of `tests/classifier_test.lua` — print `ok`/`FAIL`, non-zero exit on failure):

```js
// Pure tests for tabIdForIndex. Run with: node tests/tab_index_test.js
// tab_index.js has no DOM/host dependencies, so plain node is enough.
const { tabIdForIndex } = require("../ui/tab_index.js");

let failures = 0;
function check(label, got, want) {
  if (got === want) {
    console.log("ok   " + label);
  } else {
    failures++;
    console.log("FAIL " + label + " — got " + String(got) + ", want " + String(want));
  }
}

const order = ["all", "tells", "group", "channel:foo", "channel:bar", "channels"];
check("index 1 -> all",              tabIdForIndex(order, 1), "all");
check("index 3 -> group",            tabIdForIndex(order, 3), "group");
check("index 4 -> first pin",        tabIdForIndex(order, 4), "channel:foo");
check("index 6 (last) -> channels",  tabIdForIndex(order, 6), "channels");
check("last via order.length",       tabIdForIndex(order, order.length), "channels");
check("index 7 (past end) -> undef", tabIdForIndex(order, 7), undefined);
check("index 0 -> undef",            tabIdForIndex(order, 0), undefined);
check("non-number -> undef",         tabIdForIndex(order, undefined), undefined);
check("non-array -> undef",          tabIdForIndex(null, 1), undefined);

const minimal = ["all", "tells", "group"]; // no pins
check("no pins: last -> group",      tabIdForIndex(minimal, minimal.length), "group");

if (failures > 0) {
  console.log("\n" + failures + " failure(s)");
  process.exit(1);
}
console.log("\nall passed");
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd ~/code/mallardx-discworld-chat && node tests/tab_index_test.js`
Expected: FAIL — `Cannot find module '../ui/tab_index.js'` (file not created yet).

- [ ] **Step 3: Write minimal implementation**

Create `ui/tab_index.js`:

```js
// Pure helper: map a 1-based strip position to a tab id.
// Shared by chat.js (loaded as a browser global) and tests (node require).
// The strip order is `[all, tells, group, ...pinned channels..., channels]`;
// callers pass that array from computeTabOrder(). goto_last is expressed as
// tabIdForIndex(order, order.length), so the "last tab" path reuses this too.
function tabIdForIndex(order, index) {
  if (!Array.isArray(order)) return undefined;
  if (typeof index !== "number" || index < 1 || index > order.length) {
    return undefined;
  }
  return order[index - 1];
}

// Dual export: in the browser `module` is undefined and `tabIdForIndex`
// stays a global; under node the test can require() it.
if (typeof module !== "undefined" && module.exports) {
  module.exports = { tabIdForIndex };
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd ~/code/mallardx-discworld-chat && node tests/tab_index_test.js`
Expected: every line `ok`, final line `all passed`, exit code 0.

- [ ] **Step 5: Commit**

```bash
cd ~/code/mallardx-discworld-chat
git add ui/tab_index.js tests/tab_index_test.js
git commit -m "feat(ui): pure tabIdForIndex helper for keyboard tab nav"
```

---

### Task 2: Wire the helper into the chat iframe

**Files:**
- Modify: `ui/chat.html:7`
- Modify: `ui/chat.js` (add handlers after the `panel.on("settings", …)` block, ~line 606)

**Interfaces:**
- Consumes: `tabIdForIndex` (Task 1, browser global); existing `computeTabOrder()` (`chat.js:146`) and `switchTab(id)` (`chat.js:282`); global `panel.on` SDK.
- Produces: the iframe responds to `panel:post("goto_index", { index })` and `panel:post("goto_last", {})` by switching the active tab.

- [ ] **Step 1: Load the helper before chat.js**

In `ui/chat.html`, change line 7 from:

```html
  <script src="chat.js" defer></script>
```

to:

```html
  <script src="tab_index.js" defer></script>
  <script src="chat.js" defer></script>
```

(`defer` preserves document order, so `tab_index.js` runs first and defines the global before `chat.js` uses it; both are classic scripts sharing global scope.)

- [ ] **Step 2: Add the goto handlers in chat.js**

In `ui/chat.js`, immediately after the existing `panel.on("settings", (payload) => { … });` handler (the block ending around line 606), add:

```js
// Keyboard tab navigation. main.lua's chat_tab_<n> / chat_tab_last
// commands (bound by the "chat-tab-nav" keymap layer) post these. We
// resolve the 1-based strip position against the *current* tab order
// and reuse switchTab(), so seen-marking, re-render, and active_tab
// persistence all happen exactly as on a click. Out-of-range = no-op.
panel.on("goto_index", (payload) => {
  const index = payload && payload.index;
  const id = tabIdForIndex(computeTabOrder(), index);
  if (id) switchTab(id);
});

panel.on("goto_last", () => {
  const order = computeTabOrder();
  const id = tabIdForIndex(order, order.length);
  if (id) switchTab(id);
});
```

- [ ] **Step 3: Verify the helper is still green (no regression in the pure unit)**

Run: `cd ~/code/mallardx-discworld-chat && node tests/tab_index_test.js`
Expected: `all passed` (the handlers are thin glue over the tested helper; full behavior is exercised in the Task 4 end-to-end smoke once the Lua side exists).

- [ ] **Step 4: Commit**

```bash
cd ~/code/mallardx-discworld-chat
git add ui/chat.html ui/chat.js
git commit -m "feat(ui): handle goto_index/goto_last tab-nav messages"
```

---

### Task 3: Manifest layer, settings toggle, and Lua command/activation wiring

**Files:**
- Modify: `plugin.toml` (append `[[keymaps]]` block and `[settings.tab_keybindings]`)
- Modify: `src/main.lua` (add command registration + activation after the `panel:on_message("active_tab", …)` block, ~line 273)

**Interfaces:**
- Consumes: `mud.command(name, fn, opts)` (registers a named command; `{ hidden = true }` is a host-supported opt that keeps the command out of the command palette — `mallard/src-tauri/src/plugins/lua_api/mud.rs:2182`, test `mud_command_hidden_option_sets_entry_hidden`); `mud.keymap.activate(name)` / `mud.keymap.deactivate(name)` (as used in the user's own sailing plugin, `mallardx-discworld-sailing/src/smuggling.lua:330,348`); `settings.get(key)` and `settings.on("change", fn)` (fires `(key, new, old)`); module-scope `panel` handle (`src/main.lua:15`, colon-call `panel:post`, matching the house `mud.panel` pattern in `mallardx-discworld-vitals/src/main.lua:20`).
- Produces: keymap layer `chat-tab-nav` and commands `chat_tab_1`..`chat_tab_9`, `chat_tab_last`, each posting to the chat panel; the layer is activated on load iff `tab_keybindings` is true and tracks the setting live.

- [ ] **Step 1: Add the keymap layer + setting to plugin.toml**

Append to the end of `plugin.toml` (after the `[panels.chat]` table — these are new top-level tables, so ordering is safe):

```toml
[[keymaps]]
name = "chat-tab-nav"

[[keymaps.bindings]]
combo   = "Ctrl+Shift+1"
command = "chat_tab_1"
label   = "Chat: go to tab 1 (All)"

[[keymaps.bindings]]
combo   = "Ctrl+Shift+2"
command = "chat_tab_2"
label   = "Chat: go to tab 2 (Tells)"

[[keymaps.bindings]]
combo   = "Ctrl+Shift+3"
command = "chat_tab_3"
label   = "Chat: go to tab 3 (Group)"

[[keymaps.bindings]]
combo   = "Ctrl+Shift+4"
command = "chat_tab_4"
label   = "Chat: go to tab 4"

[[keymaps.bindings]]
combo   = "Ctrl+Shift+5"
command = "chat_tab_5"
label   = "Chat: go to tab 5"

[[keymaps.bindings]]
combo   = "Ctrl+Shift+6"
command = "chat_tab_6"
label   = "Chat: go to tab 6"

[[keymaps.bindings]]
combo   = "Ctrl+Shift+7"
command = "chat_tab_7"
label   = "Chat: go to tab 7"

[[keymaps.bindings]]
combo   = "Ctrl+Shift+8"
command = "chat_tab_8"
label   = "Chat: go to tab 8"

[[keymaps.bindings]]
combo   = "Ctrl+Shift+9"
command = "chat_tab_9"
label   = "Chat: go to tab 9"

[[keymaps.bindings]]
combo   = "Ctrl+Shift+0"
command = "chat_tab_last"
label   = "Chat: go to last tab (Channels)"

[settings.tab_keybindings]
type    = "bool"
default = true
label   = "Tab navigation keybindings"
description = "When on, Ctrl+Shift+1..9 jump to the 1st–9th chat tab and Ctrl+Shift+0 jumps to the last tab (Channels). Edit the combos in Settings → Keymaps (layer 'chat-tab-nav'). Turn off to leave your keymap untouched."
```

- [ ] **Step 2: Register the commands + activation logic in main.lua**

In `src/main.lua`, immediately after the `panel:on_message("active_tab", …)` block (ends ~line 273, just before the `-- Line dispatch.` section comment), insert:

```lua
-- ---------------------------------------------------------------------
-- Keyboard tab navigation.
--
-- The "chat-tab-nav" keymap layer (plugin.toml) binds Ctrl+Shift+1..9 /
-- Ctrl+Shift+0 to these commands. Each posts a 1-based strip position to
-- the iframe, which maps it to a tab and switches. Commands are hidden
-- from the command palette — they exist only as keymap targets. The
-- `tab_keybindings` setting is the single source of truth for whether the
-- layer is active, so a reload never re-enables a layer the user disabled.
-- ---------------------------------------------------------------------

for i = 1, 9 do
  mud.command("chat_tab_" .. i, function()
    panel:post("goto_index", { index = i })
  end, { hidden = true })
end

mud.command("chat_tab_last", function()
  panel:post("goto_last", {})
end, { hidden = true })

local function apply_tab_keymap()
  if settings.get("tab_keybindings") then
    mud.keymap.activate("chat-tab-nav")
  else
    mud.keymap.deactivate("chat-tab-nav")
  end
end

settings.on("change", function(key, new_val)
  if key == "tab_keybindings" then
    apply_tab_keymap()
  end
end)

apply_tab_keymap()
```

- [ ] **Step 3: Syntax-check the Lua loads**

Run: `cd ~/code/mallardx-discworld-chat && luac -p src/main.lua 2>&1 || lua -e "assert(loadfile('src/main.lua'))"`
Expected: no output / no syntax error. (This only parses — it does not execute host APIs. `luac`/`lua` may be absent; if so, skip and rely on Step 4's load in the app.)

- [ ] **Step 4: Confirm existing pure-module tests still pass**

Run: `cd ~/code/mallardx-discworld-chat && lua tests/classifier_test.lua && lua tests/flush_gate_test.lua`
Expected: all `ok`, no `FAIL` lines, exit 0 (these are untouched; this is a regression guard).

- [ ] **Step 5: Commit**

```bash
cd ~/code/mallardx-discworld-chat
git add plugin.toml src/main.lua
git commit -m "feat: chat-tab-nav keymap layer + Ctrl+Shift+digit tab jumps"
```

---

### Task 4: End-to-end verification + version bump

**Files:**
- Modify: `plugin.toml:3` (`version`)

**Interfaces:**
- Consumes: everything from Tasks 1–3, loaded in the running app.

- [ ] **Step 1: Manual end-to-end smoke in the app**

Launch Mallard with this plugin installed against the Discworld world (`cd ~/code/mallard && npm run tauri dev`), open the Chat panel, then verify:

1. Pin two channels (gear → pin two channels) so the strip is `All | Tells | Group | <pinA> | <pinB> | Channels`.
2. `Ctrl+Shift+1` → All; `Ctrl+Shift+2` → Tells; `Ctrl+Shift+3` → Group.
3. `Ctrl+Shift+4` → first pinned channel; `Ctrl+Shift+5` → second pinned channel.
4. `Ctrl+Shift+0` → Channels (last tab), regardless of pin count.
5. `Ctrl+Shift+9` with only 6 tabs present → nothing happens (silent no-op).
6. With focus in the host input box, `Ctrl+Shift+4` still switches the tab (modifier combos are not suppressed in text inputs — confirms the spec's open question; if it does NOT fire, note it and stop for a design follow-up).
7. Settings → Keymaps shows the `chat-tab-nav` layer with the labelled bindings, and rebinding one (e.g. `Ctrl+Shift+4` → `Alt+4`) then pressing the new combo switches the tab.
8. Toggle the plugin's `Tab navigation keybindings` setting off → the combos stop working without a reload; on → they work again.

Expected: all eight behave as described.

- [ ] **Step 2: Bump the plugin version**

In `plugin.toml`, change line 3 from:

```toml
version = "0.3.1"
```

to:

```toml
version = "0.4.0"
```

(Minor bump — additive feature. Packaging/marketplace publication of the new version is a separate flow, out of scope for this plan.)

- [ ] **Step 3: Final test sweep**

Run:
```bash
cd ~/code/mallardx-discworld-chat
node tests/tab_index_test.js && lua tests/classifier_test.lua && lua tests/flush_gate_test.lua
```
Expected: `all passed` from the node test and all `ok` from the Lua tests, exit 0.

- [ ] **Step 4: Commit**

```bash
cd ~/code/mallardx-discworld-chat
git add plugin.toml
git commit -m "chore(release): v0.4.0 — chat tab keyboard navigation"
```

---

## Notes for the implementer

- **No JS test runner exists in this repo** — that is intentional. The only automated JS test is the standalone `node tests/tab_index_test.js`; the iframe message handlers (Task 2) are thin glue verified by the Task 4 manual smoke, exactly as the plugin's other UI code is.
- **Why a pure helper file:** `chat.js` loads with DOM globals at top level and cannot be `require`d in node. Extracting `tabIdForIndex` into `ui/tab_index.js` keeps the testable logic importable while staying a plain browser global — the JS parallel to this plugin's pure-Lua-module-tested-with-vanilla-`lua` convention.
- **Do not** try to make a keypress reveal/focus a hidden chat panel — there is no host `panel:focus()` API (deferred in the host design). v1 switches the internal tab only; this is documented in the spec as a known limitation.
