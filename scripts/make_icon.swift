// Draws the app icon and writes Resources/AppIcon.icns. Run: swift scripts/make_icon.swift
import AppKit

func draw(size: Int) -> Data {
    let s = CGFloat(size)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    // macOS icon grid: the artwork sits inside a 10% margin with a continuous rounded shape.
    let plate = NSRect(x: s * 0.1, y: s * 0.1, width: s * 0.8, height: s * 0.8)
    let path = NSBezierPath(roundedRect: plate, xRadius: s * 0.18, yRadius: s * 0.18)
    NSGradient(colors: [NSColor(srgbRed: 0.13, green: 0.15, blue: 0.20, alpha: 1), NSColor(srgbRed: 0.07, green: 0.08, blue: 0.11, alpha: 1)])!
        .draw(in: path, angle: -90)
    path.addClip()

    // A 4 by 4 grid in which the focused tile takes a quarter: one large tile, the rest small.
    let inset = s * 0.17, gap = s * 0.022
    let area = NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let widths: [CGFloat] = [0.5, 0.25, 0.25], heights: [CGFloat] = [0.5, 0.25, 0.25]
    let colors: [NSColor] = [
        NSColor(srgbRed: 0.98, green: 0.80, blue: 0.28, alpha: 1), NSColor(srgbRed: 0.31, green: 0.56, blue: 0.97, alpha: 1),
        NSColor(srgbRed: 0.93, green: 0.42, blue: 0.38, alpha: 1), NSColor(srgbRed: 0.36, green: 0.78, blue: 0.56, alpha: 1),
        NSColor(srgbRed: 0.62, green: 0.50, blue: 0.94, alpha: 1), NSColor(srgbRed: 0.40, green: 0.45, blue: 0.55, alpha: 1),
    ]
    var index = 0
    var top = area.maxY
    for (r, h) in heights.enumerated() {
        var left = area.minX
        for (c, w) in widths.enumerated() {
            let cell = NSRect(x: left, y: top - area.height * h, width: area.width * w, height: area.height * h).insetBy(dx: gap / 2, dy: gap / 2)
            let focused = r == 0 && c == 0
            (focused ? colors[0] : colors[1 + index % 5].withAlphaComponent(0.9)).setFill()
            NSBezierPath(roundedRect: cell, xRadius: s * 0.012, yRadius: s * 0.012).fill()
            if !focused { index += 1 }
            left += area.width * w
        }
        top -= area.height * h
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let iconset = root.appendingPathComponent(".build/AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try draw(size: base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try draw(size: base * 2).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
let tool = Process()
tool.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
tool.arguments = ["-c", "icns", iconset.path, "-o", root.appendingPathComponent("Resources/AppIcon.icns").path]
try tool.run()
tool.waitUntilExit()
print(tool.terminationStatus == 0 ? "wrote Resources/AppIcon.icns" : "iconutil failed")
