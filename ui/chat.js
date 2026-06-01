// Discworld Chat — panel UI logic.
//
// Receives :post("line", { tab, channel, text, ts }) messages from the
// Lua side via Mallard's panel SDK. Maintains four FIFO ring buffers
// (one per tab); renders only the active tab.

const BUFFER_MAX = 1000;
const TABS = ["all", "tells", "group", "channels"];

const buffers = Object.fromEntries(TABS.map(t => [t, []]));
let activeTab = "all";

const scrollback = document.getElementById("scrollback");

function pad(n) { return n < 10 ? "0" + n : "" + n; }
function formatTime(unix) {
  const d = new Date(unix * 1000);
  return `${pad(d.getHours())}:${pad(d.getMinutes())}:${pad(d.getSeconds())}`;
}

function renderLine({ tab, channel, text, ts }) {
  const el = document.createElement("div");
  el.className = "line";
  const tag = channel ? `[${channel}]` : (tab === "tells" ? "[tells]" : "");
  // Strip the original `[channel] ` or `(channel) ` prefix from text
  // when we have a tag — otherwise the channel name displays twice.
  let body = text;
  if (channel) {
    const bracketPrefix = `[${channel}] `;
    const parenPrefix   = `(${channel}) `;
    if (body.startsWith(bracketPrefix)) body = body.slice(bracketPrefix.length);
    else if (body.startsWith(parenPrefix)) body = body.slice(parenPrefix.length);
  }
  el.innerHTML =
    `<span class="ts">${formatTime(ts)}</span>` +
    (tag ? `<span class="tag">${tag}</span>` : "") +
    escapeHtml(body);
  return el;
}

function escapeHtml(s) {
  return String(s).replace(/[&<>"']/g, c => ({
    "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;"
  }[c]));
}

function isPinnedToBottom() {
  const sb = scrollback;
  return sb.scrollHeight - sb.scrollTop - sb.clientHeight < 16;
}

function appendToActive(entry) {
  if (entry.tab !== activeTab && activeTab !== "all") return;
  const wasPinned = isPinnedToBottom();
  scrollback.appendChild(renderLine(entry));
  while (scrollback.childElementCount > BUFFER_MAX) {
    scrollback.removeChild(scrollback.firstElementChild);
  }
  if (wasPinned) scrollback.scrollTop = scrollback.scrollHeight;
}

function bufferPush(entry) {
  // Every entry goes to "all" plus its specific tab.
  for (const t of ["all", entry.tab]) {
    const buf = buffers[t];
    buf.push(entry);
    if (buf.length > BUFFER_MAX) buf.shift();
  }
}

function rerenderActive() {
  scrollback.replaceChildren();
  for (const e of buffers[activeTab]) scrollback.appendChild(renderLine(e));
  scrollback.scrollTop = scrollback.scrollHeight;
}

function switchTab(t) {
  if (!TABS.includes(t)) return;
  activeTab = t;
  document.querySelectorAll(".tab").forEach(btn => {
    btn.classList.toggle("active", btn.dataset.tab === t);
  });
  rerenderActive();
}

document.querySelectorAll(".tab").forEach(btn => {
  btn.addEventListener("click", () => switchTab(btn.dataset.tab));
});

// `panel` is the iframe-side SDK injected by the host (see
// src-tauri/src/plugins/webview/inject.rs). API:
//   panel.on(name, fn)     — Lua → iframe subscription
//   panel.post(name, data) — iframe → Lua emit
// (Same pattern as examples/plugins/showcase/ui/demo.js.)

panel.on("line", (payload) => {
  bufferPush(payload);
  appendToActive(payload);
});

// Tell the Lua side we're mounted so it can replay any persisted history.
// "ready" is the custom-HTML panel's app-defined handshake name; the
// reserved "__ready__" is owned by the template-panel framework.
panel.post("ready", {});
