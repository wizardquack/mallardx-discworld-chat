# Discworld Chat

A Mallard plugin for Discworld MUD. Captures tells, group chatter/events,
and talker channels into a configurable, tabbed chat panel.

The panel is configurable via the gear icon on the right side, where
you can add/remove tabs, and control per tab/channel settings for
things like:

- the colour of the channel's tag in the chat log
- whether or not to play notification sounds
- whether or not to show a desktop (OS) notification
- whether or not to gag from the main output
- whether or not to pina dedicated tab for the channel, or just
  capture in an aggregator tab like "Channels"

## Tests

```sh
lua tests/classifier_test.lua      # and the other tests/*.lua — no deps
node tests/colour_test.js          # pure JS helpers — no deps
node tests/tab_index_test.js

npm install && npm test            # the above JS tests plus the UI suite
npx playwright test                # UI suite only (WebKit)
```

`tests/ui/` runs the real panel document under Playwright's WebKit against a
stubbed panel SDK. WebKit only, deliberately: Mallard ships in a WKWebView /
WebKitGTK shell, and the suite guards scroll reconciliation, where a Chromium
pass would be misleading.

## Credit

Many thanks to Quow and Oki, whose work on similar plugins was
invaluable in designing and building this one.
