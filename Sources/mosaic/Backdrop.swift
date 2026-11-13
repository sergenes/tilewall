import Cocoa

/// A plain window kept right behind each group.
///
/// macOS draws rounded corners on every window and gives other apps no way to turn them off.
/// Where tiles meet, those corners leave small notches that show the desktop.
/// The backdrop fills the notches with one color, so the group reads as a single slab.
final class Backdrop {
    private var windows: [CGDirectDisplayID: NSWindow] = [:]

    /// `frame` is in accessibility coordinates, `tiles` are the window ids of the group.
    func update(_ groups: [(screen: CGDirectDisplayID, frame: CGRect, tiles: [CGWindowID])], color: NSColor?) {
        guard let color, let primary = NSScreen.screens.first else { return hide() }
        let stacking = onScreenOrder()
        for (screen, window) in windows where !groups.contains(where: { $0.screen == screen }) {
            window.orderOut(nil)
        }
        for group in groups {
            // Front to back order: the last tile in it is the one furthest back.
            guard !group.frame.isEmpty, let lowest = stacking.last(where: group.tiles.contains) else {
                windows[group.screen]?.orderOut(nil)
                continue
            }
            let window = windows[group.screen] ?? makeWindow()
            windows[group.screen] = window
            window.backgroundColor = color
            let frame = CGRect(x: group.frame.minX, y: primary.frame.maxY - group.frame.maxY, width: group.frame.width, height: group.frame.height)
            if window.frame != frame { window.setFrame(frame, display: true) }
            window.order(.below, relativeTo: Int(lowest))
        }
    }

    func hide() {
        windows.values.forEach { $0.orderOut(nil) }
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.ignoresMouseEvents = true
        window.hasShadow = false
        window.isOpaque = true
        window.animationBehavior = .none
        window.collectionBehavior = [.canJoinAllSpaces, .ignoresCycle, .fullScreenNone]
        return window
    }

    private func onScreenOrder() -> [CGWindowID] {
        let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        return info.compactMap { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value }
    }

    /// "auto", "none" or "#rrggbb".
    static func color(_ text: String) -> NSColor? {
        let value = text.trimmingCharacters(in: .whitespaces).lowercased()
        if value == "none" || value.isEmpty { return nil }
        if value.hasPrefix("#"), value.count == 7, let rgb = UInt32(value.dropFirst(), radix: 16) {
            return NSColor(srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255, green: CGFloat((rgb >> 8) & 0xFF) / 255, blue: CGFloat(rgb & 0xFF) / 255, alpha: 1)
        }
        let dark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return dark ? NSColor(srgbRed: 0.11, green: 0.11, blue: 0.11, alpha: 1) : NSColor(srgbRed: 0.93, green: 0.93, blue: 0.93, alpha: 1)
    }
}
