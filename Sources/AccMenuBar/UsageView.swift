import SwiftUI
import AccCore

/// One compact line per usage window: name, meter, remaining, time to reset.
struct UsageSection: View {
    let usage: UsageSnapshot?
    let stale: Bool
    var display: UsageDisplay = .remaining

    var body: some View {
        if let usage, !usage.windows.isEmpty {
            TimelineView(.periodic(from: .now, by: 30)) { context in
                let stale = stale || usage.isStale(at: context.date)
                Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 6) {
                    ForEach(usage.orderedWindows) { UsageRow(window: $0, stale: stale, display: display, now: context.date) }
                }
                .help("Updated \(usage.fetchedAt.formatted(date: .omitted, time: .shortened))\(stale ? " · may be out of date" : "")")
            }
        } else {
            Text("Usage unavailable").font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct UsageRow: View {
    let window: UsageWindow
    let stale: Bool
    let display: UsageDisplay
    let now: Date

    var body: some View {
        let low = window.remainingPercent < 15
        GridRow {
            Text(window.shortTitle).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                .frame(minWidth: 30, idealWidth: nil, alignment: .leading)
            UsageMeter(fraction: window.percent(display) / 100,
                tint: stale ? Color.secondary : low ? Color.orange : Color.accentColor)
                .frame(minWidth: 60)
            Text(window.percentLabel(display)).monospacedDigit()
                .foregroundStyle(stale ? .secondary : low ? Color.orange : .primary)
                .gridColumnAlignment(.trailing)
            Text(resetText).monospacedDigit().foregroundStyle(.secondary)
                .gridColumnAlignment(.trailing)
        }
        .font(.caption)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(window.title)
        .accessibilityValue("\(Int(window.percent(display))) percent \(display == .remaining ? "remaining" : "used")\(stale ? ", may be out of date" : ""), \(resetDescription)")
        .help(window.resetsAt.map { "\(window.title) resets \($0.formatted(date: .abbreviated, time: .shortened))" } ?? window.title)
    }

    private var resetText: String {
        guard let reset = window.resetsAt else { return "" }
        return reset > now ? CompactDuration.format(reset.timeIntervalSince(now)) : "now"
    }
    private var resetDescription: String {
        guard let reset = window.resetsAt else { return "reset time unavailable" }
        return reset > now ? "resets in \(CompactDuration.format(reset.timeIntervalSince(now)))" : "resetting"
    }
}

private struct UsageMeter: View {
    let fraction: Double
    let tint: Color

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule().fill(tint)
                    .frame(width: fraction > 0 ? max(4, proxy.size.width * min(1, fraction)) : 0)
            }
        }.frame(height: 4)
    }
}

enum CompactDuration {
    /// "45m", "2h 51m", "1d 15h": short enough to align in a column.
    static func format(_ interval: TimeInterval) -> String {
        let minutes = max(0, Int(interval / 60))
        if minutes < 1 { return "<1m" }
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        if hours < 24 { return minutes % 60 == 0 ? "\(hours)h" : "\(hours)h \(minutes % 60)m" }
        return hours % 24 == 0 ? "\(hours / 24)d" : "\(hours / 24)d \(hours % 24)h"
    }
}

extension UsageSnapshot {
    /// Everyday limits first, then model- or product-specific limits.
    var orderedWindows: [UsageWindow] {
        let primary = [fiveHour, weekly].compactMap { $0 }
        return primary + windows.filter { $0.id != "fiveHour" && $0.id != "weekly" }
    }
}
