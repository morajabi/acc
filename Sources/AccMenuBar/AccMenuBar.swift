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
