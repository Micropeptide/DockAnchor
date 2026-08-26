#!/usr/bin/env swift
import AppKit

// Renders the DockAnchor app icon at every size macOS needs for an .iconset,
// then leaves it to `iconutil` (invoked by build.sh) to pack into an .icns.

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

func tinted(_ image: NSImage, _ color: NSColor) -> NSImage {
    let result = NSImage(size: image.size)
    result.lockFocus()
    let rect = NSRect(origin: .zero, size: image.size)
    image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1.0)
    color.set()
    rect.fill(using: .sourceAtop)
    result.unlockFocus()
    return result
}

func drawIcon(size: CGFloat) {
    let rect = NSRect(x: 0, y: 0, width: size, height: size)
    let corner = size * 0.223
    let bgPath = NSBezierPath(roundedRect: rect, xRadius: corner, yRadius: corner)
    let gradient = NSGradient(
        starting: NSColor(calibratedRed: 0.07, green: 0.12, blue: 0.27, alpha: 1.0),
        ending: NSColor(calibratedRed: 0.13, green: 0.47, blue: 0.62, alpha: 1.0))
    gradient?.draw(in: bgPath, angle: -90)

    // Subtle top sheen for depth.
    let sheenPath = NSBezierPath(roundedRect: rect, xRadius: corner, yRadius: corner)
    NSGraphicsContext.saveGraphicsState()
    sheenPath.addClip()
    let sheen = NSGradient(
        starting: NSColor.white.withAlphaComponent(0.16),
        ending: NSColor.white.withAlphaComponent(0.0))
    sheen?.draw(in: NSRect(x: 0, y: size * 0.5, width: size, height: size * 0.5), angle: -90)
    NSGraphicsContext.restoreGraphicsState()

    // Monitor outline.
    let inset = size * 0.20
    let monitorHeight = size * 0.38
    let monitorY = size * 0.42
    let monitorRect = NSRect(x: inset, y: monitorY, width: size - inset * 2, height: monitorHeight)
    let monitorPath = NSBezierPath(roundedRect: monitorRect, xRadius: size * 0.045, yRadius: size * 0.045)
    monitorPath.lineWidth = size * 0.034
    NSColor.white.withAlphaComponent(0.95).setStroke()
    monitorPath.stroke()

    // Stand.
    let standWidth = size * 0.09
    let standRect = NSRect(x: (size - standWidth) / 2, y: monitorY - size * 0.055, width: standWidth, height: size * 0.055)
    NSColor.white.withAlphaComponent(0.55).setFill()
    NSBezierPath(rect: standRect).fill()

    // Dock pill, pinned in place by the anchor.
    let dockWidth = size * 0.48
    let dockHeight = size * 0.075
    let dockRect = NSRect(x: (size - dockWidth) / 2, y: size * 0.195, width: dockWidth, height: dockHeight)
    let dockPath = NSBezierPath(roundedRect: dockRect, xRadius: dockHeight / 2, yRadius: dockHeight / 2)
    NSColor.white.withAlphaComponent(0.97).setFill()
    dockPath.fill()

    // Pin glyph (SF Symbol), tinted amber, centered under the dock pill —
    // reads as "pinned in place" on this display.
    if let symbol = NSImage(systemSymbolName: "pin.fill", accessibilityDescription: nil) {
        let cfg = NSImage.SymbolConfiguration(pointSize: size * 0.5, weight: .bold)
        if let configured = symbol.withSymbolConfiguration(cfg) {
            let amber = NSColor(calibratedRed: 0.98, green: 0.73, blue: 0.18, alpha: 1.0)
            let colored = tinted(configured, amber)
            let natural = colored.size
            let targetHeight = size * 0.30
            let scale = targetHeight / natural.height
            let drawSize = NSSize(width: natural.width * scale, height: natural.height * scale)
            let origin = NSPoint(x: (size - drawSize.width) / 2, y: size * 0.10)
            colored.draw(in: NSRect(origin: origin, size: drawSize), from: .zero, operation: .sourceOver, fraction: 1.0)
        }
    }
}

func renderPNG(size: Int) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = ctx
    drawIcon(size: CGFloat(size))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let mapping: [(Int, String)] = [
    (16, "icon_16x16.png"),
    (32, "icon_16x16@2x.png"),
    (32, "icon_32x32.png"),
    (64, "icon_32x32@2x.png"),
    (128, "icon_128x128.png"),
    (256, "icon_128x128@2x.png"),
    (256, "icon_256x256.png"),
    (512, "icon_256x256@2x.png"),
    (512, "icon_512x512.png"),
    (1024, "icon_512x512@2x.png"),
]

var cache: [Int: Data] = [:]
for (px, name) in mapping {
    let data = cache[px] ?? renderPNG(size: px)
    cache[px] = data
    let path = (outDir as NSString).appendingPathComponent(name)
    try! data.write(to: URL(fileURLWithPath: path))
    print("wrote \(path)")
}
