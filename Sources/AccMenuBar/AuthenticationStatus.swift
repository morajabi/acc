import SwiftUI
import AccCore

/// What the operator needs to act on. Healthy accounts have no issue; their
/// renewal time appears quietly in the account subtitle instead.
struct AccountIssue {
    enum Action { case signIn, resume, renew }
    let text: String
    let warning: Bool
    let action: Action?

    static func of(_ account: AccountSummary, keepFresh: Bool, retryUncertain: Bool, now: Date) -> AccountIssue? {
        if account.isPaused == true {
            return AccountIssue(text: "Detached. Acc isn’t renewing this account.", warning: false, action: .resume)
        }
        if account.renewalHealth == .uncertain || account.health == .uncertain {
            return AccountIssue(text: retryUncertain ? "Renewal outcome unknown. Acc will retry."
                : "Renewal outcome unknown. Sign in again to be safe.", warning: true, action: .signIn)
        }
        if account.renewalHealth == .needsSignIn || account.health == .needsSignIn {
            return AccountIssue(text: account.message ?? "Sign in again to keep this account fresh.", warning: true, action: .signIn)
        }
        if let expiry = account.expiresAt, expiry <= now {
            return AccountIssue(text: "Access token expired.", warning: true, action: .renew)
        }
        if let message = account.message {
            return AccountIssue(text: message, warning: true, action: nil)
        }
        return nil
    }
}

extension AccountSummary {
    /// "renews in 3h 17m" for a healthy, managed account.
    func renewalText(keepFresh: Bool, now: Date) -> String? {
        guard isPaused != true else { return nil }
        guard keepFresh else { return "renewal off" }
        guard let next = nextRefreshAt else { return nil }
        return next <= now ? "renewing…" : "renews in \(CompactDuration.format(next.timeIntervalSince(now)))"
    }
}

/// Full renewal record, shown on request from the account menu.
struct AuthenticationDetails: View {
    let account: AccountSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(account.label).font(.headline)
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                DateDetail(label: "Access expires", date: account.expiresAt)
                DateDetail(label: "Next renewal", date: account.nextRefreshAt)
                if let retry = account.nextRenewalRetryAt { DateDetail(label: "Retry scheduled", date: retry) }
                DateDetail(label: "Last renewed", date: account.lastRefreshedAt)
                DateDetail(label: "Last attempt", date: account.lastRefreshAttemptAt)
                DateDetail(label: "Last checked", date: account.lastCheckedAt)
                if let usage = account.usage { DateDetail(label: "Usage updated", date: usage.fetchedAt) }
            }
            if let message = account.usageMessage {
                Text(message).foregroundStyle(.secondary)
            }
            if let history = account.refreshHistory, !history.isEmpty {
                Divider()
                Text("Recent renewals").font(.caption.weight(.semibold))
                ForEach(history.suffix(5).reversed()) { event in
                    HStack(alignment: .top, spacing: 12) {
                        Text(event.date, format: .dateTime.month(.abbreviated).day().hour().minute())
                            .foregroundStyle(.secondary)
                        Text(event.message ?? "Renewed")
                    }
                }
            }
            Text("Providers don’t report when refresh tokens expire.")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .font(.caption).textSelection(.enabled)
        .padding(14).frame(width: 300, alignment: .leading)
    }
}

private struct DateDetail: View {
    let label: String
    let date: Date?

    var body: some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            if let date { Text(date, format: .dateTime.month(.abbreviated).day().hour().minute()) }
            else { Text("Not recorded").foregroundStyle(.tertiary) }
        }
    }
}
