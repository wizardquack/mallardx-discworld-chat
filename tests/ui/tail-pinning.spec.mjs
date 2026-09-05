// Regression tests for tail pinning in the chat scrollback.
//
// The bug these lock down: pinning used to be measured at append time rather
// than remembered, so anything that moved the bottom *after* a line landed —
// the panel being resized, a narrower panel rewrapping every line, the host
// pushing the user's typography over the SDK's default — left the view
// permanently unpinned. Every later line then appended off-screen and the
// user had to drag to the bottom by hand before autoscroll resumed.
//
// WebKit only (see playwright.config.mjs): this is scroll reconciliation, and
// WebKit is the engine Mallard ships.

import { test, expect } from "@playwright/test";
import { fileURLToPath } from "node:url";
import path from "node:path";

const CHAT_HTML = path.join(
  path.dirname(fileURLToPath(import.meta.url)),
  "..", "..", "ui", "chat.html",
);

// Comfortably above PIN_SLACK_PX (48) so a pass means genuinely pinned, not
// merely within the slack window.
const PINNED_TOLERANCE_PX = 48;

// Long enough to wrap when the viewport narrows — that rewrap is the whole
// point of the "narrowed" case.
const LINE_TEXT =
  "some reasonably long chat text that will wrap more than once in a narrow panel";

test.beforeEach(async ({ page }) => {
  // The panel SDK is host-provided; stub the surface chat.js actually uses.
  // Must be installed before the deferred scripts run.
  await page.addInitScript(() => {
    window.panel = {
      _handlers: {},
      on(name, fn) { this._handlers[name] = fn; },
      post() {},
      emit(name, payload) { this._handlers[name]?.(payload); },
    };
  });
  await page.setViewportSize({ width: 420, height: 320 });
  await page.goto(`file://${CHAT_HTML}`);
  await page.waitForFunction(() => !!window.panel && !!document.getElementById("lines"));
});

async function feed(page, count, offset = 0) {
  await page.evaluate(({ count, offset, text }) => {
    for (let i = 0; i < count; i++) {
      window.panel.emit("line", {
        tab: "all",
        channel: "Wizards",
        text: `line ${i + offset} ${text}`,
        ts: 1700000000 + i,
      });
    }
  }, { count, offset, text: LINE_TEXT });
}

// Distance from the bottom of the scroll range. 0 means fully pinned.
async function distanceFromBottom(page) {
  return page.evaluate(() => {
    const sb = document.getElementById("scrollback");
    return Math.round(sb.scrollHeight - sb.scrollTop - sb.clientHeight);
  });
}

async function scrollTo(page, top) {
  await page.evaluate((top) => {
    const sb = document.getElementById("scrollback");
    sb.scrollTop = top === "bottom" ? sb.scrollHeight : top;
  }, top);
  // Let the scroll event and any observer settle.
  await page.waitForTimeout(120);
}

test("follows the tail while lines arrive", async ({ page }) => {
  await feed(page, 200);
  expect(await distanceFromBottom(page)).toBeLessThan(PINNED_TOLERANCE_PX);
});

test("stays pinned when the panel is made shorter", async ({ page }) => {
  await feed(page, 200);
  await page.setViewportSize({ width: 420, height: 160 });
  await page.waitForTimeout(150);
  expect(await distanceFromBottom(page)).toBeLessThan(PINNED_TOLERANCE_PX);

  // The real symptom was not the resize itself but that autoscroll never
  // recovered afterwards, so assert on a line that arrives after it.
  await feed(page, 1, 900);
  await page.waitForTimeout(120);
  expect(await distanceFromBottom(page)).toBeLessThan(PINNED_TOLERANCE_PX);
});

test("stays pinned when the panel is narrowed and every line rewraps", async ({ page }) => {
  await feed(page, 200);
  const before = await page.evaluate(() => document.getElementById("scrollback").scrollHeight);

  await page.setViewportSize({ width: 220, height: 320 });
  await page.waitForTimeout(150);

  // Guard the guard: if narrowing stopped causing a rewrap the assertions
  // below would pass without exercising anything.
  const after = await page.evaluate(() => document.getElementById("scrollback").scrollHeight);
  expect(after).toBeGreaterThan(before);

  expect(await distanceFromBottom(page)).toBeLessThan(PINNED_TOLERANCE_PX);
  await feed(page, 1, 900);
  await page.waitForTimeout(120);
  expect(await distanceFromBottom(page)).toBeLessThan(PINNED_TOLERANCE_PX);
});

test("stays pinned when the host pushes new typography", async ({ page }) => {
  await feed(page, 200);
  const before = await page.evaluate(() => document.getElementById("scrollback").scrollHeight);

  // What `set-typography` does: Mallard's SDK shim writes the vars onto the
  // iframe's :root, and the served baseline applies them via the cascade.
  await page.evaluate(() => {
    document.documentElement.style.setProperty("--font-size", "18px");
    document.documentElement.style.fontSize = "18px";
  });
  await page.waitForTimeout(150);

  const after = await page.evaluate(() => document.getElementById("scrollback").scrollHeight);
  expect(after).toBeGreaterThan(before);

  expect(await distanceFromBottom(page)).toBeLessThan(PINNED_TOLERANCE_PX);
  await feed(page, 1, 900);
  await page.waitForTimeout(120);
  expect(await distanceFromBottom(page)).toBeLessThan(PINNED_TOLERANCE_PX);
});

test("does not yank a reader who has scrolled up", async ({ page }) => {
  await feed(page, 200);
  await scrollTo(page, 800);

  await feed(page, 5, 900);
  await page.waitForTimeout(120);

  expect(await page.evaluate(() => document.getElementById("scrollback").scrollTop)).toBe(800);
});

test("re-arms the pin once the reader scrolls back to the bottom", async ({ page }) => {
  await feed(page, 200);
  await scrollTo(page, 800);
  await feed(page, 5, 900);
  await page.waitForTimeout(120);

  await scrollTo(page, "bottom");
  await feed(page, 5, 950);
  await page.waitForTimeout(120);

  expect(await distanceFromBottom(page)).toBeLessThan(PINNED_TOLERANCE_PX);
});

test("a reader scrolled up survives a panel resize without being yanked down", async ({ page }) => {
  await feed(page, 200);
  await scrollTo(page, 800);

  await page.setViewportSize({ width: 420, height: 200 });
  await page.waitForTimeout(150);
  await feed(page, 1, 900);
  await page.waitForTimeout(120);

  expect(await distanceFromBottom(page)).toBeGreaterThan(PINNED_TOLERANCE_PX);
});
