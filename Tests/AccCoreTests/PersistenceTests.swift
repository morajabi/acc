import Foundation
import Testing
@testable import AccCore

@Test func nativeCodexSwitchPreservesSettingsAndDetectsExternalChanges() throws {
    let env = TestEnvironment(); defer { env.cleanup() }
    try privateDirectory(env.paths.codexHome)
    let settings = Data("model = \"test-model\"\n".utf8)
    let config = env.paths.codexHome.appendingPathComponent("config.toml")
    try settings.write(to: config)
    let native = NativeCredentialStore(paths: env.paths)
    try native.replace(codex(), expected: nil)
    let snapshot = try #require(try native.read(.codex))
    try native.replace(codex("bob"), expected: snapshot)
    #expect(try Data(contentsOf: config) == settings)
    #expect(try native.read(.codex)?.credential.identity.userID == "bob")
    #expect(throws: AccError.externalChange) { try native.replace(codex("eve"), expected: snapshot) }
    try native.clear(.codex, expected: native.read(.codex))
    #expect(try native.read(.codex) == nil)
}

@Test func lockIsExclusiveAndReleased() throws {
    let env = TestEnvironment(); defer { env.cleanup() }
    let store = VaultStore(root: env.paths.root)
    do {
        let lock = try store.lock()
        #expect(throws: AccError.busy) { _ = try store.lock() }
        withExtendedLifetime(lock) {}
    }
    let next = try store.lock(); withExtendedLifetime(next) {}
}

@Test func corruptVaultDoesNotBecomeEmpty() throws {
    let env = TestEnvironment(); defer { env.cleanup() }
    try privateDirectory(env.paths.root)
    try privateWrite(Data("corrupted".utf8), to: env.paths.root.appendingPathComponent("accounts.json"))
    #expect(throws: AccError.storage) { _ = try VaultStore(root: env.paths.root).load() }
}

@Test func symbolicLinkCannotRedirectCredentialWrites() throws {
    let env = TestEnvironment(); defer { env.cleanup() }
    try privateDirectory(env.root)
    let target = env.root.appendingPathComponent("target")
    try Data("original".utf8).write(to: target)
    let link = env.root.appendingPathComponent("link")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
    #expect(throws: AccError.storage) { try privateWrite(Data("changed".utf8), to: link) }
    #expect(try String(contentsOf: target, encoding: .utf8) == "original")
}

@Test func signInUsesIsolatedHomesAndRemovesCredentialOverrides() {
    let directory = URL(fileURLWithPath: "/tmp/acc-fixture-login")
    let env = SignInService.environment(.claude, directory: directory,
        inherited: ["ANTHROPIC_API_KEY": "fixture", "CLAUDE_CODE_OAUTH_TOKEN": "fixture", "PATH": "/bin"])
    #expect(env["CLAUDE_CONFIG_DIR"] == directory.path)
    #expect(env["ANTHROPIC_API_KEY"] == nil)
    #expect(env["CLAUDE_CODE_OAUTH_TOKEN"] == nil)
    #expect(env["PATH"] == "/bin")
    #expect(SignInService.arguments(.claude) == ["auth", "login"])
    #expect(SignInService.arguments(.codex).contains("cli_auth_credentials_store=\"file\""))
    #expect(AccPaths.claudeService(configDirectory: nil) == "Claude Code-credentials")
    #expect(AccPaths.claudeService(configDirectory: directory.path) != "Claude Code-credentials")
}

@Test func claudeSwitchUpdatesKeychainFallbackAndIdentityPreservingSettings() throws {
    let env = TestEnvironment(); defer { env.cleanup() }
    let keychain = MemoryKeychain()
    let native = NativeCredentialStore(paths: env.paths, keychain: keychain)
    try privateDirectory(env.paths.claudeHome)
    let fallback = env.paths.claudeHome.appendingPathComponent(".credentials.json")
    try privateWrite(claude().document, to: fallback)
    try keychain.write(claude().document, service: env.paths.claudeKeychainService, account: NSUserName())
    try privateWrite(object(["theme": "dark", "oauthAccount": ["accountUuid": "alice"]]), to: env.paths.claudeConfig)
    try native.replace(claude("bob"), expected: native.read(.claude))
    #expect(try native.read(.claude)?.credential.identity.userID == "bob")
    #expect(try Credential.parse(Data(contentsOf: fallback), provider: .claude).identity.userID == "bob")
    var config = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: env.paths.claudeConfig)) as? [String: Any])
    #expect(config["theme"] as? String == "dark")
    #expect((config["oauthAccount"] as? [String: Any])?["accountUuid"] as? String == "bob")
    try native.clear(.claude, expected: native.read(.claude))
    #expect(try native.read(.claude) == nil)
    config = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: env.paths.claudeConfig)) as? [String: Any])
    #expect(config["oauthAccount"] == nil)
    #expect(config["theme"] as? String == "dark")
}

@Test func codexKeyringModeUsesHashedHomeAndKeepsFileUntouched() throws {
    let env = TestEnvironment(); defer { env.cleanup() }
    let keychain = MemoryKeychain()
    let native = NativeCredentialStore(paths: env.paths, keychain: keychain)
    try privateDirectory(env.paths.codexHome)
    try privateWrite(Data("cli_auth_credentials_store = \"keyring\"\n".utf8), to: env.paths.codexHome.appendingPathComponent("config.toml"))
    try native.replace(codex(), expected: nil)
    #expect(try native.read(.codex)?.credential.identity.userID == "alice")
    #expect(!FileManager.default.fileExists(atPath: env.paths.codexHome.appendingPathComponent("auth.json").path))
    let key = "cli|" + digest(Data(env.paths.codexHome.resolvingSymlinksInPath().path.utf8)).prefix(16)
    #expect(try keychain.read(service: "Codex Auth", account: key) != nil)
}

@Test func claudeLegacyConfigAndSameAccountMetadataArePreserved() throws {
    let env = TestEnvironment(); defer { env.cleanup() }
    let legacy = env.paths.claudeHome.appendingPathComponent(".config.json")
    try privateWrite(object(["theme": "dark", "oauthAccount": ["accountUuid": "alice", "organizationUuid": "org", "accountRole": "admin"]]), to: legacy)
    let paths = AccPaths(root: env.paths.root, home: env.root, environment: [:])
    #expect(paths.claudeConfig == legacy)
    let native = NativeCredentialStore(paths: paths, keychain: MemoryKeychain())
    try native.replace(claude(), expected: nil)
    let config = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: legacy)) as? [String: Any])
    #expect((config["oauthAccount"] as? [String: Any])?["accountRole"] as? String == "admin")
    try native.replace(claude("bob"), expected: native.read(.claude))
    let changed = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: legacy)) as? [String: Any])
    #expect((changed["oauthAccount"] as? [String: Any])?["accountRole"] == nil)
    #expect(changed["theme"] as? String == "dark")
}

@Test func claudeSeparateCredentialDirectoryAndLoginIsolation() throws {
    let env = TestEnvironment(); defer { env.cleanup() }
    let secureRoot = env.root.appendingPathComponent("secure")
    let paths = AccPaths(root: env.paths.root, home: env.root, environment: ["CLAUDE_SECURESTORAGE_CONFIG_DIR": secureRoot.path])
    #expect(paths.claudeCredentialsHome == secureRoot)
    try privateWrite(claude().document, to: secureRoot.appendingPathComponent(".credentials.json"))
    let native = NativeCredentialStore(paths: paths, keychain: MemoryKeychain())
    #expect(try native.read(.claude)?.credential.identity.userID == "alice")
    let login = SignInService.environment(.claude, directory: env.root.appendingPathComponent("isolated"),
        inherited: ["CLAUDE_SECURESTORAGE_CONFIG_DIR": secureRoot.path])
    #expect(login["CLAUDE_SECURESTORAGE_CONFIG_DIR"] == login["CLAUDE_CONFIG_DIR"])
}

@Test func codexAutoFallsBackToFileOnKeychainReadFailure() throws {
    let env = TestEnvironment(); defer { env.cleanup() }
    try privateWrite(Data("cli_auth_credentials_store = 'auto'\n".utf8), to: env.paths.codexHome.appendingPathComponent("config.toml"))
    try privateWrite(codex().document, to: env.paths.codexHome.appendingPathComponent("auth.json"))
    struct UnavailableKeychain: KeychainAccess {
        func read(service: String, account: String) throws -> Data? { throw AccError.keychain(-1) }
        func write(_ data: Data, service: String, account: String) throws { throw AccError.keychain(-1) }
        func delete(service: String, account: String) throws { throw AccError.keychain(-1) }
    }
    let native = NativeCredentialStore(paths: env.paths, keychain: UnavailableKeychain())
    #expect(try native.read(.codex)?.credential.identity.userID == "alice")
    try native.replace(codex("bob"), expected: native.read(.codex))
    #expect(try native.read(.codex)?.credential.identity.userID == "bob")
    try privateWrite(Data("cli_auth_credentials_store = 'keyring'\n".utf8), to: env.paths.codexHome.appendingPathComponent("config.toml"))
    #expect(throws: AccError.keychain(-1)) { _ = try native.read(.codex) }
}

@Test func invalidClaudeMetadataDoesNotPartiallySwitchCredentials() throws {
    let env = TestEnvironment(); defer { env.cleanup() }
    let keychain = MemoryKeychain()
    let native = NativeCredentialStore(paths: env.paths, keychain: keychain)
    try native.replace(claude(), expected: nil)
    let before = try native.read(.claude)
    try privateWrite(Data("not json".utf8), to: env.paths.claudeConfig)
    #expect(throws: (any Error).self) { try native.replace(claude("bob"), expected: before) }
    #expect(try native.read(.claude)?.fingerprint == before?.fingerprint)
}

@Test func codexAutoPromotesFileToKeychainAndRemovesStaleFallback() throws {
    let env = TestEnvironment(); defer { env.cleanup() }
    try privateWrite(Data("\"cli_auth_credentials_store\" = 'auto' # fixture\n".utf8), to: env.paths.codexHome.appendingPathComponent("config.toml"))
    let file = env.paths.codexHome.appendingPathComponent("auth.json")
    try privateWrite(codex().document, to: file)
    let native = NativeCredentialStore(paths: env.paths, keychain: MemoryKeychain())
    try native.replace(codex("bob"), expected: native.read(.codex))
    #expect(try native.read(.codex)?.credential.identity.userID == "bob")
    #expect(try native.read(.codex)?.location == "keychain")
    #expect(!FileManager.default.fileExists(atPath: file.path))
}

@Test func claudeFileFallbackWorksWhenKeychainIsLocked() throws {
    let env = TestEnvironment(); defer { env.cleanup() }
    struct LockedKeychain: KeychainAccess {
        func read(service: String, account: String) throws -> Data? { throw AccError.keychain(-25308) }
        func write(_ data: Data, service: String, account: String) throws { throw AccError.keychain(-25308) }
        func delete(service: String, account: String) throws { throw AccError.keychain(-25308) }
    }
    let native = NativeCredentialStore(paths: env.paths, keychain: LockedKeychain())
    #expect(throws: AccError.keychain(-25308)) { _ = try native.read(.claude) }
    try privateWrite(claude().document, to: env.paths.claudeCredentialsHome.appendingPathComponent(".credentials.json"))
    #expect(try native.read(.claude)?.credential.identity.userID == "alice")
    try native.replace(claude("bob"), expected: native.read(.claude))
    #expect(try native.read(.claude)?.credential.identity.userID == "bob")
}

@Test func homesAndEmptyOverridesResolveLikeProviderDefaults() {
    let root = URL(fileURLWithPath: "/tmp/acc-fixture-home")
    let paths = AccPaths(environment: ["HOME": root.path, "ACC_HOME": "", "CODEX_HOME": "", "CLAUDE_CONFIG_DIR": ""])
    #expect(paths.root == root.appendingPathComponent("Library/Application Support/Acc"))
    #expect(paths.codexHome == root.appendingPathComponent(".codex"))
    #expect(paths.claudeHome == root.appendingPathComponent(".claude"))
    #expect(paths.claudeKeychainService == "Claude Code-credentials")
    let login = SignInService.environment(.codex, directory: root,
        inherited: ["CODEX_APP_SERVER_LOGIN_CLIENT_ID": "fixture-other-client", "CODEX_REFRESH_TOKEN_URL_OVERRIDE": "https://example.test/token"])
    #expect(login["CODEX_APP_SERVER_LOGIN_CLIENT_ID"] == nil)
    #expect(login["CODEX_REFRESH_TOKEN_URL_OVERRIDE"] == nil)
}
