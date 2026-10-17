import SwiftUI
import AppKit
import AccCore

@main
struct AccEntry {
    @MainActor static func main() {
        if let index = CommandLine.arguments.firstIndex(of: "--render-previews"), index + 1 < CommandLine.arguments.count {
            do { try PreviewRenderer.render(to: URL(fileURLWithPath: CommandLine.arguments[index + 1])) }
            catch { FileHandle.standardError.write(Data("Could not render previews.\n".utf8)); exit(1) }
            return
        }
        let app = NSApplication.shared
        let model = AppModel()
        app.setActivationPolicy(model.presentation == .window ? .regular : .accessory)
        let delegate = AccAppDelegate(model: model)
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}

@MainActor enum StatusIcon {
    static func make(model: AppModel) -> NSImage {
        let providers = Provider.allCases
        let showUsage = model.preferences.showUsage
        let usage = Dictionary(uniqueKeysWithValues: providers.map { ($0, showUsage ? model.activeUsage($0) : nil) })
        let cellWidth: CGFloat = showUsage ? 35 : 21
        let image = NSImage(size: NSSize(width: cellWidth * 2, height: 18), flipped: true) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            for (index, provider) in providers.enumerated() {
                let x = CGFloat(index) * cellWidth
                let path = ProviderMark(provider: provider).path(in: CGRect(x: x, y: 0, width: 18, height: 18))
                context.setFillColor(NSColor.black.cgColor); context.addPath(path.cgPath); context.fillPath()
                if showUsage {
                    for (row, window) in [usage[provider]??.fiveHour, usage[provider]??.weekly].enumerated() {
                        let bar = CGRect(x: x + 20, y: CGFloat(5 + row * 6), width: 12, height: 3)
                        context.setFillColor(NSColor.black.withAlphaComponent(0.22).cgColor)
                        context.fill(bar)
                        if let window {
                            context.setFillColor(NSColor.black.cgColor)
                            context.fill(CGRect(x: bar.minX, y: bar.minY, width: bar.width * window.remainingPercent / 100, height: bar.height))
                        }
                    }
                }
            }
            return true
        }
        if model.needsAttention {
            image.lockFocus()
            NSColor.black.setFill()
            NSBezierPath(ovalIn: NSRect(x: image.size.width - 4, y: 13, width: 4, height: 4)).fill()
            image.unlockFocus()
        }
        image.isTemplate = true
        return image
    }
}
