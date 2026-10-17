#!/usr/bin/swift
import AppKit

// Original, reproducible Acc artwork. No provider marks or SF Symbols.
guard CommandLine.arguments.count == 2 else { fatalError("Usage: make-icon.swift output.icns") }
let destination = URL(fileURLWithPath: CommandLine.arguments[1])
let directory = destination.deletingLastPathComponent().appendingPathComponent("Acc.iconset")
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: directory) }

func drawIcon() {
    let background = NSBezierPath(roundedRect: NSRect(x: 72, y: 72, width: 880, height: 880), xRadius: 196, yRadius: 196)
    NSGradient(starting: NSColor(srgbRed: 0.22, green: 0.43, blue: 0.86, alpha: 1),
               ending: NSColor(srgbRed: 0.12, green: 0.22, blue: 0.52, alpha: 1))!.draw(in: background, angle: -90)
    func card(_ rect: NSRect, opacity: CGFloat) {
        NSColor.white.withAlphaComponent(opacity).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 48, yRadius: 48).fill()
        let center = rect.midX
        NSColor(srgbRed: 0.23, green: 0.39, blue: 0.72, alpha: opacity).setFill()
        NSBezierPath(ovalIn: NSRect(x: center - 39, y: rect.midY + 14, width: 78, height: 78)).fill()
        NSBezierPath(roundedRect: NSRect(x: center - 70, y: rect.midY - 79, width: 140, height: 70), xRadius: 35, yRadius: 35).fill()
    }
    card(NSRect(x: 480, y: 396, width: 304, height: 376), opacity: 0.65)
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.18)
    shadow.shadowBlurRadius = 24; shadow.shadowOffset = NSSize(width: 0, height: -10)
    NSGraphicsContext.saveGraphicsState(); shadow.set()
    card(NSRect(x: 240, y: 252, width: 336, height: 412), opacity: 1)
    NSGraphicsContext.restoreGraphicsState()
    let arrow = NSBezierPath()
    arrow.lineWidth = 26; arrow.lineCapStyle = .round; arrow.lineJoinStyle = .round
    arrow.move(to: NSPoint(x: 278, y: 772)); arrow.line(to: NSPoint(x: 414, y: 772))
    arrow.move(to: NSPoint(x: 380, y: 806)); arrow.line(to: NSPoint(x: 414, y: 772)); arrow.line(to: NSPoint(x: 380, y: 738))
    arrow.move(to: NSPoint(x: 746, y: 252)); arrow.line(to: NSPoint(x: 610, y: 252))
    arrow.move(to: NSPoint(x: 644, y: 286)); arrow.line(to: NSPoint(x: 610, y: 252)); arrow.line(to: NSPoint(x: 644, y: 218))
    NSColor.white.withAlphaComponent(0.95).setStroke(); arrow.stroke()
}

for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = points * scale
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        let transform = NSAffineTransform()
        transform.scale(by: CGFloat(pixels) / 1024); transform.concat()
        drawIcon()
        NSGraphicsContext.restoreGraphicsState()
        let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
        try bitmap.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent(name))
    }
}
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", "-o", destination.path, directory.path]
try task.run(); task.waitUntilExit()
exit(task.terminationStatus)
