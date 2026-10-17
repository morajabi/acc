import SwiftUI
import AccCore

struct AccountRow: View {
    let account: AccountSummary
    let model: AppModel
    @State private var retryingRenewal = false
    @State private var renaming = false
    @State private var removing = false
    @State private var signingOut = false
    @State private var name = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(account.label).font(.headline).lineLimit(1).help(account.label)
                    Text(account.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    if account.isActive {
                        Label("Active", systemImage: "checkmark.circle.fill")
                            .font(.caption.weight(.medium)).foregroundStyle(.green)
                    }
                }
                Spacer(minLength: 0)
                if !account.isActive {
                    Button("Switch") { model.switchAccount(account) }
                        .disabled(model.busy).help("Use this account in \(account.provider.title)")
                }
                Menu {
                    Button("Refresh Usage") { model.refreshUsage(account) }
                    Button("Renew Now") {
                        if account.renewalHealth == .uncertain { retryingRenewal = true }
                        else { model.renewAccount(account) }
                    }
                    Divider()
                    Button("Sign In Again…") { model.signIn(account.provider, replacing: account.id) }
                    Button("Replace from File…") { model.importFile(account.provider, replacing: account.id) }
                    Button("Rename…") { name = account.label; renaming = true }
                    Divider()
                    Button(account.isPaused == true ? "Resume Management" : "Detach from Acc") {
                        model.setPaused(account, account.isPaused != true)
                    }
                    if account.isActive { Button("Sign Out Locally…") { signingOut = true } }
                    Button("Remove from Acc…", role: .destructive) { removing = true }
                } label: { Image(systemName: "ellipsis") }
                .menuStyle(.borderlessButton).fixedSize().disabled(model.busy)
                    .accessibilityLabel("Actions for \(account.label)")
            }
            if model.preferences.showUsage {
                UsageSection(usage: account.usage, stale: account.message != nil || account.isPaused == true, expanded: account.isActive)
            }
            Divider()
            AuthenticationStatus(account: account, keepFresh: model.preferences.keepFresh,
                retryUncertain: model.preferences.retryUncertainRefresh)
            if account.isPaused == true {
                HStack {
                    Text("Detached · Automatic updates paused").font(.caption).foregroundStyle(.secondary)
                    Spacer(minLength: 4)
                    Button("Resume") { model.setPaused(account, false) }.controlSize(.small).disabled(model.busy)
                }
            } else if let message = account.message {
                VStack(alignment: .leading, spacing: 8) {
                    Text(message).font(.caption).foregroundStyle(.orange).textSelection(.enabled)
                    if account.health == .needsSignIn || account.renewalHealth == .uncertain {
                        Button("Sign In Again…") { model.signIn(account.provider, replacing: account.id) }.disabled(model.busy)
                    }
                }
            }
        }.accountCard()
            .alert("Retry an uncertain renewal?", isPresented: $retryingRenewal) {
                Button("Retry Renewal") { model.renewAccount(account) }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("The previous request may have consumed this refresh token. An old file cannot restore it. Signing in again creates a new session.")
            }
            .alert("Rename account", isPresented: $renaming) {
                TextField("Account name", text: $name)
                Button("Save") { model.renameAccount(account, name: name) }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("Cancel", role: .cancel) {}
            }
            .alert("Remove \(account.label) from Acc?", isPresented: $removing) {
                Button("Remove", role: .destructive) { model.removeAccount(account) }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Acc will stop managing this account and delete its saved login. Your active \(account.provider.title) login stays signed in.")
            }
            .alert("Sign out of \(account.provider.title)?", isPresented: $signingOut) {
                Button("Sign Out", role: .destructive) { model.signOut(account.provider) }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This clears the local provider login. The saved account stays in Acc so you can switch back later.")
            }
    }
}

extension AccountSummary {
    var subtitle: String {
        [Self.planTitle(usage?.plan ?? identity.plan), identity.email == label ? nil : identity.email]
            .compactMap { $0 }.joined(separator: " · ")
    }
    static func planTitle(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        switch value.lowercased() {
        case "prolite": return "Pro Lite"
        case "plus": return "Plus"
        case "pro": return "Pro"
        case "max": return "Max"
        case "team": return "Team"
        case "business": return "Business"
        case "enterprise": return "Enterprise"
        case "free": return "Free"
        default: return value
        }
    }
}
