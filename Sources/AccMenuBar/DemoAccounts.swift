import Foundation
import AccCore

/// Display-only fixtures for UI iteration. No credential-shaped data is created.
enum DemoAccounts {
    static func make() -> [AccountSummary] {
        let now = Date().timeIntervalSinceReferenceDate
        func account(_ id: String, provider: String, label: String, plan: String, active: Bool, five: Double, week: Double) -> [String: Any] {
            ["id": id, "provider": provider, "label": label,
             "identity": ["userID": "demo-" + provider, "email": "hello@example.test", "plan": plan],
             "expiresAt": now + (provider == "claude" ? 28800 : 6 * 86400), "lastRefreshedAt": now - 86400,
             "lastCheckedAt": now - 20, "lastRefreshAttemptAt": now - 86400,
             "nextRefreshAt": now + (provider == "claude" ? 25200 : 86400), "renewalHealth": "ready", "isActive": active, "health": "ready",
             "usage": ["fetchedAt": now, "windows": [
                ["id": "fiveHour", "title": "5 hours", "usedPercent": five, "resetsAt": now + 7200, "durationSeconds": 18000],
                ["id": "weekly", "title": "Weekly", "usedPercent": week, "resetsAt": now + 216000, "durationSeconds": 604800],
             ]]]
        }
        let rows = [
            account("00000000-0000-0000-0000-000000000001", provider: "codex", label: "Personal", plan: "Plus", active: true, five: 28, week: 46),
            account("00000000-0000-0000-0000-000000000002", provider: "codex", label: "Work", plan: "Pro", active: false, five: 8, week: 17),
            account("00000000-0000-0000-0000-000000000003", provider: "claude", label: "Claude", plan: "Max", active: true, five: 88, week: 63),
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: rows),
              let result = try? JSONDecoder().decode([AccountSummary].self, from: data) else { return [] }
        return result
    }
}
