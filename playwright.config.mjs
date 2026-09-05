import { defineConfig, devices } from "@playwright/test";

// WebKit only, deliberately. Mallard ships in a WKWebView (macOS) /
// WebKitGTK (Linux) shell, and this suite exists to guard scroll
// reconciliation — the one area where a Chromium pass is actively
// misleading. WebKit has no overflow-anchor and reconciles scrollTop
// against layout changes differently; those differences are the bug.
export default defineConfig({
  testDir: "tests/ui",
  fullyParallel: true,
  reporter: process.env.CI ? "list" : [["list"]],
  use: { ...devices["Desktop Safari"] },
  projects: [{ name: "webkit", use: { ...devices["Desktop Safari"] } }],
});
