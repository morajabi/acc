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
        AccApplication.main()
    }
}

/// SwiftUI owns the standard Settings scene and app commands. AppKit only hosts
/// the status-item popover and the optional, resizable Accounts window.
@MainActor private struct AccApplication: App {
    @NSApplicationDelegateAdaptor(AccAppDelegate.self) private var delegate

    var body: some Scene {
        Settings {
            AccSettings(model: delegate.model)
                .onAppear { NSApp.activate(ignoringOtherApps: true) }
        }
            .commands {
                CommandGroup(after: .appInfo) {
                    Button("Accounts") { delegate.showAccounts() }
                        .keyboardShortcut("a", modifiers: [.command, .shift])
                }
                CommandMenu("Account") {
                    Button("Sign In with Browser…") { delegate.model.signIn(delegate.model.selectedProvider) }
                        .keyboardShortcut("n").disabled(delegate.model.busy)
                    Button("Save Current Account") { delegate.model.saveCurrent(delegate.model.selectedProvider) }
                        .disabled(delegate.model.busy || delegate.model.selectedCurrent?.identity == nil
                            || delegate.model.selectedCurrent?.savedAccountID != nil)
                    Button("Import from File…") { delegate.model.importFile(delegate.model.selectedProvider) }
                        .keyboardShortcut("o").disabled(delegate.model.busy)
                    Divider()
                    Button("Refresh Accounts") { delegate.model.refreshAll() }
                        .keyboardShortcut("r").disabled(delegate.model.busy || delegate.model.updating)
                    Divider()
                    Button("Show ChatGPT") { delegate.model.selectedProvider = .codex }.keyboardShortcut("1")
                    Button("Show Claude") { delegate.model.selectedProvider = .claude }.keyboardShortcut("2")
                }
                CommandGroup(replacing: .help) {
                    Link("Acc on GitHub", destination: URL(string: "https://github.com/morajabi/acc")!)
                    if delegate.model.isDemo {
                        Button("Reset Preview Accounts") { delegate.model.resetDemo() }
                    }
                }
            }
    }
}

@MainActor enum StatusIcon {
    static func make(model: AppModel) -> NSImage {
        let providers = Provider.allCases
        let showUsage = model.preferences.showUsage
        let usage = Dictionary(uniqueKeysWithValues: providers.compactMap { provider -> (Provider, UsageSnapshot)? in
            guard showUsage, let snapshot = model.activeUsage(provider) else { return nil }
            return (provider, snapshot)
        })
        let staleProviders = Set(providers.filter { model.activeUsageIsStale($0) })
        let cellWidth: CGFloat = showUsage ? 35 : 21
        let image = NSImage(size: NSSize(width: cellWidth * 2, height: 18), flipped: true) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            for (index, provider) in providers.enumerated() {
                let x = CGFloat(index) * cellWidth
                let path = ProviderMark(provider: provider).path(in: CGRect(x: x, y: 0, width: 18, height: 18))
                context.setFillColor(NSColor.black.cgColor); context.addPath(path.cgPath); context.fillPath()
                if showUsage {
                    for (row, window) in [usage[provider]?.fiveHour, usage[provider]?.weekly].enumerated() {
                        let bar = CGRect(x: x + 20, y: CGFloat(5 + row * 6), width: 12, height: 3)
                        context.setFillColor(NSColor.black.withAlphaComponent(0.22).cgColor)
                        context.fill(bar)
                        if let window {
                            let stale = staleProviders.contains(provider)
                            context.setFillColor(NSColor.black.withAlphaComponent(stale ? 0.45 : 1).cgColor)
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
    static func tooltip(model: AppModel) -> String {
        var lines = [model.needsAttention ? "Acc — authentication needs attention" : "Acc — accounts and usage"]
        if model.preferences.showUsage {
            for provider in Provider.allCases {
                let name = provider == .codex ? "ChatGPT" : "Claude"
                guard let usage = model.activeUsage(provider) else {
                    lines.append("\(name): usage unavailable")
                    continue
                }
                let limits = usage.windows.filter { $0.id == "fiveHour" || $0.id == "weekly" }
                    .map { "\($0.title): \(Int($0.remainingPercent))% left" }.joined(separator: ", ")
                let stale = model.activeUsageIsStale(provider) ? " · stale" : ""
                lines.append("\(name) — \(limits)\(stale)")
                lines.append("Updated \(usage.fetchedAt.formatted(date: .omitted, time: .shortened))")
            }
        }
        return lines.joined(separator: "\n")
    }
}
