import SwiftUI
import AccCore

struct UsageSection: View {
    let usage: UsageSnapshot?
    let stale: Bool
    let expanded: Bool
    @State private var showExtra = false

    var body: some View {
        if let usage, !usage.windows.isEmpty {
            TimelineView(.periodic(from: .now, by: 30)) { context in
                VStack(alignment: .leading, spacing: 8) {
                ForEach(usage.windows.filter { $0.id == "fiveHour" || $0.id == "weekly" }) { window in
                    UsageRow(window: window, stale: stale || usage.isStale(at: context.date), showReset: expanded)
                }
                if usage.windows.contains(where: { $0.id != "fiveHour" && $0.id != "weekly" }) {
                    DisclosureGroup("More usage limits", isExpanded: $showExtra) {
                        VStack(spacing: 10) {
                            ForEach(usage.windows.filter { $0.id != "fiveHour" && $0.id != "weekly" }) {
                                UsageRow(window: $0, stale: stale || usage.isStale(at: context.date), showReset: true)
                            }
                        }.padding(.top, 8)
                    }.font(.caption)
                }
                }.help("Updated \(usage.fetchedAt.formatted(date: .abbreviated, time: .shortened))")
            }
        } else { Text("Usage unavailable").font(.caption).foregroundStyle(.secondary) }
    }
}

struct UsageRow: View {
    let window: UsageWindow
    let stale: Bool
    var showReset = true

    var body: some View {
        VStack(spacing: 4) {
            HStack {
                HStack(spacing: 4) {
                    Text(window.title)
                    if showReset, let reset = window.resetsAt {
                        if reset > Date() { Text("· \(reset, style: .relative)").foregroundStyle(.secondary) }
                        else { Text("· resetting").foregroundStyle(.secondary) }
                    }
                }.lineLimit(1)
                Spacer(minLength: 4)
                Text("\(Int(window.remainingPercent))% left\(stale ? " · stale" : "")").monospacedDigit()
            }.font(.caption).foregroundStyle(stale ? .secondary : .primary)
            ProgressView(value: window.remainingPercent, total: 100)
                .tint(window.remainingPercent < 15 ? .orange : .accentColor)
                .accessibilityLabel(window.title)
                .accessibilityValue("\(Int(window.remainingPercent)) percent remaining\(stale ? ", stale" : "")")
        }.help(window.resetsAt.map { "Resets \($0.formatted(date: .abbreviated, time: .shortened))" } ?? window.title)
    }
}
