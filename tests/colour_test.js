// Pure tests for the tag-colour helpers. Run with: node tests/colour_test.js
// colour.js has no DOM/host dependencies, so plain node is enough — same
// pattern as tab_index_test.js.
const {
  COLOUR_DEFAULT, colourVar, tagColourSlot, colourSignature,
} = require("../ui/colour.js");

let failures = 0;
function check(label, got, want) {
  if (got === want) {
    console.log("ok   " + label);
  } else {
    failures++;
    console.log("FAIL " + label + " — got " + String(got) + ", want " + String(want));
  }
}

// --- colourVar -------------------------------------------------------
// Slot 0 is a real colour (Black) and must not be treated as "unset".
check("colourVar null -> link",    colourVar(null),           "var(--link)");
check("colourVar undefined",       colourVar(undefined),      "var(--link)");
check("colourVar DEFAULT",         colourVar(COLOUR_DEFAULT), "var(--link)");
check("colourVar 0 is a colour",   colourVar(0),  "var(--ansi-0, var(--link))");
check("colourVar 15",              colourVar(15), "var(--ansi-15, var(--link))");

// --- tagColourSlot ---------------------------------------------------
const settings = {
  sources: { tells: { colour: 4 }, group: { colour: 0 } },
  channels: {
    Wizards:  { colour: 9 },
    Newbie:   {},              // in the registry, no colour chosen
    Zero:     { colour: 0 },
  },
};

check("tells comes off the source",  tagColourSlot(settings, "tells", null), 4);
check("group comes off the source",  tagColourSlot(settings, "group", "AdHocGroupName"), 0);
check("channel line -> registry",    tagColourSlot(settings, "channels", "Wizards"), 9);
check("pinned tab -> registry",      tagColourSlot(settings, "channel:Wizards", "Wizards"), 9);
check("channel with no colour",      tagColourSlot(settings, "channels", "Newbie"), null);
check("channel slot 0 kept",         tagColourSlot(settings, "channels", "Zero"), 0);
check("unknown channel",             tagColourSlot(settings, "channels", "Nope"), null);
check("no channel, no source",       tagColourSlot(settings, "all", null), null);

// A group line's tag carries the group's ad hoc name; it must resolve to the
// group source even when a channel of that name happens to be registered.
check("group beats a same-named channel",
  tagColourSlot(settings, "group", "Wizards"), 0);

// Missing/partial settings must not throw — the panel renders replayed lines
// before the first `settings` broadcast arrives.
check("empty settings",  tagColourSlot({}, "channels", "Wizards"), null);
check("bare tells",      tagColourSlot({}, "tells", null), null);

// --- colourSignature -------------------------------------------------
const sig = colourSignature;
const base = { sources: { tells: {}, group: {} }, channels: {} };

check("signature is stable",
  sig(base) === sig({ sources: { tells: {}, group: {} }, channels: {} }), true);

check("channel colour changes it",
  sig(base) !== sig({ ...base, channels: { A: { colour: 1 } } }), true);

check("source colour changes it",
  sig(base) !== sig({ sources: { tells: { colour: 1 }, group: {} }, channels: {} }), true);

check("clearing a colour changes it",
  sig({ ...base, channels: { A: { colour: 1 } } }) !== sig({ ...base, channels: { A: {} } }), true);

check("slot 0 is not 'unset'",
  sig({ ...base, channels: { A: { colour: 0 } } }) !== sig(base), true);

// Non-colour churn must NOT change it — this is the whole point of the
// signature, since every settings broadcast would otherwise repaint (and
// re-anchor) the scrollback.
check("last_seen/count churn is ignored",
  sig({ ...base, channels: { A: { colour: 1, count: 1, last_seen: 100 } } })
  === sig({ ...base, channels: { A: { colour: 1, count: 99, last_seen: 999 } } }), true);

check("toggles are ignored",
  sig({ ...base, channels: { A: { colour: 1, pinned: false } } })
  === sig({ ...base, channels: { A: { colour: 1, pinned: true } } }), true);

check("a new uncoloured channel is ignored",
  sig({ ...base, channels: { A: { colour: 1 } } })
  === sig({ ...base, channels: { A: { colour: 1 }, B: {} } }), true);

// Key order must not matter: Object.entries follows insertion order, and the
// registry is rebuilt from JSON on every broadcast.
check("key order does not matter",
  sig({ ...base, channels: { A: { colour: 1 }, B: { colour: 2 } } })
  === sig({ ...base, channels: { B: { colour: 2 }, A: { colour: 1 } } }), true);

// Sources and channels are namespaced, so a channel named "tells" can't
// forge the tells source entry and mask a real change.
check("channel named 'tells' does not collide with the source",
  sig({ sources: { tells: { colour: 3 }, group: {} }, channels: {} })
  !== sig({ sources: { tells: {}, group: {} }, channels: { tells: { colour: 3 } } }), true);

console.log("");
if (failures === 0) {
  console.log("all passed");
} else {
  console.log(failures + " failure(s)");
  process.exit(1);
}
