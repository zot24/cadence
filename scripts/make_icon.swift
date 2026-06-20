#!/usr/bin/env swift
// Renders Cadence's app icon to an .icns. Usage: swift make_icon.swift <out.icns>
// On-brand motif: indigo→purple squircle with rising rounded bars (a run-history
// / cadence visualization), plus a small clock tick — Cadence tracks runs over time.
import AppKit
import Foundation

func drawIcon(px: Int) -> NSBitmapImageRep {
    let size = CGFloat(px)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                               isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    // Rounded-rect "squircle" body, inset to leave macOS-style padding.
    let inset = size * 0.09
    let rect = NSRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    let radius = rect.width * 0.225
    let body = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)

    let gradient = NSGradient(colors: [
        NSColor(srgbRed: 0.36, green: 0.36, blue: 0.84, alpha: 1),   // indigo
        NSColor(srgbRed: 0.55, green: 0.36, blue: 0.96, alpha: 1),   // violet
    ])!
    gradient.draw(in: body, angle: -55)

    // Rising rounded bars (cadence / run-history motif).
    let barCount = 4
    let heights: [CGFloat] = [0.34, 0.55, 0.44, 0.78]
    let area = rect.insetBy(dx: rect.width * 0.20, dy: rect.height * 0.22)
    let gap = area.width * 0.07
    let barW = (area.width - gap * CGFloat(barCount - 1)) / CGFloat(barCount)
    for i in 0..<barCount {
        let h = area.height * heights[i]
        let x = area.minX + CGFloat(i) * (barW + gap)
        let r = NSRect(x: x, y: area.minY, width: barW, height: h)
        let br = barW * 0.42
        let bar = NSBezierPath(roundedRect: r, xRadius: br, yRadius: br)
        NSColor.white.withAlphaComponent(0.92).setFill()
        bar.fill()
    }

    // Small clock tick dot on the tallest bar (a "run" marker).
    let lastX = area.minX + CGFloat(barCount - 1) * (barW + gap) + barW / 2
    let dotR = barW * 0.5
    let topY = area.minY + area.height * heights[barCount - 1]
    let dot = NSBezierPath(ovalIn: NSRect(x: lastX - dotR, y: topY - dotR * 0.4,
                                          width: dotR * 2, height: dotR * 2))
    NSColor(srgbRed: 0.36, green: 0.36, blue: 0.84, alpha: 1).setFill()
    dot.fill()
    NSColor.white.setStroke()
    dot.lineWidth = size * 0.012
    dot.stroke()

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

guard CommandLine.arguments.count >= 2 else {
    FileHandle.standardError.write(Data("usage: make_icon.swift <out.icns>\n".utf8)); exit(64)
}
let outPath = CommandLine.arguments[1]
let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("Cadence-\(UUID().uuidString).iconset")
try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)

// (pixel size, iconset filename)
let variants: [(Int, String)] = [
    (16, "icon_16x16.png"), (32, "icon_16x16@2x.png"),
    (32, "icon_32x32.png"), (64, "icon_32x32@2x.png"),
    (128, "icon_128x128.png"), (256, "icon_128x128@2x.png"),
    (256, "icon_256x256.png"), (512, "icon_256x256@2x.png"),
    (512, "icon_512x512.png"), (1024, "icon_512x512@2x.png"),
]
for (px, name) in variants {
    let png = drawIcon(px: px).representation(using: .png, properties: [:])!
    try png.write(to: tmp.appendingPathComponent(name))
}

let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", tmp.path, "-o", outPath]
try p.run(); p.waitUntilExit()
try? FileManager.default.removeItem(at: tmp)
print(p.terminationStatus == 0 ? "✓ wrote \(outPath)" : "✗ iconutil failed (\(p.terminationStatus))")
exit(p.terminationStatus)
