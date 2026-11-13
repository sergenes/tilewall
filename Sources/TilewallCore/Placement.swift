import Foundation

/// Decides which display's group a window belongs to, or whether Tilewall leaves it alone.
public enum Placement: Equatable {
    /// Tile the window in the group of this display.
    case tile(display: String)
    /// Do not move or resize the window.
    case leave

    /// - Parameters:
    ///   - home: the display the window belongs to, nil for a window seen for the first time.
    ///   - current: the display the window is on right now.
    ///   - connected: the displays that are plugged in.
    ///   - untiled: the displays the user switched tiling off for, connected or not.
    /// - Returns: what to do with the window, and the display to remember as its home.
    ///
    /// A home is sticky, so a group that is dragged around keeps its tiles, and a window whose display was
    /// unplugged goes back to it when the display returns. Until then a window from a tiled display is tiled
    /// wherever macOS put it, and a window from an untiled display stays untouched.
    public static func decide(home: String?, current: String, connected: Set<String>, untiled: Set<String>) -> (placement: Placement, home: String) {
        guard let home else {
            return (untiled.contains(current) ? .leave : .tile(display: current), current)
        }
        if connected.contains(home) {
            if !untiled.contains(home) { return (.tile(display: home), home) }
            // On an untiled display nothing holds a window in place, so follow it when the user moves it to a tiled one.
            if current != home, !untiled.contains(current) { return (.tile(display: current), current) }
            return (.leave, home)
        }
        if untiled.contains(home) || untiled.contains(current) { return (.leave, home) }
        return (.tile(display: current), home)
    }
}
