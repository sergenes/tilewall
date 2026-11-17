import Foundation
import TilewallCore

let usage = """
tilewall: tiles windows in a grid and grows the focused one to a quarter of the screen.

  tilewall start            start the daemon in the background
  tilewall run              run the daemon in the foreground
  tilewall stop             stop the daemon
  tilewall status [--all]   list tiles, with --all also the visible windows that are not tiled
  tilewall all              tile every window the rules match, undoing manual excludes
  tilewall none             release every tile on the current space
  tilewall rule [add|remove <app>]   list the apps that are tiled automatically, or change them
  tilewall toggle [id]      include or exclude the focused window, or the window with that id
  tilewall include [id]     tile a window
  tilewall exclude [id]     stop tiling a window
  tilewall focus next|prev|<id>
  tilewall move next|prev [id]   swap a tile with its neighbour, so it takes that slot
  tilewall orientation [landscape|portrait]   tiles in rows, or in columns
  tilewall fill             make every group fill its screen again
  tilewall area <x> <y> <width> <height>   place the focused group, origin at the top left of the main display
  tilewall display [<number> on|off]   list displays, or switch tiling on or off for one
  tilewall send [id]        move a tile to the group of the next display
  tilewall guide            open the help window with the hotkeys
  tilewall corners [square|round]   square window corners for apps started from now on
  tilewall attach <session> open a Terminal window attached to a tmux session
  tilewall sessions         list the tmux sessions attached in Terminal windows
  tilewall untab            move every tab of the rule-matched apps into its own window
  tilewall retile | pause | resume | reload
  tilewall version

Config: \(Paths.config.path)
"""

let arguments = Array(CommandLine.arguments.dropFirst())
switch arguments.first {
case nil where App.isBundled:
    // Opened as an app (Finder, Launchpad, login item): there is no terminal, so log to the file.
    freopen(Paths.log.path, "a", stderr)
    Daemon.run()
case nil, "help", "-h", "--help":
    print(usage)
case "version", "--version":
    print("tilewall \(App.version)")
case "run":
    Daemon.run()
case "start":
    if IPC.send("ping") != nil {
        print("tilewall is already running")
        break
    }
    do {
        try FileManager.default.createDirectory(at: Paths.home, withIntermediateDirectories: true)
        let launcher = Process()
        launcher.executableURL = URL(fileURLWithPath: "/bin/sh")
        try? FileManager.default.createDirectory(at: Paths.home, withIntermediateDirectories: true)
        if let app = App.bundleURL {
            // Part of an app bundle: start it the way Finder would, so macOS treats it as the app.
            launcher.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            launcher.arguments = [app.path]
        } else {
            launcher.arguments = ["-c", "nohup \"$0\" run >> \"$1\" 2>&1 &", Bundle.main.executablePath ?? CommandLine.arguments[0], Paths.log.path]
        }
        try launcher.run()
        launcher.waitUntilExit()
    } catch {
        FileHandle.standardError.write(Data("cannot start: \(error.localizedDescription)\n".utf8))
        exit(1)
    }
    var up = false
    for _ in 0..<50 where !up {
        usleep(100_000)
        up = IPC.send("ping") != nil
    }
    if up {
        print("tilewall started, log: \(Paths.log.path)")
    } else {
        FileHandle.standardError.write(Data("tilewall did not start, see \(Paths.log.path)\n".utf8))
        exit(1)
    }
default:
    guard let reply = IPC.send(arguments.joined(separator: " ")) else {
        FileHandle.standardError.write(Data("tilewall is not running, start it with: tilewall start\n".utf8))
        exit(1)
    }
    print(reply, terminator: "")
    exit(reply.hasPrefix("error:") ? 1 : 0)
}
