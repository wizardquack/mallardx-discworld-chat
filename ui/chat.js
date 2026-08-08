// Discworld Chat — panel UI logic.
//
// Receives :post("line", { tab, channel, text, ts }) and :post("settings", …)
// messages from the Lua side via Mallard's panel SDK. Maintains per-tab
// FIFO ring buffers; renders only the active tab.
//
// Tabs: all, tells, group, <pinned channels as "channel:<name>">, channels.
// Pinned tabs come from `settings.channels` entries with `pinned=true`.

const BUFFER_MAX = 1000;
const FIXED_TABS = ["all", "tells", "group"];

const buffers = {};
const tabOrder = [];
let activeTab = "all";
let settings = { channels: {}, sources: { tells: { gag_main: false }, group: { gag_main: false } } };
let view = "chat"; // "chat" or "settings"

const tabsEl = document.getElementById("tabs");
const scrollback = document.getElementById("scrollback");
const settingsEl = document.getElementById("settings");
const sourcesEl = document.getElementById("sources");
const channelsEl = document.getElementById("channels");
const addChannelEl = document.getElementById("add-channel");
const overflowPopover = document.getElementById("overflow-popover");
const colourMenu = document.getElementById("colour-menu");

// ANSI_COLOURS / COLOUR_DEFAULT / colourVar / tagColourSlot /
// colourSignature come from colour.js, loaded ahead of this script.

function pad(n) { return n < 10 ? "0" + n : "" + n; }
function formatTime(unix) {
  const d = new Date(unix * 1000);
  return `${pad(d.getHours())}:${pad(d.getMinutes())}:${pad(d.getSeconds())}`;
}

function formatRelative(unix) {
  if (!unix) return "never";
  const dt = Math.floor(Date.now() / 1000) - unix;
  if (dt < 60) return `${dt}s ago`;
  if (dt < 3600) return `${Math.floor(dt / 60)}m ago`;
  if (dt < 86400) return `${Math.floor(dt / 3600)}h ago`;
  return `${Math.floor(dt / 86400)}d ago`;
}

function escapeHtml(s) {
  return String(s).replace(/[&<>"']/g, c => ({
    "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;"
  }[c]));
}

// URL autolinking — mirrors src-tauri/src/url_autolink.rs in Mallard proper
// so links in plugin content behave the same as links in the main output:
// the same shapes match (http(s)://, www., mailto:, bare host/path), the
// same trailing-punctuation trim runs, and the same "bare host with no path"
// guard prevents false positives on file names like `connection.lua`.
const URL_RE = new RegExp(
  [
    "https?://[^\\s<>\"'`]+",
    "www\\.[^\\s<>\"'`]+",
    "mailto:[^\\s<>\"'`]+",
    "[A-Za-z0-9][A-Za-z0-9-]*(?:\\.[A-Za-z0-9][A-Za-z0-9-]+)+/[^\\s<>\"'`]+",
  ].join("|"),
  "g",
);

function trimTrailingPunctuation(matched) {
  let end = matched.length;
  while (end > 0) {
    const c = matched[end - 1];
    if (c === "." || c === "," || c === ";" || c === ":" || c === "!" || c === "?") {
      end -= 1;
      continue;
    }
    const pair = c === ")" ? ["(", ")"]
      : c === "]" ? ["[", "]"]
      : c === "}" ? ["{", "}"]
      : c === ">" ? ["<", ">"]
      : null;
    if (!pair) break;
    const prefix = matched.slice(0, end);
    let opens = 0, closes = 0;
    for (const ch of prefix) { if (ch === pair[0]) opens++; else if (ch === pair[1]) closes++; }
    if (closes > opens) end -= 1; else break;
  }
  return matched.slice(0, end);
}

function linkTarget(matched) {
  if (matched.startsWith("http://") || matched.startsWith("https://") || matched.startsWith("mailto:")) {
    return matched;
  }
  return "https://" + matched;
}

// Build a document fragment from `text`, with detected URLs as anchors that
// route clicks through `panel.openUrl`. Anchors carry `href` so right-click
// "Copy link" works and middle-clickability surfaces; the click handler
// preventDefaults to keep the iframe from navigating away from itself.
function renderTextWithLinks(text) {
  const frag = document.createDocumentFragment();
  let cursor = 0;
  URL_RE.lastIndex = 0;
  let m;
  while ((m = URL_RE.exec(text)) !== null) {
    const matched = trimTrailingPunctuation(m[0]);
    if (!matched) continue;
    const start = m.index;
    const end = start + matched.length;
    // Resync regex past the trimmed match so e.g. a stripped trailing "." can
    // still be the start of a fresh consideration on the next iteration.
    URL_RE.lastIndex = end;
    if (start > cursor) frag.appendChild(document.createTextNode(text.slice(cursor, start)));
    const a = document.createElement("a");
    a.className = "url";
    a.textContent = matched;
    a.href = linkTarget(matched);
    a.rel = "noopener noreferrer";
    a.addEventListener("click", onUrlClick);
    a.addEventListener("auxclick", onUrlClick);
    frag.appendChild(a);
    cursor = end;
  }
  if (cursor === 0) {
    frag.appendChild(document.createTextNode(text));
  } else if (cursor < text.length) {
    frag.appendChild(document.createTextNode(text.slice(cursor)));
  }
  return frag;
}

function onUrlClick(e) {
  // Left and middle clicks; ignore modifier-clicks so the user can still
  // select-and-drag a URL into the system clipboard via Cmd+drag etc.
  if (e.type === "auxclick" && e.button !== 1) return;
  if (e.button !== undefined && e.button !== 0 && e.button !== 1) return;
  e.preventDefault();
  const url = e.currentTarget.href;
  if (typeof panel.openUrl === "function") panel.openUrl(url);
}

// Pinned channel tabs ordered by last_seen desc.
function pinnedChannels() {
  return Object.entries(settings.channels)
    .filter(([, e]) => e.pinned)
    .sort((a, b) => (b[1].last_seen || 0) - (a[1].last_seen || 0))
    .map(([name]) => name);
}

function computeTabOrder() {
  const pins = pinnedChannels().map(name => `channel:${name}`);
  return [...FIXED_TABS, ...pins, "channels"];
}

function ensureBuffer(tabId) {
  if (!buffers[tabId]) buffers[tabId] = [];
  return buffers[tabId];
}

function tabLabel(tabId) {
  if (tabId === "all") return "All";
  if (tabId === "tells") return "Tells";
  if (tabId === "group") return "Group";
  if (tabId === "channels") return "Channels";
  if (tabId.startsWith("channel:")) return tabId.slice("channel:".length);
  return tabId;
}

function renderLine({ tab, channel, text, ts }) {
  const el = document.createElement("div");
  el.className = "line";
  const tag = channel ? `[${channel}]` : (tab === "tells" ? "[tells]" : "");
  let body = text;
  if (channel) {
    const bracketPrefix = `[${channel}] `;
    const parenPrefix   = `(${channel}) `;
    if (body.startsWith(bracketPrefix)) body = body.slice(bracketPrefix.length);
    else if (body.startsWith(parenPrefix)) body = body.slice(parenPrefix.length);
  }
  el.innerHTML = `<span class="ts">${formatTime(ts)}</span>`;
  if (tag) {
    // Built as a node rather than interpolated: the tag carries a
    // MUD-supplied channel name, and it now carries a style too.
    const tagEl = document.createElement("span");
    tagEl.className = "tag";
    tagEl.textContent = tag;
    const slot = tagColourSlot(settings, tab, channel);
    if (slot !== null) tagEl.style.color = colourVar(slot);
    el.appendChild(tagEl);
  }
  el.appendChild(renderTextWithLinks(body));
  return el;
}

function isPinnedToBottom() {
  return scrollback.scrollHeight - scrollback.scrollTop - scrollback.clientHeight < 16;
}

// Every line goes to "all". Channel lines route to "channels" (the master
// channel roll-up) and additionally to "channel:<name>" when the channel
// is pinned — pinned tabs are focused *additional* views, not replacements
// for the Channels tab. The Lua side stamps payload.tab as either
// "channels" or "channel:<name>"; we fan pinned ones back into "channels"
// here so the catch-all stays complete.
function bufferPush(entry) {
  // Pre-mark seen if the entry is going to be visible right now, so the
  // tab the user is on never lights up its own dot for content it just
  // displayed.
  if (view === "chat" && entryBelongsInTab(entry, activeTab)) {
    entry.seen = true;
  }
  const targets = new Set(["all", entry.tab]);
  if (typeof entry.tab === "string" && entry.tab.startsWith("channel:")) {
    targets.add("channels");
  }
  for (const t of targets) {
    const buf = ensureBuffer(t);
    buf.push(entry);
    if (buf.length > BUFFER_MAX) buf.shift();
  }
  return targets;
}

// Unread state is tracked per-line via `entry.seen`. A tab has its dot
// iff its buffer holds any unseen entry. Because the same entry object
// is shared across the buffers it routes to (all + tab + maybe
// "channels"), flipping `seen = true` while viewing one tab silently
// clears the same line's contribution to every other tab too — so
// viewing Group not only clears Group's dot but also All's, when the
// Group message was the only unseen thing in All.
//
// Tab ids currently collapsed into the overflow "•••" button. Set by
// collapseOverflow; consulted by refreshUnreadDots so the overflow
// trigger lights up when a hidden tab has unread.
let overflowHiddenIds = [];

function isTabUnread(tabId) {
  const buf = buffers[tabId];
  if (!buf) return false;
  for (let i = 0; i < buf.length; i++) {
    if (!buf[i].seen) return true;
  }
  return false;
}

// Mark every entry in `tabId`'s buffer as seen. Entries are shared
// across buffers, so this clears the contribution of those entries in
// every tab that also holds them.
function markBufferSeen(tabId) {
  const buf = buffers[tabId];
  if (!buf) return;
  for (let i = 0; i < buf.length; i++) buf[i].seen = true;
}

function refreshUnreadDots() {
  const order = computeTabOrder();
  for (const id of order) {
    const flag = isTabUnread(id);
    const sel = `.tab[data-tab="${CSS.escape(id)}"]`;
    for (const btn of tabsEl.querySelectorAll(sel)) btn.classList.toggle("has-unread", flag);
    for (const btn of overflowPopover.querySelectorAll(sel)) btn.classList.toggle("has-unread", flag);
  }
  const overflowBtn = tabsEl.querySelector(".tab.overflow");
  if (overflowBtn) {
    overflowBtn.classList.toggle("has-unread", overflowHiddenIds.some(id => isTabUnread(id)));
  }
}

function entryBelongsInTab(entry, tab) {
  if (tab === "all") return true;
  if (tab === entry.tab) return true;
  if (tab === "channels" && typeof entry.tab === "string" && entry.tab.startsWith("channel:")) return true;
  return false;
}

function appendToActive(entry) {
  if (view !== "chat") return;
  if (!entryBelongsInTab(entry, activeTab)) return;
  const wasPinned = isPinnedToBottom();
  scrollback.appendChild(renderLine(entry));
  while (scrollback.childElementCount > BUFFER_MAX) {
    scrollback.removeChild(scrollback.firstElementChild);
  }
  if (wasPinned) scrollback.scrollTop = scrollback.scrollHeight;
}

function rerenderActive({ keepScroll = false } = {}) {
  const prevTop = scrollback.scrollTop;
  const wasPinned = isPinnedToBottom();
  scrollback.replaceChildren();
  const buf = buffers[activeTab] || [];
  for (const e of buf) scrollback.appendChild(renderLine(e));
  // A tab switch always lands at the newest line. A repaint in place (a
  // colour change) keeps the reader where they were unless they were
  // already following the bottom.
  scrollback.scrollTop = (keepScroll && !wasPinned) ? prevTop : scrollback.scrollHeight;
}

let lastColourSignature = null;

function switchTab(t) {
  const order = computeTabOrder();
  if (!order.includes(t)) return;
  hideColourMenu();
  activeTab = t;
  view = "chat";
  scrollback.hidden = false;
  settingsEl.hidden = true;
  markBufferSeen(t);
  renderTabs();
  rerenderActive();
  panel.post("active_tab", { tab: t });
  // Any explicit tab choice (including the restore call below) closes
  // the one-shot restore window so a late `settings` broadcast can't
  // yank the user back.
  activeTabRestored = true;
}

function openSettings() {
  view = "settings";
  scrollback.hidden = true;
  settingsEl.hidden = false;
  renderTabs();
  renderSettings();
  kickHandshake();
}

function makeTabButton(tabId, { overflow = false } = {}) {
  const btn = document.createElement("button");
  btn.className = "tab"
    + (tabId === activeTab && view === "chat" ? " active" : "")
    + (isTabUnread(tabId) ? " has-unread" : "");
  btn.dataset.tab = tabId;
  btn.role = "tab";
  btn.textContent = tabLabel(tabId);
  btn.addEventListener("click", () => {
    switchTab(tabId);
    if (overflow) hideOverflowPopover();
  });
  return btn;
}

const GEAR_SVG = '<svg viewBox="0 0 24 24" fill="currentColor" aria-hidden="true">' +
  '<path d="M19.14 12.94c.04-.3.06-.61.06-.94 0-.32-.02-.64-.07-.94l2.03-1.58a.49.49 0 0 0 .12-.61l-1.92-3.32a.49.49 0 0 0-.59-.22l-2.39.96c-.5-.38-1.03-.7-1.62-.94l-.36-2.54A.48.48 0 0 0 13.92 2h-3.84c-.24 0-.43.17-.47.41l-.36 2.54c-.59.24-1.13.57-1.62.94l-2.39-.96c-.22-.08-.47 0-.59.22L2.74 8.47c-.12.21-.08.47.12.61l2.03 1.58c-.05.3-.09.63-.09.94s.02.64.07.94l-2.03 1.58a.49.49 0 0 0-.12.61l1.92 3.32c.12.22.37.29.59.22l2.39-.96c.5.38 1.03.7 1.62.94l.36 2.54c.05.24.24.41.48.41h3.84c.24 0 .44-.17.47-.41l.36-2.54c.59-.24 1.13-.56 1.62-.94l2.39.96c.22.08.47 0 .59-.22l1.92-3.32c.12-.22.07-.47-.12-.61l-2.01-1.58zM12 15.6A3.6 3.6 0 1 1 12 8.4a3.6 3.6 0 0 1 0 7.2z"/>' +
  '</svg>';

function makeIconButton(content, className, onClick, { svg = false, title = "" } = {}) {
  const btn = document.createElement("button");
  btn.className = `tab ${className}` + (className === "gear" && view === "settings" ? " active" : "");
  if (svg) btn.innerHTML = content; else btn.textContent = content;
  if (title) btn.title = title;
  btn.addEventListener("click", onClick);
  return btn;
}

function hideOverflowPopover() {
  overflowPopover.hidden = true;
  overflowPopover.replaceChildren();
}

function showOverflowPopover(tabIds, anchorBtn) {
  overflowPopover.replaceChildren();
  for (const id of tabIds) {
    overflowPopover.appendChild(makeTabButton(id, { overflow: true }));
  }
  overflowPopover.hidden = false;
  const r = anchorBtn.getBoundingClientRect();
  overflowPopover.style.left = `${r.left}px`;
  overflowPopover.style.top = `${r.bottom}px`;
}

function renderTabs() {
  tabsEl.replaceChildren();
  const order = computeTabOrder();
  const gear = makeIconButton(GEAR_SVG, "gear", () => {
    if (view === "settings") switchTab(activeTab); else openSettings();
  }, { svg: true, title: "Settings" });

  // First-pass render — everything visible. Then measure and collapse.
  for (const id of order) tabsEl.appendChild(makeTabButton(id));
  tabsEl.appendChild(gear);

  requestAnimationFrame(() => collapseOverflow(order, gear));
}

function collapseOverflow(order, gear) {
  hideOverflowPopover();
  overflowHiddenIds = [];
  const barWidth = tabsEl.clientWidth;
  const gearWidth = gear.offsetWidth;
  const childButtons = Array.from(tabsEl.querySelectorAll(".tab:not(.gear):not(.overflow)"));

  let used = gearWidth;
  let overflowStart = -1;
  for (let i = 0; i < childButtons.length; i++) {
    used += childButtons[i].offsetWidth;
    if (used > barWidth) { overflowStart = i; break; }
  }
  if (overflowStart < 0) return;

  // Reserve space for the overflow button itself.
  const overflowBtn = makeIconButton("•••", "overflow", () => {
    const hiddenIds = order.slice(overflowStart);
    showOverflowPopover(hiddenIds, overflowBtn);
  });
  // Re-measure with overflow button width factored in: walk back until fits.
  // Insert temporarily to measure.
  tabsEl.insertBefore(overflowBtn, gear);
  const overflowWidth = overflowBtn.offsetWidth;

  // Recompute the cutoff with overflowWidth reserved.
  used = gearWidth + overflowWidth;
  overflowStart = -1;
  for (let i = 0; i < childButtons.length; i++) {
    used += childButtons[i].offsetWidth;
    if (used > barWidth) { overflowStart = i; break; }
  }
  if (overflowStart < 0) {
    overflowBtn.remove();
    return;
  }

  for (let i = overflowStart; i < childButtons.length; i++) {
    childButtons[i].remove();
  }
  // Rewire the overflow handler with the final hidden list.
  const hiddenIds = order.slice(overflowStart);
  overflowHiddenIds = hiddenIds;
  overflowBtn.onclick = () => showOverflowPopover(hiddenIds, overflowBtn);
  // Now that the overflow button exists, sync its dot — refreshUnreadDots
  // queries `.tab.overflow` so this couldn't run during makeTabButton.
  refreshUnreadDots();
}

// ---------------------------------------------------------------------
// Settings view rendering
// ---------------------------------------------------------------------

function sendUpdate(delta) {
  panel.post("settings_update", delta);
}

// Which row's swatch owns the open menu, as a *stable* key ("source:tells",
// "channel:foo") rather than an element or a sequence number. A settings
// broadcast rebuilds every row, destroying the button the menu is anchored
// to -- the key still resolves to that row's replacement, so the menu can be
// put back where it was. See the note in renderSettings().
let colourMenuOwner = null;

// key -> { btn, current, onPick }, repopulated on every renderSettings()
// pass. This is what re-anchoring resolves against.
const colourPickers = new Map();

// Rebuilding the rows can clamp settingsEl.scrollTop (a removed channel
// shortens the list), and the scroll event that produces is dispatched in
// the next rendering update -- after renderSettings has already re-anchored
// the menu, so the scroll-to-close handler would shut it again immediately.
// rAF callbacks run after scroll dispatch in that same update, so clearing
// the flag there covers exactly the rebuild's own scroll and nothing later.
let suppressScrollClose = false;
function suppressScrollCloseForOneFrame() {
  suppressScrollClose = true;
  requestAnimationFrame(() => { suppressScrollClose = false; });
}

// `restoreFocus` hands focus back to the swatch, for the closes that are the
// user finishing with the menu (Escape, Tab, picking a colour). Closes they
// didn't ask for -- clicking elsewhere, a rebuild, a tab switch -- leave
// focus alone rather than yanking it across the panel.
function hideColourMenu({ restoreFocus = false } = {}) {
  const owner = colourMenuOwner;
  colourMenuOwner = null;
  colourMenu.hidden = true;
  colourMenu.replaceChildren();
  const picker = owner !== null ? colourPickers.get(owner) : null;
  if (picker) {
    picker.btn.setAttribute("aria-expanded", "false");
    if (restoreFocus) picker.btn.focus();
  }
}

// A swatch button that opens the colour list. `key` identifies the row,
// `current` is a slot or null, `onPick` receives a slot or COLOUR_DEFAULT.
function makeColourPicker(key, current, onPick) {
  const btn = document.createElement("button");
  btn.className = "settings-colour";
  btn.title = "Tag colour";
  btn.setAttribute("aria-label", "Tag colour");
  btn.setAttribute("aria-haspopup", "menu");
  btn.setAttribute("aria-expanded", "false");
  const sw = document.createElement("span");
  sw.className = "swatch";
  sw.style.background = colourVar(current);
  btn.appendChild(sw);

  btn.addEventListener("click", (e) => {
    e.stopPropagation();
    // Second click on the same swatch closes rather than reopening.
    if (colourMenuOwner === key) {
      hideColourMenu({ restoreFocus: true });
      return;
    }
    openColourMenu(key);
  });

  colourPickers.set(key, { btn, current, onPick });
  return btn;
}

// Opens (or re-anchors) the menu for `key`. `focusIndex` restores which
// option was focused across a rebuild; without it focus lands on the
// row's current colour, per the usual menu-button pattern.
function openColourMenu(key, { focusIndex = null } = {}) {
  const picker = colourPickers.get(key);
  // The row can be gone -- the channel was removed while its menu was open.
  if (!picker) return;
  const { btn, current, onPick } = picker;

  if (colourMenuOwner !== null && colourMenuOwner !== key) hideColourMenu();
  colourMenu.replaceChildren();
  colourMenuOwner = key;
  btn.setAttribute("aria-expanded", "true");

  const selected = (current === null || current === undefined) ? COLOUR_DEFAULT : current;
  let selectedIndex = 0;

  function addOption(slot, label) {
    const row = document.createElement("button");
    const isSelected = selected === slot;
    row.className = "colour-option" + (isSelected ? " selected" : "");
    row.setAttribute("role", "menuitem");
    if (isSelected) {
      row.setAttribute("aria-current", "true");
      selectedIndex = colourMenu.childElementCount;
    }
    const sw = document.createElement("span");
    sw.className = "swatch";
    sw.style.background = colourVar(slot);
    row.appendChild(sw);
    row.appendChild(document.createTextNode(label));
    row.addEventListener("click", (e) => {
      e.stopPropagation();
      hideColourMenu({ restoreFocus: true });
      onPick(slot);
    });
    colourMenu.appendChild(row);
  }

  addOption(COLOUR_DEFAULT, "Default");
  ANSI_COLOURS.forEach((name, slot) => addOption(slot, name));

  colourMenu.hidden = false;
  // Positioned after unhiding so the height is measurable: the list is tall,
  // so flip it above the swatch when there isn't room below.
  const r = btn.getBoundingClientRect();
  const h = colourMenu.offsetHeight;
  const below = window.innerHeight - r.bottom;
  colourMenu.style.top = (below >= h || r.top < h)
    ? `${Math.max(0, Math.min(r.bottom, window.innerHeight - h))}px`
    : `${Math.max(0, r.top - h)}px`;
  colourMenu.style.left =
    `${Math.max(0, Math.min(r.left, window.innerWidth - colourMenu.offsetWidth))}px`;

  // Focus moves into the menu on open (mouse or keyboard), which is what
  // makes Escape/Tab-to-return coherent and is why the menu doesn't need to
  // sit in the static tab order.
  const options = colourMenu.children;
  const target = focusIndex !== null
    ? options[Math.min(focusIndex, options.length - 1)]
    : options[selectedIndex];
  if (target) target.focus();
}

// Arrow/Home/End move within the open menu; Tab leaves it entirely, handing
// focus back to the swatch so the browser's normal order continues from
// there rather than from the end of <body> where the menu lives.
colourMenu.addEventListener("keydown", (e) => {
  if (colourMenu.hidden) return;
  const options = Array.from(colourMenu.children);
  if (options.length === 0) return;
  const last = options.length - 1;
  const i = options.indexOf(document.activeElement);

  if (e.key === "ArrowDown") {
    e.preventDefault();
    options[i < 0 || i === last ? 0 : i + 1].focus();
  } else if (e.key === "ArrowUp") {
    e.preventDefault();
    options[i <= 0 ? last : i - 1].focus();
  } else if (e.key === "Home") {
    e.preventDefault();
    options[0].focus();
  } else if (e.key === "End") {
    e.preventDefault();
    options[last].focus();
  } else if (e.key === "Tab") {
    // No preventDefault: focus is back on the swatch by the time the
    // default action runs, so Tab advances from there.
    hideColourMenu({ restoreFocus: true });
  }
});

function renderSourceRow(label, key) {
  const row = document.createElement("div");
  row.className = "settings-row source-row";
  const name = document.createElement("span");
  name.className = "settings-name";
  name.textContent = label;
  row.appendChild(name);

  function sourceToggle(text, field) {
    const lab = document.createElement("label");
    lab.className = "settings-toggle";
    const cb = document.createElement("input");
    cb.type = "checkbox";
    cb.checked = !!(settings.sources[key] && settings.sources[key][field]);
    cb.addEventListener("change", () => {
      sendUpdate({ source: { [key]: { [field]: cb.checked } } });
    });
    lab.appendChild(cb);
    lab.appendChild(document.createTextNode(" " + text));
    return lab;
  }

  row.appendChild(sourceToggle("gag from main", "gag_main"));
  row.appendChild(sourceToggle("sound", "sound"));
  row.appendChild(sourceToggle("notify", "notify"));

  const src = settings.sources[key] || {};
  row.appendChild(makeColourPicker(
    "source:" + key,
    src.colour !== undefined ? src.colour : null,
    (slot) => sendUpdate({ source: { [key]: { colour: slot } } })
  ));
  return row;
}

function renderChannelRow(name, entry) {
  const row = document.createElement("div");
  row.className = "settings-row channel-row";

  const nameEl = document.createElement("span");
  nameEl.className = "settings-name";
  nameEl.textContent = name;
  row.appendChild(nameEl);

  const meta = document.createElement("span");
  meta.className = "settings-meta";
  meta.textContent = `${formatRelative(entry.last_seen)} · ${entry.count || 0} msg`;
  row.appendChild(meta);

  const toggles = document.createElement("span");
  toggles.className = "settings-toggles";

  function toggle(label, field) {
    const lab = document.createElement("label");
    lab.className = "settings-toggle";
    const cb = document.createElement("input");
    cb.type = "checkbox";
    cb.checked = !!entry[field];
    cb.addEventListener("change", () => {
      sendUpdate({ channel: { name, [field]: cb.checked } });
    });
    lab.appendChild(cb);
    lab.appendChild(document.createTextNode(" " + label));
    return lab;
  }

  toggles.appendChild(toggle("listen", "listen"));
  toggles.appendChild(toggle("gag main", "gag_main"));
  toggles.appendChild(toggle("pin", "pinned"));
  toggles.appendChild(toggle("sound", "sound"));
  toggles.appendChild(toggle("notify", "notify"));
  row.appendChild(toggles);

  row.appendChild(makeColourPicker(
    "channel:" + name,
    entry.colour !== undefined ? entry.colour : null,
    (slot) => sendUpdate({ channel: { name, colour: slot } })
  ));

  const remove = document.createElement("button");
  remove.className = "settings-remove";
  remove.textContent = "×";
  remove.title = "Remove from registry";
  remove.addEventListener("click", () => {
    sendUpdate({ channel: { name, remove: true } });
  });
  row.appendChild(remove);

  return row;
}

// The add-channel row lives outside the per-update channels list so a
// late-arriving settings broadcast doesn't wipe whatever the user is
// typing or steal focus. Built lazily on first renderSettings() call,
// reused thereafter.
function ensureAddChannelRow() {
  if (addChannelEl.firstChild) return;

  const row = document.createElement("div");
  row.className = "settings-row add-channel-row";

  const input = document.createElement("input");
  input.type = "text";
  input.className = "add-channel-input";
  input.placeholder = "Add channel by name…";
  input.spellcheck = false;
  input.autocomplete = "off";

  const button = document.createElement("button");
  button.className = "settings-add";
  button.textContent = "Add";

  function submit() {
    const name = input.value.trim();
    if (!name) return;
    // If an entry already exists, just clear the input and surface a
    // brief hint via :invalid styling. The Lua side would otherwise
    // happily re-set defaults and silently drop the user's existing
    // toggles — better to skip the round-trip entirely.
    if (settings.channels[name]) {
      input.value = "";
      input.focus();
      return;
    }
    sendUpdate({ channel: { name } });
    input.value = "";
    input.focus();
  }

  button.addEventListener("click", submit);
  input.addEventListener("keydown", (e) => {
    if (e.key === "Enter") {
      e.preventDefault();
      submit();
    }
  });

  row.appendChild(input);
  row.appendChild(button);
  addChannelEl.appendChild(row);
}

function renderSettings() {
  // Every settings broadcast rebuilds these rows, throwing away both the
  // button an open menu is anchored to and whatever had focus. Those
  // broadcasts are no longer only user-driven: a line from a never-before-
  // seen channel makes the Lua side re-announce, so ambient MUD traffic
  // lands here too -- and closing the picker mid-choice (or dropping focus
  // to <body> after a pick) is exactly what that shouldn't do. Remember
  // what was open and focused, then restore it against the new rows.
  const reopenKey = colourMenuOwner;
  const focusIndex = reopenKey !== null
    ? Array.from(colourMenu.children).indexOf(document.activeElement)
    : -1;
  let refocusKey = null;
  for (const [key, picker] of colourPickers) {
    if (picker.btn === document.activeElement) { refocusKey = key; break; }
  }

  hideColourMenu();
  colourPickers.clear();
  sourcesEl.replaceChildren();
  sourcesEl.appendChild(renderSourceRow("Tells", "tells"));
  sourcesEl.appendChild(renderSourceRow("Group", "group"));

  ensureAddChannelRow();

  channelsEl.replaceChildren();
  const entries = Object.entries(settings.channels).sort((a, b) => {
    if (a[1].pinned !== b[1].pinned) return a[1].pinned ? -1 : 1;
    return (b[1].last_seen || 0) - (a[1].last_seen || 0);
  });
  if (entries.length === 0) {
    const empty = document.createElement("div");
    empty.className = "settings-empty";
    empty.textContent = "No channels yet — type one above, or wait for traffic.";
    channelsEl.appendChild(empty);
  } else {
    for (const [name, entry] of entries) channelsEl.appendChild(renderChannelRow(name, entry));
  }

  if (reopenKey !== null) {
    suppressScrollCloseForOneFrame();
    openColourMenu(reopenKey, { focusIndex: focusIndex >= 0 ? focusIndex : null });
  } else if (refocusKey !== null) {
    const picker = colourPickers.get(refocusKey);
    if (picker) picker.btn.focus();
  }
}

// ---------------------------------------------------------------------
// Panel SDK wiring
// ---------------------------------------------------------------------

panel.on("line", (payload) => {
  bufferPush(payload);
  appendToActive(payload);
  refreshUnreadDots();
});

let settingsReceived = false;
let activeTabRestored = false;
panel.on("settings", (payload) => {
  settingsReceived = true;
  if (payload && typeof payload === "object") {
    settings.channels = payload.channels || {};
    settings.sources = payload.sources || settings.sources;
    // Restore the persisted active tab once per iframe lifetime —
    // subsequent settings broadcasts (e.g. after a settings_update)
    // must not yank the user back if they've since clicked elsewhere.
    // switchTab is a no-op if the saved tab is no longer in the tab
    // order (e.g. channel was unpinned in another session), and the
    // post-back it does is idempotent.
    if (!activeTabRestored) {
      activeTabRestored = true;
      if (typeof payload.active_tab === "string" && payload.active_tab !== activeTab) {
        switchTab(payload.active_tab);
      }
    }
  }
  renderTabs();
  const sig = colourSignature(settings);
  if (sig !== lastColourSignature) {
    lastColourSignature = sig;
    if (view === "chat") rerenderActive({ keepScroll: true });
  }
  if (view === "settings") renderSettings();
});

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

window.addEventListener("resize", () => renderTabs());

document.addEventListener("click", (e) => {
  if (!colourMenu.hidden && !colourMenu.contains(e.target)) hideColourMenu();
  if (overflowPopover.hidden) return;
  if (overflowPopover.contains(e.target)) return;
  if (e.target.classList && e.target.classList.contains("overflow")) return;
  hideOverflowPopover();
});

document.addEventListener("keydown", (e) => {
  // Escape is the user dismissing the menu, so focus goes back to the
  // swatch they opened it from.
  if (e.key === "Escape" && !colourMenu.hidden) hideColourMenu({ restoreFocus: true });
});

// The menu is positioned in viewport coordinates against a row that scrolls,
// so anything that moves the row underneath it must close it rather than
// leave it floating somewhere arbitrary. Wrapped rather than passed
// directly: these fire with an Event argument, which is not an options bag.
window.addEventListener("resize", () => hideColourMenu());
settingsEl.addEventListener("scroll", () => {
  if (!suppressScrollClose) hideColourMenu();
}, true);

renderTabs();

// Handshake with retry: Mallard's panel dispatcher drops messages when
// no Lua listener is yet registered (host.rs panel_dispatch_post), so
// our first "ready" can race the plugin's top-level code on a Mallard
// restart. Plugins can load lazily after the panel mounts, so we keep
// retrying generously until Lua's "settings" reply confirms the
// handshake landed. Lua dedupes history replay by `session` so retries
// don't double-replay but a fresh iframe mount always gets history.
const READY_RETRY_MS = 500;
const READY_MAX_ATTEMPTS = 120; // ~60s total
const SESSION_ID = `${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 10)}`;
let readyAttempts = 0;
let readyTimer = null;
function sendReady() {
  readyTimer = null;
  if (settingsReceived) return;
  if (readyAttempts >= READY_MAX_ATTEMPTS) return;
  panel.post("ready", { session: SESSION_ID });
  readyAttempts += 1;
  readyTimer = setTimeout(sendReady, READY_RETRY_MS);
}
function kickHandshake() {
  if (settingsReceived) return;
  if (readyTimer) { clearTimeout(readyTimer); readyTimer = null; }
  readyAttempts = 0;
  sendReady();
}
sendReady();
