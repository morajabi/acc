import Foundation
import AccCore

/// Real credential operations stay in AccCore. Preview actions change only
/// public, token-free view data in memory.
extension AppModel {
    func switchAccount(_ account: AccountSummary) {
        if isDemo {
            for i in accounts.indices where accounts[i].provider == account.provider {
                accounts[i].isActive = accounts[i].id == account.id
                if accounts[i].id == account.id { accounts[i].isPaused = false }
            }
            current.removeAll { $0.provider == account.provider }
            current.append(CurrentLogin(provider: account.provider, identity: account.identity,
                expiresAt: account.expiresAt, savedAccountID: account.id))
            notice = "Switched to \(account.label) in this preview."
            return
        }
        perform(title: "Switching account…",
                success: "Now using \(account.label). Restart an open \(account.provider.title) client to use this login.") {
            try await $0.switchAccount(account.id)
        }
    }
    func refreshUsage(_ account: AccountSummary) {
        if isDemo {
            if let i = accounts.firstIndex(where: { $0.id == account.id }) { accounts[i].usage?.fetchedAt = Date() }
            return
        }
        perform(title: "Updating usage…") { try await $0.refresh(account.id, includeUsage: true) }
    }
    func renewAccount(_ account: AccountSummary) {
        if isDemo { notice = "Preview mode. No authentication was changed."; return }
        perform(title: "Renewing authentication…", success: "Authentication renewed for \(account.label).") {
            try await $0.refresh(account.id, force: true, includeUsage: false)
        }
    }
    func renameAccount(_ account: AccountSummary, name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        if isDemo {
            if let i = accounts.firstIndex(where: { $0.id == account.id }) { accounts[i].label = name }
            notice = nil
            return
        }
        perform(title: "Renaming account…") { try await $0.rename(account.id, label: name) }
    }
    func setPaused(_ account: AccountSummary, _ paused: Bool) {
        if isDemo {
            if let i = accounts.firstIndex(where: { $0.id == account.id }) { accounts[i].isPaused = paused }
            notice = nil
            return
        }
        perform(title: paused ? "Detaching account…" : "Resuming management…",
                success: paused ? "Acc stopped managing \(account.label). Your provider login is unchanged." : nil) {
            try await $0.setPaused(account.id, paused)
        }
    }
    func removeAccount(_ account: AccountSummary) {
        if isDemo {
            accounts.removeAll { $0.id == account.id }
            if let i = current.firstIndex(where: { $0.savedAccountID == account.id }) { current[i].savedAccountID = nil }
            notice = "Removed \(account.label) from this preview."
            return
        }
        perform(title: "Removing account…", success: "Removed \(account.label) from Acc.") {
            try await $0.remove(account.id)
        }
    }
    func signOut(_ provider: Provider) {
        if isDemo {
            for i in accounts.indices where accounts[i].provider == provider { accounts[i].isActive = false }
            current.removeAll { $0.provider == provider }
            return
        }
        perform(title: "Signing out…", success: "Signed out of \(provider.title) locally. Your saved account is still in Acc.") {
            try await $0.signOut(provider)
        }
    }
    func saveCurrent(_ provider: Provider) {
        if isDemo {
            guard let login = current.first(where: { $0.provider == provider }), let identity = login.identity else { return }
            let record = AccountSummary(id: UUID(), provider: provider, label: identity.email ?? "Preview",
                identity: identity, expiresAt: login.expiresAt, isActive: true, usage: observedUsage[provider])
            accounts.append(record)
            if let i = current.firstIndex(where: { $0.provider == provider }) { current[i].savedAccountID = record.id }
            return
        }
        perform(title: "Saving account…", success: "Account saved. Acc will keep its authentication fresh.") {
            _ = try await $0.importCurrent(provider)
        }
    }
    func authorizeKeychain(_ provider: Provider) {
        if isDemo { notice = "Preview mode does not access Keychain."; return }
        perform(title: "Waiting for Keychain access…") { try await $0.authorizeKeychain(provider) }
    }
    func resetDemo() {
        guard isDemo else { return }
        accounts = DemoAccounts.make()
        current = accounts.filter(\.isActive).map {
            CurrentLogin(provider: $0.provider, identity: $0.identity, expiresAt: $0.expiresAt, savedAccountID: $0.id)
        }
        pending = []; notice = nil; message = nil
    }
}
