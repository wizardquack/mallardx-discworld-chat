# Discworld Chat

A Mallard plugin for Discworld MUD. Captures tells, group says,
and public channels into a 4-tab panel: `All / Tells / Group / Channels`.

## Install (dev)

```sh
bash scripts/reinstall.sh
```

## What it does

Triggers (ported from Quow's QuowMinimap.xml) match:
- outgoing tells / asks / exclaims
- incoming tells / asks / exclaims (with sender capture)
- bracketed channels — `[partyA] Bob says: ...`, etc. (excluding internal
  `[say]`, `[tell]`, `[soul]`, `[/path]`, and empty `[ ]` brackets).

The plugin auto-detects your group by watching for "You have joined the
group." / "The group has been renamed to..." / "You have left the group."
and routes matching `[group_name]` lines to the Group tab.

Per-tab scrollback (max 500 lines) is persisted to plugin storage and
replayed on Mallard restart.

## Auto-enable

`[worlds] match = ["discworld.starturtle.net:*"]`.
