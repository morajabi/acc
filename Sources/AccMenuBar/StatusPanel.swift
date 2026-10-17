import AppKit
import SwiftUI
import Observation

/// A single hosting surface avoids MenuBarExtra's competing intrinsic sizes.
/// Native resizing and the visible bottom handle both preserve the panel's height.
@MainActor final class AccAppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let model: AppModel
    private var windowMode: Bool { model.presentation == .window }
    private var accountsToolbar: AccountsToolbar?
    private var statusItem: NSStatusItem?
    private var panel: AccountWindow?
    private var accountsWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private var outsideClick: Any?
    private var localClick: Any?

    init(model: AppModel) {
        self.model = model
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        model.configureLoginAtStartup()
        installMenu()
        model.openAccounts = { [weak self] in self?.showAccounts() }
        model.openSettings = { [weak self] in self?.showSettings() }
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
    private func installMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem(); main.addItem(appItem)
        let menu = NSMenu(title: "Acc"); appItem.submenu = menu
        menu.addItem(withTitle: "About Acc", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        let accounts = NSMenuItem(title: "Accounts", action: #selector(showAccounts), keyEquivalent: "a")
        accounts.keyEquivalentModifierMask = [.command, .shift]; accounts.target = self; menu.addItem(accounts)
        let settings = NSMenuItem(title: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        settings.target = self; menu.addItem(settings)
        let servicesItem = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
        let services = NSMenu(title: "Services"); servicesItem.submenu = services; menu.addItem(servicesItem)
        NSApp.servicesMenu = services
        menu.addItem(.separator())
        menu.addItem(withTitle: "Hide Acc", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = menu.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        menu.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Acc", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let accountItem = NSMenuItem(title: "Account", action: nil, keyEquivalent: ""); main.addItem(accountItem)
        let accountMenu = NSMenu(title: "Account"); accountItem.submenu = accountMenu
        let commands = AccountsToolbar(model: model)
        accountsToolbar = commands
        commands.populateAccountMenu(accountMenu)
        let editItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: ""); main.addItem(editItem)
        let edit = NSMenu(title: "Edit"); editItem.submenu = edit
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let windowItem = NSMenuItem(title: "Window", action: nil, keyEquivalent: ""); main.addItem(windowItem)
        let window = NSMenu(title: "Window"); windowItem.submenu = window
        window.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        window.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        window.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        NSApp.windowsMenu = window
        let helpItem = NSMenuItem(title: "Help", action: nil, keyEquivalent: ""); main.addItem(helpItem)
        let help = NSMenu(title: "Help"); helpItem.submenu = help
        let source = NSMenuItem(title: "Acc on GitHub", action: #selector(openSource), keyEquivalent: "")
        source.target = self; help.addItem(source)
        if model.isDemo {
            let reset = NSMenuItem(title: "Reset Preview Accounts", action: #selector(resetPreview), keyEquivalent: "")
            reset.target = self; help.addItem(reset)
        }
        NSApp.helpMenu = help
        NSApp.mainMenu = main
    }
    @objc private func openSource() { NSWorkspace.shared.open(URL(string: "https://github.com/morajabi/acc")!) }
    @objc private func resetPreview() { model.resetDemo() }
    private func updateIcon() {
        guard statusItem != nil else { return }
        withObservationTracking {
            statusItem?.button?.image = StatusIcon.make(model: model)
            statusItem?.button?.toolTip = model.needsAttention ? "Acc — authentication needs attention" : "Acc — accounts and authentication"
        } onChange: { [weak self] in
            Task { @MainActor in self?.updateIcon() }
        }
    }
    @objc private func togglePanel() {
        if panel?.isVisible == true { hidePanel(); return }
        showPanel()
    }
    private func showPanel() {
        if panel?.isVisible == true { panel?.makeKeyAndOrderFront(nil); return }
        hidePanel() // also releases monitors after an Escape dismissal
        guard let button = statusItem?.button, let buttonWindow = button.window else { return }
        let screen = buttonWindow.screen ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1200, height: 800)
        let height = min(max(360, UserDefaults.standard.double(forKey: "panelHeight").nonzero ?? 580), visible.height - 12)
        if panel == nil {
            let window = AccountWindow(contentRect: NSRect(x: 0, y: 0, width: 410, height: height),
                styleMask: [.borderless, .resizable, .nonactivatingPanel], backing: .buffered, defer: false)
            window.title = "Acc Accounts"
            window.contentView = NSHostingView(rootView: AccountPanel(model: model, compact: true).clipShape(RoundedRectangle(cornerRadius: 12)))
            window.backgroundColor = .clear
            window.isOpaque = false; window.hasShadow = true
            window.level = .popUpMenu
            window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
            window.minSize = NSSize(width: 390, height: 360)
            window.maxSize = NSSize(width: 520, height: visible.height - 12)
            window.delegate = self
            window.isReleasedWhenClosed = false
            panel = window
        }
        let buttonRect = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let width = panel!.frame.width
        let x = min(max(buttonRect.midX - width / 2, visible.minX + 6), visible.maxX - width - 6)
        panel?.setFrame(NSRect(x: x, y: visible.maxY - height - 6, width: width, height: height), display: true)
        model.panelHeight = height
        panel?.makeKeyAndOrderFront(nil)
        model.updateLoginStatus()
        outsideClick = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in self?.hidePanel() }
        }
        localClick = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            MainActor.assumeIsolated {
                if let self, let window = event.window,
                   window === self.accountsWindow || window === self.settingsWindow { self.hidePanel() }
            }
            return event
        }
    }
    private func hidePanel() {
        panel?.orderOut(nil)
        if let outsideClick { NSEvent.removeMonitor(outsideClick); self.outsideClick = nil }
        if let localClick { NSEvent.removeMonitor(localClick); self.localClick = nil }
    }
    private func resizePanel(to height: CGFloat) {
        guard let panel else { return }
        let visible = panel.screen?.visibleFrame ?? NSScreen.main!.visibleFrame
        let height = min(max(360, height), min(panel.maxSize.height, panel.frame.maxY - visible.minY - 6))
        var frame = panel.frame
        frame.origin.y = frame.maxY - height; frame.size.height = height
        panel.setFrame(frame, display: true)
    }
    func windowDidResize(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === panel else { return }
        model.panelHeight = window.frame.height
        if !model.isDemo { UserDefaults.standard.set(window.frame.height, forKey: "panelHeight") }
    }
    @objc private func showAccounts() {
        hidePanel()
        if accountsWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 650),
                styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.title = model.isDemo ? "Accounts Preview" : "Accounts"
            window.contentView = NSHostingView(rootView: AccountPanel(model: model, compact: false))
            window.toolbar = accountsToolbar?.toolbar
            window.toolbarStyle = .unified
            window.minSize = NSSize(width: 440, height: 400)
            window.setFrameAutosaveName(model.isDemo ? "AccDemoAccounts" : "AccAccounts")
            window.isReleasedWhenClosed = false
            window.center(); accountsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        accountsWindow?.makeKeyAndOrderFront(nil)
    }
    @objc private func showSettings() {
        hidePanel()
        if settingsWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 540),
                styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "Settings"
            window.contentView = NSHostingView(rootView: AccSettings(model: model))
            window.isReleasedWhenClosed = false
            window.center(); settingsWindow = window
        }
        model.updateLoginStatus()
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
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

private final class AccountWindow: NSPanel {
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { orderOut(nil) }
}
private extension Double { var nonzero: Double? { self == 0 ? nil : self } }
