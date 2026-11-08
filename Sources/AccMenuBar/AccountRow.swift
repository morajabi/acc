import SwiftUI
import AccCore

struct AccountRow: View {
    let account: AccountSummary
    let model: AppModel
    @State private var retryingRenewal = false
    @State private var renaming = false
    @State private var removing = false
    @State private var signingOut = false
    @State private var details = false
    @State private var name = ""

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .center, spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(account.label).font(.headline).lineLimit(1).truncationMode(.middle).help(account.label)
                        subtitle(now: context.date)
                    }
                    Spacer(minLength: 4)
                    if !account.isActive {
                        Button("Switch") { model.switchAccount(account) }
                            .controlSize(.small).disabled(model.busy)
                            .help("Use this account in \(account.provider.displayName)")
                    }
                    actions
                }
                if model.preferences.showUsage {
                    UsageSection(usage: account.usage, stale: account.usageMessage != nil || account.isPaused == true,
                                 display: model.usageDisplay)
                }
                if let issue = AccountIssue.of(account, keepFresh: model.preferences.keepFresh,
                                               retryUncertain: model.preferences.retryUncertainRefresh, now: context.date) {
                    IssueLine(issue: issue) { perform(issue.action) }.disabled(model.busy)
                }
            }
        }
        .accountCard()
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
            Text("Acc will stop managing this account and delete its saved login. Your active \(account.provider.displayName) login stays signed in.")
        }
        .alert("Sign out of \(account.provider.displayName)?", isPresented: $signingOut) {
            Button("Sign Out", role: .destructive) { model.signOut(account.provider) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This clears the local provider login. The saved account stays in Acc so you can switch back later.")
        }
    }

    /// "Max · ● Active · renews in 3h 17m"
    private func subtitle(now: Date) -> some View {
        HStack(spacing: 4) {
            let parts = [AccountSummary.planTitle(account.usage?.plan ?? account.identity.plan),
                         account.identity.email == account.label ? nil : account.identity.email].compactMap { $0 }
            if !parts.isEmpty { Text(parts.joined(separator: " · ")).lineLimit(1).truncationMode(.middle) }
            if account.isActive {
                if !parts.isEmpty { Text("·") }
                Circle().fill(.green).frame(width: 6, height: 6).accessibilityHidden(true)
                Text("Active")
            }
            if let renewal = account.renewalText(keepFresh: model.preferences.keepFresh, now: now),
               AccountIssue.of(account, keepFresh: model.preferences.keepFresh,
                               retryUncertain: model.preferences.retryUncertainRefresh, now: now) == nil {
                Text("· \(renewal)").lineLimit(1)
            }
        }
        .font(.caption).foregroundStyle(.secondary)
        .help(account.expiresAt.map { "Access expires \($0.formatted(date: .abbreviated, time: .shortened))" } ?? "")
    }

    private var actions: some View {
        Menu {
            Button("Refresh Usage") { model.refreshUsage(account) }
            Button("Renew Now") { perform(.renew) }
            Button("Details…") { details = true }
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
        } label: { Image(systemName: "ellipsis.circle") }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .disabled(model.busy).help("Account actions")
        .accessibilityLabel("Actions for \(account.label)")
        .popover(isPresented: $details, arrowEdge: .trailing) { AuthenticationDetails(account: account) }
    }

    private func perform(_ action: AccountIssue.Action?) {
        switch action {
        case .signIn: model.signIn(account.provider, replacing: account.id)
        case .resume: model.setPaused(account, false)
        case .renew:
            if account.renewalHealth == .uncertain { retryingRenewal = true } else { model.renewAccount(account) }
        case nil: break
        }
    }
}

private struct IssueLine: View {
    let issue: AccountIssue
    let act: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: issue.warning ? "exclamationmark.triangle.fill" : "pause.circle")
                .foregroundStyle(issue.warning ? Color.orange : Color.secondary)
            Text(issue.text).foregroundStyle(issue.warning ? .primary : .secondary)
                .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            Spacer(minLength: 4)
            if let action = issue.action {
                Button(action == .signIn ? "Sign In…" : action == .resume ? "Resume" : "Renew", action: act)
                    .controlSize(.small)
            }
        }.font(.caption)
    }
}

extension AccountSummary {
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
