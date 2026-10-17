import AppKit
import Observation
import AccCore

/// Native toolbar and menu commands share the same actions and validation.
@MainActor final class AccountsToolbar: NSObject, NSToolbarDelegate, NSMenuItemValidation {
    private let model: AppModel
    let toolbar = NSToolbar(identifier: "Accounts")
    private static let refresh = NSToolbarItem.Identifier("RefreshAccounts")
    private static let add = NSToolbarItem.Identifier("AddAccount")

    init(model: AppModel) {
        self.model = model
        super.init()
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        observeState()
    }
    private func observeState() {
        withObservationTracking {
            let busy = model.busy
            let updating = model.updating
            for item in toolbar.items {
                item.isEnabled = !busy && (item.itemIdentifier != Self.refresh || !updating)
            }
        } onChange: { [weak self] in Task { @MainActor in self?.observeState() } }
    }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, Self.refresh, Self.add]
    }
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarAllowedItemIdentifiers(toolbar)
    }
    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        if identifier == Self.add {
            let item = NSMenuToolbarItem(itemIdentifier: identifier)
            item.label = "Add Account"
            item.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "Add account")
            item.toolTip = "Add an account"
            item.menu = NSMenu()
            populateAddMenu(item.menu)
            item.isEnabled = !model.busy
            return item
        }
        guard identifier == Self.refresh else { return nil }
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.label = "Refresh"
        item.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "Refresh accounts")
        item.toolTip = "Check accounts and update usage"
        item.target = self; item.action = #selector(refresh)
        item.isEnabled = !model.busy && !model.updating
        return item
    }
    private func add(_ title: String, action: Selector, key: String = "", to menu: NSMenu) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self; menu.addItem(item)
    }
    private func populateAddMenu(_ menu: NSMenu) {
        add("Sign In with Browser…", action: #selector(signIn), to: menu)
        add("Save Current Account", action: #selector(saveCurrent), to: menu)
        menu.addItem(.separator())
        add("Import from File…", action: #selector(importFile), to: menu)
    }
    func populateAccountMenu(_ menu: NSMenu) {
        add("Sign In with Browser…", action: #selector(signIn), key: "n", to: menu)
        add("Save Current Account", action: #selector(saveCurrent), to: menu)
        add("Import from File…", action: #selector(importFile), key: "o", to: menu)
        menu.addItem(.separator())
        add("Refresh Accounts", action: #selector(refresh), key: "r", to: menu)
        menu.addItem(.separator())
        add("Show ChatGPT", action: #selector(showCodex), key: "1", to: menu)
        add("Show Claude", action: #selector(showClaude), key: "2", to: menu)
    }
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(showCodex) || menuItem.action == #selector(showClaude) { return true }
        guard !model.busy else { return false }
        if menuItem.action == #selector(saveCurrent) {
            return model.selectedCurrent?.identity != nil && model.selectedCurrent?.savedAccountID == nil
        }
        return menuItem.action != #selector(refresh) || !model.updating
    }
    @objc private func signIn() { model.signIn(model.selectedProvider) }
    @objc private func saveCurrent() { model.saveCurrent(model.selectedProvider) }
    @objc private func importFile() { model.importFile(model.selectedProvider) }
    @objc private func refresh() { model.refreshAll() }
    @objc private func showCodex() { model.selectedProvider = .codex }
    @objc private func showClaude() { model.selectedProvider = .claude }
}
