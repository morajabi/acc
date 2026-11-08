import Foundation
import Testing
@testable import AccCore

private let syntheticAccess = "fixture-access-shape"
private let syntheticRefresh = "fixture-refresh-shape"
private var mcpState: [String: Any] { ["fixture-server|0": ["serverName": "fixture", "accessToken": "fixture-mcp-access",
    "expiresAt": 0, "discoveryState": ["authorizationServerUrl": "https://mcp.example.test"]]] }

private func oauth(_ overrides: [String: Any?] = [:]) -> [String: Any] {
    var tokens: [String: Any] = ["accessToken": syntheticAccess, "refreshToken": syntheticRefresh,
        "expiresAt": testNow.addingTimeInterval(7200).timeIntervalSince1970 * 1000,
        "scopes": ["user:inference", "user:profile"], "subscriptionType": "max", "rateLimitTier": "default_claude_max_20x"]
    for (key, value) in overrides { tokens[key] = value ?? NSNull() }
    return tokens
}

private struct ShapeHome {
    let env = TestEnvironment()
    let keychain = MemoryKeychain()
    var native: NativeCredentialStore { NativeCredentialStore(paths: env.paths, keychain: keychain) }
    var file: URL { env.paths.claudeCredentialsHome.appendingPathComponent(".credentials.json") }
    func storeKeychain(_ data: Data) throws {
        try keychain.write(data, service: env.paths.claudeKeychainService, account: env.paths.claudeKeychainAccount)
    }
    func keychainDocument() throws -> Data? {
        try keychain.read(service: env.paths.claudeKeychainService, account: env.paths.claudeKeychainAccount)
    }
    func storeFile(_ data: Data) throws { try privateWrite(data, to: file) }
    func storeAccount(_ user: String) throws {
        try privateWrite(object(["theme": "dark", "oauthAccount": ["accountUuid": user, "organizationUuid": "org",
            "emailAddress": "\(user)@example.test", "billingType": "stripe_subscription"]]), to: env.paths.claudeConfig)
    }
}

private struct ThrowingKeychain: KeychainAccess {
    func read(service: String, account: String) throws -> Data? { throw AccError.keychain(-25308) }
    func write(_ data: Data, service: String, account: String) throws { throw AccError.keychain(-25308) }
    func delete(service: String, account: String) throws { throw AccError.keychain(-25308) }
}

@Test func currentClaudeCodeKeychainShapeParsesAndKeepsUnknownFields() throws {
    var tokens = oauth()
    tokens["refreshTokenExpiresAt"] = testNow.addingTimeInterval(86400 * 30).timeIntervalSince1970 * 1000
    tokens["subscriptionTypeSource"] = "profile"
    tokens["clientId"] = "fixture-client"
    let credential = try Credential.parse(object(["mcpOAuth": mcpState, "claudeAiOauth": tokens]), provider: .claude)
    #expect(credential.accessToken == syntheticAccess)
    #expect(credential.refreshToken == syntheticRefresh)
    #expect(credential.identity.plan == "max")
    #expect(credential.expiresAt == testNow.addingTimeInterval(7200))
    let stored = try #require(credential.object["claudeAiOauth"] as? [String: Any])
    #expect(stored["subscriptionTypeSource"] as? String == "profile")
    #expect(stored["refreshTokenExpiresAt"] != nil)
    #expect(credential.object["mcpOAuth"] != nil)
}

@Test(arguments: [
    ("1800000000000", 1_800_000_000.0 as Double?),
    ("1800000000123.0", 1_800_000_000.123),
    ("1800000000", 1_800_000_000),
    ("\"2027-01-15T08:00:00Z\"", 1_800_000_000),
    ("\"2027-01-15T08:00:00.250Z\"", 1_800_000_000.25),
    ("\"1800000000000\"", 1_800_000_000),
    ("0", nil),
    ("null", nil),
    ("true", nil),
    ("\"soon\"", nil),
])
func claudeExpiryAcceptsMillisecondsSecondsAndDates(fragment: String, expected: Double?) throws {
    let json = "{\"claudeAiOauth\":{\"accessToken\":\"\(syntheticAccess)\",\"expiresAt\":\(fragment)}}"
    let credential = try Credential.parse(Data(json.utf8), provider: .claude)
    let seconds = credential.expiresAt?.timeIntervalSince1970
    #expect((seconds == nil) == (expected == nil))
    if let seconds, let expected { #expect(abs(seconds - expected) < 0.001) }
}

@Test func claudeOptionalFieldsMayBeMissingOrNull() throws {
    let minimal = try Credential.parse(object(["claudeAiOauth": ["accessToken": syntheticAccess]]), provider: .claude)
    #expect(minimal.expiresAt == nil)
    #expect(minimal.refreshToken.isEmpty)
    #expect(minimal.identity.plan == nil)
    let nulls = try Credential.parse(object(["claudeAiOauth": oauth(["refreshToken": nil, "expiresAt": nil, "scopes": nil,
        "subscriptionType": nil, "rateLimitTier": nil])]), provider: .claude)
    #expect(nulls.refreshToken.isEmpty)
    #expect(nulls.identity.plan == nil)
    #expect(nulls.expiresAt == nil)
}

@Test func bareClaudeTokenObjectIsWrappedForPublication() throws {
    var tokens = oauth()
    tokens["futureField"] = ["preserved": true]
    let credential = try Credential.parse(object(tokens), provider: .claude)
    #expect(credential.accessToken == syntheticAccess)
    let wrapped = try #require(credential.object["claudeAiOauth"] as? [String: Any])
    #expect(wrapped["futureField"] != nil)
    #expect(credential.object["accessToken"] == nil)
}

@Test func keychainPaddingAroundClaudeJSONIsTolerated() throws {
    let json = try object(["claudeAiOauth": oauth()])
    let padded = Data([0xEF, 0xBB, 0xBF]) + json + Data("\n".utf8) + Data([0, 0])
    let credential = try Credential.parse(padded, provider: .claude)
    #expect(credential.accessToken == syntheticAccess)
    #expect(credential.document == json)
}

@Test func claudeDocumentsWithoutAUsableLoginExplainWhy() throws {
    #expect(throws: AccError.loginNotFound(.claude)) { try Credential.parse(object(["mcpOAuth": mcpState]), provider: .claude) }
    #expect(throws: AccError.loginNotFound(.claude)) { try Credential.parse(object([:]), provider: .claude) }
    #expect(throws: AccError.loginNotFound(.claude)) {
        try Credential.parse(object(["claudeAiOauth": NSNull(), "mcpOAuth": mcpState]), provider: .claude)
    }
    #expect(throws: AccError.loginEnded(.claude)) {
        try Credential.parse(object(["claudeAiOauth": oauth(["accessToken": "", "refreshToken": "", "expiresAt": 0,
            "loginEnded": "time_limit"])]), provider: .claude)
    }
    #expect(throws: AccError.loginEnded(.claude)) { try Credential.parse(object(["claudeAiOauth": ["refreshToken": syntheticRefresh]]), provider: .claude) }
    #expect(throws: AccError.invalidCredentials) { try Credential.parse(Data("{\"claudeAiOauth\":{\"accessToken\":".utf8), provider: .claude) }
}

@Test func claudeLoginMessagesAreActionableAndCredentialFree() {
    let errors: [AccError] = [.loginNotFound(.claude), .loginEnded(.claude), .unreadableLogin(.claude), .noRefreshToken(.claude)]
    for error in errors {
        let message = safeMessage(error)
        #expect(message.contains("Claude"))
        #expect(message.contains("claude auth login"))
        #expect(!message.contains("does not contain a supported OAuth login"))
        #expect(!message.contains("fixture"))
    }
    #expect(safeMessage(AccError.loginNotFound(.codex)).contains("codex login"))
}

@Test func mcpOnlyKeychainIsReportedAsMissingLoginNotAsAnInvalidFile() throws {
    let home = ShapeHome(); defer { home.env.cleanup() }
    try home.storeKeychain(object(["mcpOAuth": mcpState]))
    guard case .unusable(let reason)? = try home.native.inspect(.claude) else { Issue.record("expected an unusable login"); return }
    #expect(reason == .loginNotFound(.claude))
    #expect(try home.native.read(.claude) == nil)
}

@Test func endedKeychainLoginIsReportedAsEnded() throws {
    let home = ShapeHome(); defer { home.env.cleanup() }
    try home.storeKeychain(object(["claudeAiOauth": oauth(["accessToken": "", "refreshToken": "", "expiresAt": 0]), "mcpOAuth": mcpState]))
    try home.storeFile(object(["mcpOAuth": mcpState]))
    guard case .unusable(let reason)? = try home.native.inspect(.claude) else { Issue.record("expected an unusable login"); return }
    #expect(reason == .loginEnded(.claude))
}

@Test func malformedKeychainOnlyIsReportedAsUnreadable() throws {
    let home = ShapeHome(); defer { home.env.cleanup() }
    try home.storeKeychain(Data("{\"claudeAiOauth\":".utf8))
    guard case .unusable(let reason)? = try home.native.inspect(.claude) else { Issue.record("expected an unusable login"); return }
    #expect(reason == .unreadableLogin(.claude))
}

@Test func unusableKeychainFallsBackToFileAndPublishesToBothStores() throws {
    let home = ShapeHome(); defer { home.env.cleanup() }
    try home.storeAccount("alice")
    try home.storeKeychain(object(["mcpOAuth": mcpState]))
    try home.storeFile(object(["claudeAiOauth": oauth()]))
    let snapshot = try #require(try home.native.read(.claude))
    #expect(snapshot.credential.accessToken == syntheticAccess)
    #expect(snapshot.credential.identity.userID == "alice")
    #expect(snapshot.location == "keychain")
    try home.native.replace(claude("bob"), expected: snapshot)
    #expect(try Credential.parse(#require(try home.keychainDocument()), provider: .claude).identity.userID == "bob")
    #expect(try Credential.parse(Data(contentsOf: home.file), provider: .claude).identity.userID == "bob")
    #expect(try home.native.read(.claude)?.credential.identity.userID == "bob")
}

@Test func malformedKeychainFallsBackToUsableFile() throws {
    let home = ShapeHome(); defer { home.env.cleanup() }
    try home.storeKeychain(Data("not json".utf8))
    try home.storeFile(claude().document)
    #expect(try home.native.read(.claude)?.credential.identity.userID == "alice")
}

@Test func usableKeychainWinsOverStaleFile() throws {
    let home = ShapeHome(); defer { home.env.cleanup() }
    try home.storeKeychain(claude("alice").document)
    try home.storeFile(object(["mcpOAuth": mcpState]))
    let snapshot = try #require(try home.native.read(.claude))
    #expect(snapshot.credential.identity.userID == "alice")
    #expect(snapshot.location == "keychain")
}

@Test func lockedKeychainStillWinsOverAnUnusableFile() throws {
    let env = TestEnvironment(); defer { env.cleanup() }
    let native = NativeCredentialStore(paths: env.paths, keychain: ThrowingKeychain())
    try privateWrite(object(["mcpOAuth": mcpState]), to: env.paths.claudeCredentialsHome.appendingPathComponent(".credentials.json"))
    #expect(throws: AccError.keychain(-25308)) { _ = try native.inspect(.claude) }
}

@Test func switchingReplacesAnUnusableNativeLogin() throws {
    let home = ShapeHome(); defer { home.env.cleanup() }
    try home.storeKeychain(object(["claudeAiOauth": oauth(["accessToken": "", "refreshToken": ""])]))
    try home.native.replace(claude("bob"), expected: home.native.read(.claude))
    #expect(try home.native.read(.claude)?.credential.identity.userID == "bob")
}

@Test func currentLoginShowsSpecificReasonWithoutMarkingSavedAccountsUnavailable() async throws {
    let home = ShapeHome(); defer { home.env.cleanup() }
    let service = AccountService(paths: home.env.paths, active: home.native, client: home.env.client)
    try home.storeKeychain(claude("alice").document)
    let id = try await service.importCurrent(.claude)
    try home.storeKeychain(object(["mcpOAuth": mcpState]))
    let current = try #require(try await service.currentLogins([.claude]).first)
    #expect(current.identity == nil)
    #expect(current.message == safeMessage(AccError.loginNotFound(.claude)))
    #expect(current.requiresKeychainAccess != true)
    let saved = try #require(try await service.accounts().first { $0.id == id })
    #expect(saved.message == nil)
    #expect(saved.isActive == false)
    await #expect(throws: AccError.loginNotFound(.claude)) { _ = try await service.importCurrent(.claude) }
    await #expect(throws: AccError.loginNotFound(.claude)) { _ = try await service.currentUsage(.claude, now: testNow) }
}

@Test func missingNativeLoginIsReportedAsNotFound() async throws {
    let home = ShapeHome(); defer { home.env.cleanup() }
    let service = AccountService(paths: home.env.paths, active: home.native, client: home.env.client)
    await #expect(throws: AccError.loginNotFound(.claude)) { _ = try await service.importCurrent(.claude) }
    #expect(try await service.currentLogins([.claude]).first?.message == nil)
}

@Test func claudeLoginWithoutRefreshTokenCannotBeSaved() async throws {
    let env = TestEnvironment(); defer { env.cleanup() }
    let credential = try Credential.parse(object(["claudeAiOauth": oauth(["refreshToken": nil]),
        "oauthAccount": ["accountUuid": "alice", "organizationUuid": "org"]]), provider: .claude)
    await #expect(throws: AccError.noRefreshToken(.claude)) { _ = try await env.service.importCredential(credential) }
}

@Test func claudeKeychainAccountMatchesClaudeCodeNaming() {
    #expect(AccPaths.claudeAccount(user: "b.rajabifard") == "b.rajabifard")
    #expect(AccPaths.claudeAccount(user: "first_last-2") == "first_last-2")
    #expect(AccPaths.claudeAccount(user: "first last") == "claude-code-user")
    #expect(AccPaths.claudeAccount(user: "DOMAIN\\user") == "claude-code-user")
    #expect(AccPaths(home: URL(fileURLWithPath: "/tmp/acc-fixture-home"), environment: ["USER": "fixture.user"]).claudeKeychainAccount == "fixture.user")
    #expect(AccPaths(home: URL(fileURLWithPath: "/tmp/acc-fixture-home"), environment: ["USER": "fixture user"]).claudeKeychainAccount == "claude-code-user")
}
