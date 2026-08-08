// Pure tag-colour helpers, shared by chat.js (loaded as browser globals)
// and tests (node require) — same dual-export shape as tab_index.js.
//
// Tag colours are ANSI palette slots, not hex. The host pushes --ansi-0..15
// onto this iframe with the rest of the theme, and Discworld's channel
// colours are ANSI as well, so slot N paints the tag in the same shade the
// main output pane uses for that channel — and re-resolves on a theme
// change instead of freezing one hard-coded value. Names follow the usual
// 16-colour convention; slot order is the ANSI order, so the menu reads
// the same as any other palette the user has seen.
const ANSI_COLOURS = [
  "Black",   "Red",         "Green",        "Yellow",
  "Blue",    "Magenta",     "Cyan",         "White",
  "Grey",    "Bright red",  "Bright green", "Bright yellow",
  "Bright blue", "Bright magenta", "Bright cyan", "Bright white",
];
const COLOUR_DEFAULT = -1; // clears back to the theme's --link

function colourVar(slot) {
  return (slot === null || slot === undefined || slot === COLOUR_DEFAULT)
    ? "var(--link)"
    : `var(--ansi-${slot}, var(--link))`;
}

// Which palette slot paints this line's tag, or null for the default.
//
// Group is checked before the channel registry, and deliberately: a group
// line's tag shows the current group's name, which is ad hoc and different
// for every group joined. Colouring those per channel would mean re-picking
// a colour for each new group -- and group lines never reach the registry
// anyway. One colour for "group chatter" is the useful unit. Everything
// else resolves per channel, and the literal "[tells]" tag has no channel,
// so it comes off the tells source entry.
function tagColourSlot(settings, tab, channel) {
  const sources = (settings && settings.sources) || {};
  const src = tab === "group" ? sources.group
            : tab === "tells" ? sources.tells
            : null;
  if (src) return src.colour !== undefined ? src.colour : null;
  if (channel) {
    const entry = (settings && settings.channels || {})[channel];
    return entry && entry.colour !== undefined ? entry.colour : null;
  }
  return null;
}

// A string that changes exactly when some tag's colour would change.
//
// Tag colours are read at render time, so a line already on screen keeps
// whatever colour was in force when it was drawn. Lines replay before the
// first `settings` message arrives, which means the opening scrollback is
// always drawn with no colours at all -- hence the repaint this gates,
// which only fires when the assignments actually changed so unrelated
// settings traffic doesn't repaint (and re-anchor) the view for nothing.
//
// Sources and channels are namespaced so a channel that happens to be
// called "tells" can't produce a string that collides with the tells
// source entry.
function colourSignature(settings) {
  const parts = [];
  const sources = (settings && settings.sources) || {};
  for (const key of ["tells", "group"]) {
    const s = sources[key];
    parts.push("src:" + key + ":" + (s && s.colour !== undefined ? s.colour : ""));
  }
  const channels = (settings && settings.channels) || {};
  for (const [name, e] of Object.entries(channels)) {
    if (e && e.colour !== undefined) parts.push("ch:" + name + ":" + e.colour);
  }
  return parts.sort().join("|");
}

// Dual export: in the browser `module` is undefined and these stay globals
// for chat.js; under node the test can require() them.
if (typeof module !== "undefined" && module.exports) {
  module.exports = { ANSI_COLOURS, COLOUR_DEFAULT, colourVar, tagColourSlot, colourSignature };
}
