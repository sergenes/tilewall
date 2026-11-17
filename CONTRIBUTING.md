# Contributing

Bug reports and ideas are welcome as [issues](https://github.com/sergenes/tilewall/issues).

## Build and test

```sh
swift build
swift test
swift build && .build/debug/tilewall run   # runs this copy in the foreground
```

A copy started from a terminal uses that terminal's Accessibility permission.
Set `TILEWALL_HOME` to a scratch folder to run it next to an installed tilewall, with its own config, state and socket.

## Where things go

- `Sources/TilewallCore` holds every decision that can be made without touching a window: layout, placement, ordering, rules, versions.
  It has no AppKit dependency, and new logic there comes with unit tests.
- `Sources/tilewall` talks to macOS: Accessibility, the menu, hotkeys, the socket.
  Keep it thin, and move a decision into the core when it grows a branch worth testing.

## Pull requests

- Keep a pull request to one change.
- `swift test` must pass, and CI runs it on every pull request.
- Describe how you tried the change with real windows, since the window code has no automated tests.
