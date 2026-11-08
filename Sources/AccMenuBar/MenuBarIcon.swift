import AppKit
import AccCore

/// How the status item summarizes the active accounts.
enum MenuBarStyle: String, CaseIterable, Identifiable {
    case bars, percent, logos, symbol
    var id: String { rawValue }
    var title: String {
        switch self {
        case .bars: "Logos and usage bars"
        case .percent: "Logos and remaining percent"
        case .logos: "Logos only"
        case .symbol: "Single symbol"
        }
    }
    var showsUsage: Bool { self == .bars || self == .percent }
}

extension UsageSnapshot {
    /// The windows that limit everyday use, shortest first. Providers omit
    /// windows that do not apply to a plan, so a missing window is not 0%.
    var primaryWindows: [UsageWindow] {
        let primary = [fiveHour, weekly].compactMap { $0 }
        if !primary.isEmpty { return primary }
        return windows.min(by: { $0.remainingPercent < $1.remainingPercent }).map { [$0] } ?? []
    }
    /// The tightest remaining allowance among the primary windows.
    var limitingWindow: UsageWindow? { primaryWindows.min { $0.remainingPercent < $1.remainingPercent } }
}

/// Template artwork for the status item. Everything draws in black with alpha
/// so macOS tints it for the menu bar's appearance and highlight state.
@MainActor enum StatusIcon {
    struct Cell {
        let provider: Provider
        let windows: [UsageWindow]
        let stale: Bool
    }
    private static let height: CGFloat = 18
    private static let mark: CGFloat = 16
    private static let barWidth: CGFloat = 14
    private static let barHeight: CGFloat = 3
    private static let gap: CGFloat = 6
    private static let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)

    static func make(model: AppModel) -> NSImage {
        let providers = Provider.allCases.filter { model.menuBarProviders.contains($0) }
        var style = model.menuBarStyle
        if providers.isEmpty { style = .symbol }
        if style.showsUsage && !model.preferences.showUsage { style = .logos }
        let cells = providers.map { provider in
            Cell(provider: provider, windows: model.activeUsage(provider)?.primaryWindows ?? [],
                 stale: model.activeUsageIsStale(provider))
        }
        return make(cells: cells, style: style, attention: model.needsAttention)
    }

    static func make(cells: [Cell], style: MenuBarStyle, attention: Bool) -> NSImage {
        if style == .symbol { return symbol(attention: attention) }
        let widths = cells.map { width(of: $0, style: style) }
        let dot: CGFloat = attention ? 6 : 0
        let total = widths.reduce(0, +) + gap * CGFloat(max(0, cells.count - 1)) + dot
        let image = NSImage(size: NSSize(width: max(total, 1), height: height), flipped: true) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            var x: CGFloat = 0
            for (cell, width) in zip(cells, widths) {
                draw(cell, style: style, at: x, in: context)
                x += width + gap
            }
            if attention {
                context.setFillColor(NSColor.black.cgColor)
                context.fillEllipse(in: CGRect(x: total - 4, y: 1, width: 4, height: 4))
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Acc"
        return image
    }

    private static func width(of cell: Cell, style: MenuBarStyle) -> CGFloat {
        switch style {
        case .bars: cell.windows.isEmpty ? mark : mark + 3 + barWidth
        case .percent: mark + 2 + ceil(percentText(cell).size(withAttributes: [.font: font]).width)
        default: mark
        }
    }

    private static func percentText(_ cell: Cell) -> String {
        cell.windows.min(by: { $0.remainingPercent < $1.remainingPercent })
            .map { "\(Int($0.remainingPercent.rounded(.down)))%" } ?? "–"
    }

    private static func draw(_ cell: Cell, style: MenuBarStyle, at x: CGFloat, in context: CGContext) {
        let path = ProviderMark(provider: cell.provider).path(in: CGRect(x: x, y: 1, width: mark, height: mark))
        context.setFillColor(NSColor.black.cgColor)
        context.addPath(path.cgPath); context.fillPath()
        let ink = NSColor.black.withAlphaComponent(cell.stale ? 0.45 : 1)
        switch style {
        case .bars:
            // One bar sits on the centerline; two straddle it.
            let windows = Array(cell.windows.prefix(2))
            let spacing: CGFloat = 2
            let stack = CGFloat(windows.count) * barHeight + CGFloat(max(0, windows.count - 1)) * spacing
            var y = (height - stack) / 2
            for window in windows {
                let track = CGRect(x: x + mark + 3, y: y, width: barWidth, height: barHeight)
                context.setFillColor(NSColor.black.withAlphaComponent(0.25).cgColor)
                context.addPath(CGPath(roundedRect: track, cornerWidth: 1.5, cornerHeight: 1.5, transform: nil)); context.fillPath()
                let fraction = max(0, min(1, window.remainingPercent / 100))
                if fraction > 0 {
                    let fill = CGRect(x: track.minX, y: track.minY, width: max(barHeight, track.width * fraction), height: barHeight)
                    context.setFillColor(ink.cgColor)
                    context.addPath(CGPath(roundedRect: fill, cornerWidth: 1.5, cornerHeight: 1.5, transform: nil)); context.fillPath()
                }
                y += barHeight + spacing
            }
        case .percent:
            let text = percentText(cell) as NSString
            let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: ink]
            let size = text.size(withAttributes: attributes)
            text.draw(at: NSPoint(x: x + mark + 2, y: (height - size.height) / 2), withAttributes: attributes)
        default: break
        }
    }

    private static func symbol(attention: Bool) -> NSImage {
        let configuration = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
        let glyph = NSImage(systemSymbolName: "person.2.fill", accessibilityDescription: "Acc")?
            .withSymbolConfiguration(configuration)
        let size = glyph?.size ?? NSSize(width: 18, height: 12)
        let width = size.width + (attention ? 6 : 0)
        let image = NSImage(size: NSSize(width: width, height: height), flipped: true) { _ in
            glyph?.draw(in: NSRect(x: 0, y: (height - size.height) / 2, width: size.width, height: size.height))
            if attention {
                NSColor.black.setFill()
                NSBezierPath(ovalIn: NSRect(x: width - 4, y: 1, width: 4, height: 4)).fill()
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Acc"
        return image
    }

    static func tooltip(model: AppModel) -> String {
        var lines = [model.needsAttention ? "Acc — needs attention" : "Acc"]
        guard model.preferences.showUsage else { return lines.joined() }
        for provider in Provider.allCases {
            let name = provider.displayName
            guard let usage = model.activeUsage(provider), !usage.windows.isEmpty else {
                lines.append("\(name): usage unavailable")
                continue
            }
            let limits = usage.primaryWindows.map { "\($0.shortTitle) \(Int($0.remainingPercent))% left" }
                .joined(separator: " · ")
            lines.append("\(name): \(limits)\(model.activeUsageIsStale(provider) ? " (stale)" : "")")
        }
        return lines.joined(separator: "\n")
    }
}

extension Provider {
    /// Product names people recognize; `title` remains the CLI's name.
    var displayName: String { self == .codex ? "ChatGPT" : "Claude" }
}

extension UsageWindow {
    /// "5h", "Week", "Fable": the provider's own name without the window length
    /// when the length is the usual weekly allowance.
    var shortTitle: String {
        func short(_ label: String) -> String {
            switch label {
            case "5 hours": "5h"
            case "Weekly": "Week"
            default: label
            }
        }
        if id == "fiveHour" { return "5h" }
        if id == "weekly" { return "Week" }
        // Codex: "<limit name> · 5 hours"; Claude: "<model> weekly".
        let parts = title.components(separatedBy: " · ")
        if parts.count == 2 { return parts[0] + " " + short(parts[1]) }
        return title.hasSuffix(" weekly") ? String(title.dropLast(7)) : title
    }
}
