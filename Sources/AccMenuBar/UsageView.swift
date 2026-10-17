import SwiftUI
import AccCore

struct UsageSection: View {
    let usage: UsageSnapshot?
    let stale: Bool
    let expanded: Bool
    @State private var showExtra = false

    var body: some View {
        if let usage, !usage.windows.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(usage.windows.filter { $0.id == "fiveHour" || $0.id == "weekly" }) { window in
                    UsageRow(window: window, stale: stale || usage.isStale(), showReset: expanded)
                }
                if usage.windows.contains(where: { $0.id != "fiveHour" && $0.id != "weekly" }) {
                    DisclosureGroup("More usage limits", isExpanded: $showExtra) {
                        VStack(spacing: 10) {
                            ForEach(usage.windows.filter { $0.id != "fiveHour" && $0.id != "weekly" }) {
                                UsageRow(window: $0, stale: stale || usage.isStale(), showReset: true)
                            }
                        }.padding(.top, 8)
                    }.font(.caption)
                }
            }.help("Updated \(usage.fetchedAt.formatted(date: .abbreviated, time: .shortened))")
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
                Text(window.title)
                Spacer()
                Text("\(Int(window.remainingPercent))% left\(stale ? " · stale" : "")").monospacedDigit()
            }.font(.caption).foregroundStyle(stale ? .secondary : .primary)
            ProgressView(value: window.remainingPercent, total: 100)
                .tint(window.remainingPercent < 15 ? .orange : .accentColor)
                .accessibilityLabel(window.title)
                .accessibilityValue("\(Int(window.remainingPercent)) percent remaining\(stale ? ", stale" : "")")
            if showReset, let reset = window.resetsAt {
                HStack {
                    if reset > Date() { Text("Resets in \(reset, style: .relative)") }
                    else { Text("Waiting for usage reset") }
                    Spacer()
                }.font(.caption2).foregroundStyle(.secondary)
            }
        }.help(window.resetsAt.map { "Resets \($0.formatted(date: .abbreviated, time: .shortened))" } ?? window.title)
    }
}
