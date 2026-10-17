import SwiftUI
import AccCore

struct AuthenticationStatus: View {
    let account: AccountSummary
    let keepFresh: Bool
    let retryUncertain: Bool
    @State private var details = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            DisclosureGroup(isExpanded: $details) {
                AuthenticationDetails(account: account).padding(.top, 8)
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    if account.isPaused == true || !keepFresh {
                        Text("Automatic renewal paused").foregroundStyle(.secondary)
                    } else if account.renewalHealth == .uncertain {
                        Text(retryUncertain ? "Renewal uncertain · Retry enabled" : "Renewal uncertain · Sign in again")
                            .foregroundStyle(.orange)
                    } else if account.renewalHealth == .needsSignIn {
                        Text("Sign in to resume renewal").foregroundStyle(.orange)
                    } else if let next = account.nextRefreshAt {
                        if next <= context.date { Text("Renewal due · Checking automatically").foregroundStyle(.secondary) }
                        else { Text("Renews in \(next, style: .relative)").foregroundStyle(.secondary) }
                    } else { Text("Automatic renewal").foregroundStyle(.secondary) }
                    if let expiry = account.expiresAt {
                        if expiry > context.date {
                            Text("Access expires \(expiry, format: .dateTime.month(.abbreviated).day().hour().minute())")
                                .foregroundStyle(.secondary)
                        } else { Text("Access token expired").foregroundStyle(.orange) }
                    } else { Text("Access-token expiry unavailable").foregroundStyle(.secondary) }
                }.font(.caption)
            }.accessibilityLabel("Authentication details for \(account.label)")
        }
    }
}

private struct AuthenticationDetails: View {
    let account: AccountSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                DateDetail(label: "Access expires", date: account.expiresAt)
                DateDetail(label: "Last checked", date: account.lastCheckedAt)
                DateDetail(label: "Last attempt", date: account.lastRefreshAttemptAt)
                DateDetail(label: "Last renewed", date: account.lastRefreshedAt)
                DateDetail(label: "Next renewal", date: account.nextRefreshAt)
                if let retry = account.nextRenewalRetryAt { DateDetail(label: "Retry scheduled", date: retry) }
            }
            Text("The provider does not report when refresh tokens expire.")
                .font(.caption2).foregroundStyle(.secondary)
            if let history = account.refreshHistory, !history.isEmpty {
                Divider()
                Text("Recent renewals").font(.caption.weight(.medium))
                ForEach(history.suffix(5).reversed()) { event in
                    HStack(alignment: .top, spacing: 12) {
                        Text(event.date, format: .dateTime.month(.abbreviated).day().hour().minute())
                            .foregroundStyle(.secondary)
                        Text(event.message ?? "Renewed")
                    }
                }
            }
        }.font(.caption).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
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
