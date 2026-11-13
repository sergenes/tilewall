# tilewall

See all your agents at once.

tilewall is a small macOS tiler for people who run many terminal agents side by side.
Every tiled window gets a slot in a grid, and the focused one grows to a quarter of the screen.
The other windows stay in their slots and shrink, so nothing jumps around when focus moves.

In the default landscape layout the tiles run in rows.
The focused row grows taller, and only the tiles in that row change width, so the other rows keep their widths and just get shorter.
The portrait layout keeps every window in the same slot and flips the rule: the focused column grows wider, and only the tiles in that column change height.
The other columns keep their heights and just get narrower.

It arranges the windows you already have.
Your agents keep running in Terminal, tmux, or any other app, and tilewall only moves and resizes their windows.

tilewall is free and open source under the MIT license.
It pairs well with [Agents At Work](https://agentsatwork.app), which runs agents in tmux sessions and lets you control them from a phone.

## Install

### The app

Download `tilewall-<version>.zip` from the [releases page](https://github.com/sergenes/tilewall/releases), unzip it, and move `tilewall.app` to Applications.
The app is signed and notarized.
It lives in the menu bar and has no Dock icon.

On first start macOS asks for the Accessibility permission, under System Settings, Privacy & Security, Accessibility.
tilewall needs it to move and resize the windows of other apps, and starts tiling as soon as it is granted.

Launch at Login in the menu starts tilewall with your Mac.

To use the command line with the app, link its binary into your path:

```sh
ln -s /Applications/tilewall.app/Contents/MacOS/tilewall ~/.local/bin/tilewall
```

### From source

```sh
make install          # builds a release binary and copies it to ~/.local/bin/tilewall
make test
./scripts/release.sh  # builds dist/tilewall.app, unsigned unless private/release.env holds signing settings
```

A binary started from a terminal uses that terminal's Accessibility permission.

## Before you rely on it

- Square window corners are experimental.
  They depend on an undocumented macOS default, described below, that Apple can remove in any release.
- Applying the corners means quitting and reopening each app, which closes its windows.
  For Terminal that ends every shell that is not inside tmux.
  Whether tmux sessions survive a Terminal restart has not been tested with tilewall, so save or finish what is running first.
- tilewall uses one private macOS function, `_AXUIElementGetWindow`, to tell windows apart.
  Other macOS tilers depend on the same function, but it is not a public API.

## Use

```sh
tilewall start            # start the daemon in the background
tilewall untab            # move every tab of the rule-matched apps into its own window
tilewall status --all     # tiles, plus the visible windows that are not tiled
tilewall all              # tile every window the rules match, undoing manual excludes
tilewall none             # release every tile on the current space
tilewall toggle           # include or exclude the focused window
tilewall toggle 9154      # the same for a window id from `tilewall status --all`
tilewall focus next       # also: prev, or a window id
tilewall orientation portrait   # the focused column grows instead of the focused row; `landscape` switches back
tilewall fill             # make every group fill its screen again
tilewall area -1700 100 1200 700   # place the focused group: x y width height, from the top left of the main display
tilewall send             # move the focused tile to the group of the next display
tilewall pause            # also: resume, retile, reload, stop
```

## The group behaves like one window

The tiles of a display form a group.
Drag any tile by its title bar and the whole group moves with it.
Drop it on another display and the group moves to that display and fills its screen.
Resize any tile by its edge or corner and the whole group scales by the same factor when the mouse is released.
A group is never larger than its screen and never above the top of the desktop.
A moved or resized group stays where it was put, also after a restart, until `tilewall fill` puts it back to full screen.
When focus enters a group from another window, all of its tiles come to the front together.

A tab is not a window, so tabbed sessions must be split first.
`tilewall untab` does that through the app's own "Move Tab to New Window" menu item.

The menu bar icon offers the same actions and lists the tiles of the current space.
Rest the pointer on a menu item to see what it does.

## Square window corners (experimental)

macOS rounds the corners of every window, which leaves notches where tiles meet.
`tilewall corners square`, or Square Window Corners in the menu, switches on an undocumented macOS default (`NSConvolutionOverride1`, macOS 26.4 or later) that makes them square.
`tilewall corners round` switches it off again.

- The default is global: it applies to every app, not only to tiles.
- An app reads it when it starts, so apps that are already open keep their corners until they are restarted.
- tilewall does not restart apps for you.
  Quitting Terminal can end what runs in it, including tmux sessions, so check before you do.
- `tilewall attach <session>` opens a single Terminal window attached to a tmux session.
- Being undocumented, the default can stop working in a later macOS release.

## Hotkeys

Every default sits under the left hand, next to the left control and option keys.
The menu bar menu shows the current keys next to each action, and `tilewall guide` or ctrl+alt+q opens a help window.

| Keys | Action |
|---|---|
| ctrl+alt+t | include or exclude the focused window |
| ctrl+alt+d / ctrl+alt+a | focus the next / previous tile |
| ctrl+alt+f | make every group fill its screen again |
| ctrl+alt+s | send the focused tile to the next display |
| ctrl+alt+r | retile now |
| ctrl+alt+z | pause or resume tiling |
| ctrl+alt+q | open the help window |

## Config

`~/.config/tilewall/config.json` is created on first start.
Run `tilewall reload` after editing it.

```json
{
  "rules": [{ "app": "com.apple.Terminal" }],
  "focusFraction": 0.5,
  "gap": 0,
  "targetAspect": 1.5,
  "backdrop": "auto",
  "orientation": "landscape",
  "hotkeys": { "toggle": "ctrl+alt+t", "next": "ctrl+alt+d", "prev": "ctrl+alt+a", "fill": "ctrl+alt+f", "send": "ctrl+alt+s", "retile": "ctrl+alt+r", "pause": "ctrl+alt+z", "help": "ctrl+alt+q" }
}
```

- `rules`: windows that are tiled automatically.
  `app` is a bundle identifier or an app name.
  The optional `title` is a regular expression, for example `{ "app": "Terminal", "title": "tmux attach -t =aaw-" }` tiles only the agent sessions.
- `focusFraction`: the share of each screen axis the focused tile takes, so 0.5 is a quarter of the screen.
- `gap`: space between tiles, in points.
  The default is 0.
  Tiles are packed using the size each window really took, so apps that snap to character cells, such as Terminal, still touch.
  The leftover of less than one cell ends up at the right and bottom edge of the group.
- `targetAspect`: preferred width to height ratio of a small tile, which decides the grid shape.
- `backdrop`: the color of the plain window tilewall keeps behind each group.
  macOS rounds the corners of every window and gives other apps no way to switch that off.
  The backdrop fills the notches those corners leave, so with a color that matches the windows the corners disappear.
  Use `"#rrggbb"`, `"auto"` to follow the light or dark system appearance, or `"none"` to turn it off.
- `orientation`: `"landscape"` grows the focused row, `"portrait"` grows the focused column.
- An empty hotkey string disables that hotkey.

Any window of any app can be tiled by hand with `tilewall toggle`, whether a rule matches it or not.

## Behavior

- Each display has its own group, and remembers its own focused tile.
- A window joins the group of the display it is first seen on and stays in it, so a dragged group keeps its tiles.
  Use `tilewall send` to move a tile to another display.
- Bringing a whole group to the front works for tiles of the focused app.
  macOS does not let one app raise windows of a background app without activating it.
- Only the current space is tiled, and windows on other spaces keep their slot.
- Minimized, hidden and full screen windows are skipped.
- With three or fewer tiles the focused one is larger than a quarter, because there is nothing else to fill the screen.
- To take one window out of the group, exclude it with `tilewall toggle`.

## Layout of the code

- `Sources/TilewallCore`: the layout math, config and hotkey parsing, with no AppKit dependency and full unit tests.
- `Sources/tilewall`: the daemon (Accessibility, hotkeys, menu bar) and the CLI, which talk over a Unix socket.
- `scripts/release.sh`: builds, signs and notarizes the app.
  Signing settings live in `private/`, which is not part of the repository.

## License

MIT, see [LICENSE](LICENSE).
