import Foundation
import Testing
@testable import AccCore

let testNow = Date(timeIntervalSince1970: 1_800_000_000)
func object(_ value: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) }
func token(_ claims: [String: Any]) throws -> String {
    let payload = try object(claims).base64EncodedString().replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    return "fixture.\(payload).signature"
}
func codex(_ user: String = "alice", expires: Date = testNow.addingTimeInterval(7200), rotation: Int = 0, organization: String = "personal") throws -> Credential {
    let claims: [String: Any] = ["sub": user, "email": "\(user)@example.test", "exp": expires.timeIntervalSince1970,
        "https://api.openai.com/auth": ["chatgpt_account_id": organization, "chatgpt_user_id": user, "chatgpt_plan_type": "plus"]]
    return try Credential.parse(object(["tokens": ["access_token": token(claims), "id_token": token(claims),
        "refresh_token": "fixture-refresh-\(user)-\(rotation)", "account_id": organization],
        "auth_mode": "chatgpt", "last_refresh": ISO8601DateFormatter().string(from: testNow.addingTimeInterval(Double(rotation))),
        "future_field": ["preserved": true]]), provider: .codex)
}
func claude(_ user: String = "alice") throws -> Credential {
    try Credential.parse(object(["claudeAiOauth": ["accessToken": "fixture-access-\(user)", "refreshToken": "fixture-refresh-\(user)",
        "expiresAt": testNow.addingTimeInterval(7200).timeIntervalSince1970 * 1000,
        "scopes": ["user:profile", "user:inference"], "subscriptionType": "max"],
        "oauthAccount": ["accountUuid": user, "organizationUuid": "org", "emailAddress": "\(user)@example.test"]]), provider: .claude)
}
func usageSnapshot() -> UsageSnapshot {
    UsageSnapshot(windows: [UsageWindow(id: "fiveHour", title: "5 hours", usedPercent: 25, resetsAt: testNow.addingTimeInterval(300), durationSeconds: 18000)], fetchedAt: testNow)
}

final class MemoryActive: ActiveCredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Provider: ActiveSnapshot] = [:]
    private var failWrite = false
    private var failRead = false
    private var partialWrite = false
    func set(_ credential: Credential) { lock.withLock { values[credential.provider] = ActiveSnapshot(credential: credential) } }
    func setFailWrite(_ value: Bool) { lock.withLock { failWrite = value } }
    func setPartialWrite(_ value: Bool) { lock.withLock { partialWrite = value } }
    func setFailRead(_ value: Bool) { lock.withLock { failRead = value } }
    func read(_ provider: Provider) throws -> ActiveSnapshot? {
        try lock.withLock { if failRead { throw AccError.keychain(-1) }; return values[provider] }
    }
    func replace(_ credential: Credential, expected: ActiveSnapshot?) throws {
        try lock.withLock {
            guard !failWrite else { throw AccError.storage }
            guard values[credential.provider]?.fingerprint == expected?.fingerprint else { throw AccError.externalChange }
            values[credential.provider] = ActiveSnapshot(credential: credential)
            if partialWrite { throw AccError.storage }
        }
    }
    func clear(_ provider: Provider, expected: ActiveSnapshot?) throws {
        try lock.withLock {
            guard values[provider]?.fingerprint == expected?.fingerprint else { throw AccError.externalChange }
            values[provider] = nil
        }
    }
}

actor TestClient: ProviderClient {
    var refreshCalls = 0
    var usageCalls = 0
    var usageAccounts: [String] = []
    var refreshError: AccError?
    var usageError: AccError?
    var onRefresh: (@Sendable () -> Void)?
    var pause: Duration?
    func configure(refreshError: AccError? = nil, usageError: AccError? = nil, pause: Duration? = nil, onRefresh: (@Sendable () -> Void)? = nil) {
        self.refreshError = refreshError; self.usageError = usageError; self.pause = pause; self.onRefresh = onRefresh
    }
    func identify(_ credential: Credential) async throws -> Credential { credential }
    func refresh(_ credential: Credential, now: Date) async throws -> Credential {
        refreshCalls += 1
        if let pause { try await Task.sleep(for: pause) }
        if let refreshError { throw refreshError }
        onRefresh?()
        var result = try codex(credential.identity.userID, expires: now.addingTimeInterval(7200), rotation: refreshCalls,
                               organization: credential.identity.organizationID ?? "personal")
        if credential.provider == .claude { result = credential }
        return result
    }
    func usage(_ credential: Credential, now: Date) async throws -> UsageSnapshot {
        usageCalls += 1
        usageAccounts.append(credential.identity.userID)
        if let usageError { throw usageError }
        var snapshot = usageSnapshot()
        snapshot.fetchedAt = now
        return snapshot
    }
}

struct TestEnvironment {
    let root: URL
    let paths: AccPaths
    let active = MemoryActive()
    let client = TestClient()
    let service: AccountService
    init() {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("acc-tests-" + UUID().uuidString)
        paths = AccPaths(root: root.appendingPathComponent("vault"), home: root, environment: [:])
        service = AccountService(paths: paths, active: active, client: client)
    }
    func cleanup() { try? FileManager.default.removeItem(at: root) }
}

actor QueueTransport: HTTPTransport {
    var responses: [HTTPResponse]
    var requests: [URLRequest] = []
    init(_ responses: [HTTPResponse]) { self.responses = responses }
    func send(_ request: URLRequest) async throws -> HTTPResponse {
        requests.append(request)
        guard !responses.isEmpty else { throw AccError.network }
        return responses.removeFirst()
    }
}

final class MemoryKeychain: KeychainAccess, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: Data] = [:]
    func read(service: String, account: String) throws -> Data? { lock.withLock { items[service + ":" + account] } }
    func write(_ data: Data, service: String, account: String) throws { lock.withLock { items[service + ":" + account] = data } }
    func delete(service: String, account: String) throws { _ = lock.withLock { items.removeValue(forKey: service + ":" + account) } }
}
