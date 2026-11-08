import SwiftUI
import AppKit
import AccCore

/// Credential-free renders of the shipping views for layout review and documentation.
@MainActor enum PreviewRenderer {
    static func render(to directory: URL) throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for theme in ["light", "dark"] {
            let appearance = NSAppearance(named: theme == "light" ? .aqua : .darkAqua)!
            for state in ["accounts", "claude", "current", "empty", "error", "keychain", "detached", "pending", "signin", "short", "tall", "uncertain", "used", "window"] {
                let model = AppModel(demo: true)
                if state == "claude" { model.selectedProvider = .claude }
                if state == "current" {
                    let active = model.accounts[0]
                    model.accounts = []
                    model.current = [CurrentLogin(provider: .codex, identity: active.identity)]
                    model.observedUsage[.codex] = active.usage
                }
                if state == "empty" { model.accounts = []; model.current = [] }
                if state == "keychain" {
                    model.accounts = []; model.selectedProvider = .claude
                    model.current = [CurrentLogin(provider: .claude, message: "Allow Keychain access to show your active Claude subscription.", requiresKeychainAccess: true)]
                }
                if state == "signin" { model.signingIn = .codex; model.busy = true }
                if state == "error" {
                    model.accounts[0].health = .needsSignIn
                    model.accounts[0].renewalHealth = .needsSignIn
                    model.accounts[0].message = "Sign in again to refresh this account."
                    model.message = "Could not reach the provider. Acc will retry later."
                }
                if state == "uncertain" {
                    model.accounts[0].health = .uncertain; model.accounts[0].renewalHealth = .uncertain
                    model.accounts[0].message = AccError.refreshUncertain.localizedDescription
                    model.accounts[0].nextRefreshAt = nil
                }
                if state == "used" { model.setUsageDisplay(.used) }
                if state == "detached" { model.accounts[0].isPaused = true }
                if state == "pending" {
                    model.pending = try JSONDecoder().decode([PendingSignIn].self, from: Data("""
                    [{"id":"00000000-0000-0000-0000-000000000010","provider":"codex","createdAt":0}]
                    """.utf8))
                }
                try snapshot(AccountPanel(model: model, compact: state != "window"), size: NSSize(width: state == "window" ? 440 : 380, height: state == "short" ? 320 : state == "tall" ? 740 : state == "claude" ? 320 : 490),
                    appearance: appearance, material: state != "window", to: directory.appendingPathComponent("\(state)-\(theme).png"))
            }
            try snapshot(AccSettings(model: AppModel(demo: true)), size: NSSize(width: 480, height: 560),
                appearance: appearance, to: directory.appendingPathComponent("settings-\(theme).png"))
            try renderMenuBar(theme: theme, to: directory.appendingPathComponent("menubar-\(theme).png"))
        }
        print("Rendered 32 credential-free previews to \(directory.path)")
    }
    /// Every icon style, including a provider that reports only a weekly window
    /// and one without usage, on the menu bar's own tint.
    private static func renderMenuBar(theme: String, to url: URL) throws {
        func window(_ id: String, _ remaining: Double) -> UsageWindow {
            UsageWindow(id: id, title: id, usedPercent: 100 - remaining)
        }
        let cells = [
            StatusIcon.Cell(provider: .codex, windows: [window("weekly", 53)], stale: false),
            StatusIcon.Cell(provider: .claude, windows: [window("fiveHour", 71), window("weekly", 34)], stale: false),
        ]
        let rows: [NSImage] = [
            StatusIcon.make(cells: cells, style: .bars, attention: false),
            StatusIcon.make(cells: cells, style: .percent, attention: false),
            StatusIcon.make(cells: cells, style: .logos, attention: false),
            StatusIcon.make(cells: cells, style: .symbol, attention: false),
            StatusIcon.make(cells: [StatusIcon.Cell(provider: .codex, windows: [], stale: true), cells[1]], style: .bars, attention: true),
        ]
        let scale: CGFloat = 4, rowHeight: CGFloat = 24
        let size = NSSize(width: 120, height: rowHeight * CGFloat(rows.count))
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale),
            pixelsHigh: Int(size.height * scale), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { throw AccError.storage }
        bitmap.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        let dark = theme == "dark"
        (dark ? NSColor(white: 0.16, alpha: 1) : NSColor(white: 0.93, alpha: 1)).setFill()
        NSRect(origin: .zero, size: size).fill()
        for (index, image) in rows.enumerated() {
            let y = size.height - rowHeight * CGFloat(index + 1) + (rowHeight - image.size.height) / 2
            let rect = NSRect(x: 8, y: y, width: image.size.width, height: image.size.height)
            // Tint the template the way the menu bar does: ink where the image is opaque.
            let tinted = NSImage(size: image.size, flipped: false) { bounds in
                image.draw(in: bounds)
                (dark ? NSColor.white : NSColor.black).set()
                bounds.fill(using: .sourceAtop)
                return true
            }
            tinted.draw(in: rect)
        }
        NSGraphicsContext.restoreGraphicsState()
        guard let data = bitmap.representation(using: .png, properties: [:]) else { throw AccError.storage }
        try data.write(to: url)
    }
    private static func snapshot<V: View>(_ content: V, size: NSSize, appearance: NSAppearance, material: Bool = false, to url: URL) throws {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless], backing: .buffered, defer: false)
        let view = NSHostingView(rootView: content
            .environment(\.colorScheme, appearance.name == .darkAqua ? .dark : .light))
        view.sizingOptions = []
        window.appearance = appearance
        view.appearance = appearance
        let surface: NSView
        if material {
            // Preview-only container uses the same system material supplied by
            // the shipping NSPopover. The actual app has no custom background.
            let effect = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
            effect.material = .popover
            effect.blendingMode = .behindWindow
            effect.state = .active
            surface = effect
        } else { surface = NSView(frame: NSRect(origin: .zero, size: size)) }
        surface.addSubview(view)
        window.contentView = surface
        view.frame = NSRect(origin: .zero, size: size)
        surface.layoutSubtreeIfNeeded()
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil,
            pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { throw AccError.storage }
        bitmap.size = size
        surface.cacheDisplay(in: surface.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { throw AccError.storage }
        try data.write(to: url)
    }
}
