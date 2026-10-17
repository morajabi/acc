import AppKit
import SwiftUI
import Observation

/// System popover chrome supplies the menu-bar material and dismissal behavior.
/// A separate standard window supports longer account-management sessions.
@MainActor final class AccAppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    let model: AppModel
    private var windowMode: Bool { model.presentation == .window }
    private var accountsToolbar: AccountsToolbar?
    private var statusItem: NSStatusItem?
    private let popover = NSPopover()
    private var accountsWindow: NSWindow?

    override init() {
        model = AppModel()
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        model.configureLoginAtStartup()
        accountsToolbar = AccountsToolbar(model: model)
        popover.behavior = .transient
        popover.delegate = self
        model.openAccounts = { [weak self] in self?.showAccounts() }
        model.resizePanel = { [weak self] height in self?.resizePanel(to: height) }
        model.changePresentation = { [weak self] in self?.applyPresentation() }
        applyPresentation()
        if !windowMode && CommandLine.arguments.contains("--show-panel") {
            // Status-item geometry is available after the launch callback returns.
            DispatchQueue.main.async { [weak self] in self?.showPanel() }
        }
    }
    private func applyPresentation() {
        if windowMode {
            hidePanel()
            if let statusItem { NSStatusBar.system.removeStatusItem(statusItem); self.statusItem = nil }
            NSApp.setActivationPolicy(.regular)
            showAccounts()
        } else {
            NSApp.setActivationPolicy(.accessory)
            if statusItem == nil {
                let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
                statusItem = item
                item.button?.target = self
                item.button?.action = #selector(togglePanel)
                updateIcon()
            }
            accountsWindow?.orderOut(nil)
        }
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            if windowMode { showAccounts() }
            else { showPanel() }
        }
        return true
    }
    private func updateIcon() {
        guard statusItem != nil else { return }
        withObservationTracking {
            statusItem?.button?.image = StatusIcon.make(model: model)
            statusItem?.button?.toolTip = StatusIcon.tooltip(model: model)
        } onChange: { [weak self] in
            Task { @MainActor in self?.updateIcon() }
        }
    }
    @objc private func togglePanel() {
        if popover.isShown { hidePanel() }
        else { showPanel() }
    }
    private func showPanel() {
        guard !popover.isShown, let button = statusItem?.button else { return }
        let availableHeight = (button.window?.screen ?? NSScreen.main)?.visibleFrame.height ?? 800
        let savedHeight = model.isDemo ? 0 : UserDefaults.standard.double(forKey: "panelHeight")
        let height = min(max(320, savedHeight.nonzero ?? 430), availableHeight - 48)
        if popover.contentViewController == nil {
            let controller = NSHostingController(rootView: AccountPanel(model: model, compact: true))
            // The system popover owns the background and sizing, not an opaque
            // SwiftUI container or the hosting view's ideal content size.
            controller.sizingOptions = []
            popover.contentViewController = controller
        }
        popover.contentSize = NSSize(width: 380, height: height)
        model.panelHeight = height
        // A status-item click or application reopen doesn't necessarily make an
        // accessory app active. Activate before showing the popover so native
        // controls draw their active state and keyboard/drag focus stays here.
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
        model.updateLoginStatus()
        model.refreshWhenPresented()
    }
    private func hidePanel() { popover.performClose(nil) }
    private func resizePanel(to proposedHeight: CGFloat) {
        guard popover.isShown else { return }
        let availableHeight = (statusItem?.button?.window?.screen ?? NSScreen.main)?.visibleFrame.height ?? 800
        let height = min(max(320, proposedHeight), availableHeight - 48)
        popover.contentSize.height = height
        model.panelHeight = height
        if !model.isDemo { UserDefaults.standard.set(height, forKey: "panelHeight") }
    }
    func popoverShouldDetach(_ popover: NSPopover) -> Bool { false }
    @objc func showAccounts() {
        hidePanel()
        if accountsWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 560),
                styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.title = model.isDemo ? "Accounts Preview" : "Accounts"
            window.contentView = NSHostingView(rootView: AccountPanel(model: model, compact: false))
            window.toolbar = accountsToolbar?.toolbar
            window.toolbarStyle = .unified
            window.minSize = NSSize(width: 380, height: 360)
            window.setFrameAutosaveName(model.isDemo ? "AccDemoAccounts" : "AccAccounts")
            window.isReleasedWhenClosed = false
            window.center(); accountsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        accountsWindow?.makeKeyAndOrderFront(nil)
        model.refreshWhenPresented()
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard model.busy || model.updating else { return .terminateNow }
        model.isQuitting = true
        model.cancelSignIn()
        Task {
            // Finish saving any rotation before an ordinary Quit or logout.
            while model.busy || model.updating { try? await Task.sleep(for: .milliseconds(100)) }
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

private extension Double { var nonzero: Double? { self == 0 ? nil : self } }
