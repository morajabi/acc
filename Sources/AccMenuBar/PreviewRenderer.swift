import SwiftUI
import AppKit
import AccCore

/// Credential-free renders of the shipping views for layout review and documentation.
@MainActor enum PreviewRenderer {
    static func render(to directory: URL) throws {
        let app = NSApplication.shared
        let previousApplication = NSWorkspace.shared.frontmostApplication
        app.setActivationPolicy(.accessory)
        app.finishLaunching()
        app.activate(ignoringOtherApps: true)
        defer {
            if app.isActive { previousApplication?.activate(options: []) }
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for theme in ["light", "dark"] {
            let appearance = NSAppearance(named: theme == "light" ? .aqua : .darkAqua)!
            for state in ["accounts", "claude", "current", "empty", "error", "keychain", "detached", "pending", "signin", "short", "tall", "uncertain", "window"] {
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
                if state == "detached" { model.accounts[0].isPaused = true }
                if state == "pending" {
                    model.pending = try JSONDecoder().decode([PendingSignIn].self, from: Data("""
                    [{"id":"00000000-0000-0000-0000-000000000010","provider":"codex","createdAt":0}]
                    """.utf8))
                }
                try snapshot(AccountPanel(model: model, compact: state != "window"), size: NSSize(width: state == "window" ? 440 : 380, height: state == "short" ? 320 : state == "tall" ? 740 : state == "claude" ? 320 : 490),
                    appearance: appearance, material: state != "window", to: directory.appendingPathComponent("\(state)-\(theme).png"))
            }
            try snapshot(AccSettings(model: AppModel(demo: true)), size: NSSize(width: 480, height: 440),
                appearance: appearance, to: directory.appendingPathComponent("settings-\(theme).png"))
        }
        print("Rendered 28 credential-free previews to \(directory.path)")
    }
    private static func snapshot<V: View>(_ content: V, size: NSSize, appearance: NSAppearance, material: Bool = false, to url: URL) throws {
        let window = PreviewWindow(contentRect: NSRect(origin: NSPoint(x: -10_000, y: -10_000), size: size),
            styleMask: [.borderless], backing: .buffered, defer: false)
        let view = NSHostingView(rootView: ActivePreview(content: content)
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
        // Establish real AppKit key state without ordering any preview window
        // onscreen. This also gives represented native controls their active tint.
        window.makeKey()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
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

private final class PreviewWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

private struct ActivePreview<Content: View>: View {
    let content: Content

    var body: some View {
        if #available(macOS 15, *) { content.environment(\.appearsActive, true) }
        else { content.environment(\.controlActiveState, .key) }
    }
}
