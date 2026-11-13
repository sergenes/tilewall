import ApplicationServices
import Cocoa

// Private but stable API used by every macOS tiler to map an accessibility window to its CGWindowID.
@_silgen_name("_AXUIElementGetWindow")
func _AXUIElementGetWindow(_ element: AXUIElement, _ id: UnsafeMutablePointer<CGWindowID>) -> AXError

extension AXUIElement {
    func value(_ name: String) -> CFTypeRef? {
        var v: CFTypeRef?
        return AXUIElementCopyAttributeValue(self, name as CFString, &v) == .success ? v : nil
    }

    func string(_ name: String) -> String? { value(name) as? String }
    func bool(_ name: String) -> Bool? { value(name) as? Bool }
    func elements(_ name: String) -> [AXUIElement] { value(name) as? [AXUIElement] ?? [] }

    func element(_ name: String) -> AXUIElement? {
        guard let v = value(name), CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return (v as! AXUIElement)
    }

    var windowID: CGWindowID? {
        var id: CGWindowID = 0
        return _AXUIElementGetWindow(self, &id) == .success && id != 0 ? id : nil
    }

    /// Frame in accessibility coordinates: origin at the top left of the primary screen, y grows down.
    var frame: CGRect? {
        guard let p = value(kAXPositionAttribute), let s = value(kAXSizeAttribute),
              CFGetTypeID(p) == AXValueGetTypeID(), CFGetTypeID(s) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        var size = CGSize.zero
        AXValueGetValue(p as! AXValue, .cgPoint, &point)
        AXValueGetValue(s as! AXValue, .cgSize, &size)
        return CGRect(origin: point, size: size)
    }

    func setFrame(_ rect: CGRect) {
        var size = rect.size
        var origin = rect.origin
        guard let sizeValue = AXValueCreate(.cgSize, &size), let originValue = AXValueCreate(.cgPoint, &origin) else { return }
        // Size, position, size: the first resize can be clamped by the screen the window is leaving.
        AXUIElementSetAttributeValue(self, kAXSizeAttribute as CFString, sizeValue)
        AXUIElementSetAttributeValue(self, kAXPositionAttribute as CFString, originValue)
        AXUIElementSetAttributeValue(self, kAXSizeAttribute as CFString, sizeValue)
    }

    /// Number of native tabs shown in this window's tab bar, 0 when it has none.
    var tabCount: Int {
        for child in elements(kAXChildrenAttribute) where child.string(kAXRoleAttribute) == "AXTabGroup" {
            let tabs = child.elements("AXTabs")
            if !tabs.isEmpty { return tabs.count }
            return child.elements(kAXChildrenAttribute).filter { $0.string(kAXRoleAttribute) == "AXRadioButton" }.count
        }
        return 0
    }

    func menuItem(titled title: String, depth: Int = 0) -> AXUIElement? {
        guard depth < 6 else { return nil }
        for child in elements(kAXChildrenAttribute) {
            if child.string(kAXRoleAttribute) == "AXMenuItem", child.string(kAXTitleAttribute) == title { return child }
            if let found = child.menuItem(titled: title, depth: depth + 1) { return found }
        }
        return nil
    }
}

/// Usable area of every screen in accessibility coordinates, keyed by display id.
func screenAreas() -> [(id: CGDirectDisplayID, area: CGRect)] {
    guard let primary = NSScreen.screens.first else { return [] }
    return NSScreen.screens.compactMap { screen in
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
        let v = screen.visibleFrame
        return (number.uint32Value, CGRect(x: v.minX, y: primary.frame.maxY - v.maxY, width: v.width, height: v.height))
    }
}
