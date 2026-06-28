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
