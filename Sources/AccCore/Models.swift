import Foundation

public enum Provider: String, Codable, CaseIterable, Sendable, Identifiable {
    case codex, claude
    public var id: String { rawValue }
    public var title: String { self == .codex ? "Codex" : "Claude" }
}

public struct AccountIdentity: Codable, Equatable, Sendable {
    public var userID: String
    public var organizationID: String?
    public var email: String?
    public var plan: String?
    var key: String { userID + "|" + (organizationID ?? "") }
    public init(userID: String, organizationID: String? = nil, email: String? = nil, plan: String? = nil) {
        self.userID = userID; self.organizationID = organizationID; self.email = email; self.plan = plan
    }
}

public struct UsageWindow: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var usedPercent: Double
    public var resetsAt: Date?
    public var durationSeconds: Int?
    public var remainingPercent: Double { max(0, min(100, 100 - usedPercent)) }
    public init(id: String, title: String, usedPercent: Double, resetsAt: Date? = nil, durationSeconds: Int? = nil) {
        self.id = id; self.title = title; self.usedPercent = usedPercent
        self.resetsAt = resetsAt; self.durationSeconds = durationSeconds
    }
}

public struct UsageSnapshot: Codable, Equatable, Sendable {
    public var windows: [UsageWindow]
    public var fetchedAt: Date
    public var plan: String?
    public var fiveHour: UsageWindow? { windows.first { $0.id == "fiveHour" } }
    public var weekly: UsageWindow? { windows.first { $0.id == "weekly" } }
    /// A passed reset invalidates the old measurement; it does not prove that the
    /// provider reset the allowance to 100 percent.
    public func isStale(at now: Date = Date()) -> Bool {
        now.timeIntervalSince(fetchedAt) > 600 || crossedReset(at: now)
    }
    public func needsRefresh(at now: Date = Date(), interval: TimeInterval) -> Bool {
        now.timeIntervalSince(fetchedAt) >= interval || crossedReset(at: now)
    }
    private func crossedReset(at now: Date) -> Bool {
        windows.contains { $0.resetsAt.map { $0 > fetchedAt && $0 <= now } ?? false }
    }
    public init(windows: [UsageWindow], fetchedAt: Date, plan: String? = nil) {
        self.windows = windows; self.fetchedAt = fetchedAt; self.plan = plan
    }
}

public enum AccountHealth: String, Codable, Sendable { case ready, needsSignIn, retrying, uncertain }

/// The public account projection deliberately contains no credentials.
public struct AccountSummary: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var provider: Provider
    public var label: String
    public var identity: AccountIdentity
    public var expiresAt: Date?
    public var isActive: Bool
    public var health: AccountHealth
    public var message: String?
    public var usage: UsageSnapshot?
    public var usageMessage: String?
    public var nextRetryAt: Date?
    public var isPaused: Bool?
    public var lastCheckedAt: Date?
    public var lastRefreshAttemptAt: Date?
    public var lastRefreshedAt: Date?
    public var nextRefreshAt: Date?
    public var nextRenewalRetryAt: Date?
    public var renewalHealth: AccountHealth?
    public var refreshHistory: [RefreshEvent]?
    public init(id: UUID, provider: Provider, label: String, identity: AccountIdentity, expiresAt: Date? = nil,
                isActive: Bool = false, health: AccountHealth = .ready, message: String? = nil,
                usage: UsageSnapshot? = nil, nextRetryAt: Date? = nil, isPaused: Bool? = nil) {
        self.id = id; self.provider = provider; self.label = label; self.identity = identity; self.expiresAt = expiresAt
        self.isActive = isActive; self.health = health; self.message = message; self.usage = usage
        self.nextRetryAt = nextRetryAt; self.isPaused = isPaused
    }
}

/// Read-only discovery of the provider's current login, including unsaved logins.
public struct CurrentLogin: Codable, Identifiable, Equatable, Sendable {
    public var id: Provider { provider }
    public var provider: Provider
    public var identity: AccountIdentity?
    public var expiresAt: Date?
    public var savedAccountID: UUID?
    public var message: String?
    public var revision: String?
    public var requiresKeychainAccess: Bool?
    public init(provider: Provider, identity: AccountIdentity? = nil, expiresAt: Date? = nil,
                savedAccountID: UUID? = nil, message: String? = nil, revision: String? = nil, requiresKeychainAccess: Bool? = nil) {
        self.provider = provider; self.identity = identity; self.expiresAt = expiresAt
        self.savedAccountID = savedAccountID; self.message = message; self.revision = revision
        self.requiresKeychainAccess = requiresKeychainAccess
    }
}

public struct RefreshEvent: Codable, Equatable, Sendable, Identifiable {
    public var id = UUID()
    public var date: Date
    public var outcome: String
    public var message: String?
}

public struct Preferences: Codable, Equatable, Sendable {
    public var keepFresh = true
    public var showUsage = true
    public var usageIntervalSeconds: TimeInterval = 300
    /// Leave room for transient failures before Claude's short-lived token expires.
    public var refreshBeforeExpirySeconds: TimeInterval = 3600
    /// Codex Auth Guard's early renewal margin.
    public var codexRefreshBeforeExpirySeconds: TimeInterval = 120 * 3600
    public var maximumRefreshIntervalSeconds: TimeInterval = 5 * 86400
    public var refreshWhenNativeUnavailable = true
    public var retryUncertainRefresh = false
    private var renewalDefaultsVersion = 2
    public init() {}
    private enum CodingKeys: String, CodingKey {
        case keepFresh, showUsage, usageIntervalSeconds, refreshBeforeExpirySeconds
        case codexRefreshBeforeExpirySeconds, maximumRefreshIntervalSeconds, refreshWhenNativeUnavailable, retryUncertainRefresh
        case renewalDefaultsVersion
    }
    public init(from decoder: any Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        keepFresh = try c.decodeIfPresent(Bool.self, forKey: .keepFresh) ?? keepFresh
        showUsage = try c.decodeIfPresent(Bool.self, forKey: .showUsage) ?? showUsage
        usageIntervalSeconds = try c.decodeIfPresent(Double.self, forKey: .usageIntervalSeconds) ?? usageIntervalSeconds
        refreshBeforeExpirySeconds = try c.decodeIfPresent(Double.self, forKey: .refreshBeforeExpirySeconds) ?? refreshBeforeExpirySeconds
        // Old vaults did not record whether the ten-minute default was explicitly
        // chosen. Upgrade that legacy default once; preserve custom values and all
        // choices made after this version, including an explicit ten minutes.
        if !c.contains(.renewalDefaultsVersion), refreshBeforeExpirySeconds == 600 {
            refreshBeforeExpirySeconds = 3600
        }
        codexRefreshBeforeExpirySeconds = try c.decodeIfPresent(Double.self, forKey: .codexRefreshBeforeExpirySeconds) ?? codexRefreshBeforeExpirySeconds
        maximumRefreshIntervalSeconds = try c.decodeIfPresent(Double.self, forKey: .maximumRefreshIntervalSeconds) ?? maximumRefreshIntervalSeconds
        refreshWhenNativeUnavailable = try c.decodeIfPresent(Bool.self, forKey: .refreshWhenNativeUnavailable) ?? refreshWhenNativeUnavailable
        retryUncertainRefresh = try c.decodeIfPresent(Bool.self, forKey: .retryUncertainRefresh) ?? retryUncertainRefresh
    }
}

public enum AccError: Error, LocalizedError, Sendable, Equatable {
    case busy, missingAccount, invalidCredentials, invalidResponse, signInRequired
    case refreshUncertain, requestNotSent
    case network, http(Int), rateLimited(Date), storage, keychain(Int32), externalChange
    case unsupportedStorage, executableMissing(Provider), loginFailed, loginTimedOut
    case identityMismatch, invalidArgument(String), pendingSignIn(UUID), unsupportedAuthentication
    public var errorDescription: String? {
        switch self {
        case .busy: "Another account operation is in progress. Try again shortly."
        case .missingAccount: "Account not found."
        case .unsupportedAuthentication: "This login uses an authentication method Acc does not manage. Sign in with a ChatGPT subscription."
        case .invalidCredentials: "This file does not contain a supported OAuth login."
        case .invalidResponse: "The provider returned an unexpected response."
        case .signInRequired: "Sign in again to refresh this account."
        case .refreshUncertain: "Renewal outcome unknown. The provider may have consumed this refresh token. Sign in again, or explicitly retry renewal."
        case .requestNotSent: "Could not connect to the provider. Acc will retry later."
        case .network: "Could not reach the provider. Acc will retry later."
        case .http(let code): "The provider returned HTTP \(code)."
        case .rateLimited: "The provider is rate limiting requests. Acc will retry later."
        case .storage: "Could not read or save Acc's private account store."
        case .keychain(let status): "Keychain access is needed (\(status)). Allow access from the account menu, then retry."
        case .externalChange: "The active login changed during this operation. Refresh and try again."
        case .unsupportedStorage: "This credential storage mode is not supported. Use file, keyring, or auto."
        case .executableMissing(let provider): "Install \(provider.title) CLI to sign in."
        case .loginFailed: "Sign-in did not complete. Try again."
        case .loginTimedOut: "Sign-in timed out after ten minutes. Try again."
        case .identityMismatch: "This login belongs to a different account. Add it as a new account instead."
        case .pendingSignIn(let id): "Sign-in is saved but could not be added yet. Finish adding it in Acc, or run acc login-resume \(id.uuidString)."
        case .invalidArgument(let message): message
        }
    }
}

struct AccountRecord: Codable, Sendable {
    var id = UUID()
    var label: String
    var credential: Credential
    var health: AccountHealth = .ready
    var message: String?
    var usage: UsageSnapshot?
    var lastUsageAttempt: Date?
    var nextRetryAt: Date?
    var failures = 0
    var addedAt = Date()
    var nativeFingerprint: String?
    var pendingNativePublication: Bool?
    var usageMessage: String?
    var usageRetryAt: Date?
    var usageFailures: Int?
    var usageRetryOnConnectivity: Bool?
    var isPaused: Bool?
    var lastCheckedAt: Date?
    var lastRefreshAttemptAt: Date?
    var lastRefreshedAt: Date?
    var refreshHistory: [RefreshEvent]?
    var retryOnConnectivity: Bool?
    var syncMessage: String?
    var refreshInFlight: Bool?

    func renewalDate(_ preferences: Preferences) -> Date {
        credential.renewalDate(preferences: preferences, lastRenewal: lastRefreshedAt, firstObservedAt: addedAt)
    }

    func usageIsDue(at now: Date, interval: TimeInterval, connectivityRestored: Bool) -> Bool {
        if let retry = usageRetryAt {
            return now >= retry || (connectivityRestored && usageRetryOnConnectivity == true)
        }
        return usage?.needsRefresh(at: now, interval: interval) ?? true
    }
}

struct Vault: Codable, Sendable {
    var version = 1
    var accounts: [AccountRecord] = []
    var preferences = Preferences()
    var forgottenIdentities: [String]?
}

public func safeMessage(_ error: Error) -> String {
    (error as? AccError)?.localizedDescription ?? (error is CancellationError ? "Cancelled." : "The operation failed. Try again.")
}
