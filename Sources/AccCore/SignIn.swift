import Foundation
import Darwin

public struct PendingSignIn: Codable, Sendable, Identifiable {
    public let id: UUID
    public let provider: Provider
    public let label: String?
    public let replacingID: UUID?
    public let createdAt: Date
}

/// Uses the providers' browser sign-in flows in a disposable, isolated config home.
/// It never logs CLI output or starts an inference request.
public actor SignInService {
    private let accounts: AccountService
    private var running = false
    private let inheritedEnvironment: [String: String]
    private let keychain: any KeychainAccess
    private let timeoutSeconds: TimeInterval
    public init(accounts: AccountService, environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.accounts = accounts
        self.inheritedEnvironment = environment
        self.keychain = Keychain(allowInteraction: true)
        self.timeoutSeconds = 600
    }
    init(accounts: AccountService, environment: [String: String], keychain: any KeychainAccess, timeoutSeconds: TimeInterval = 600) {
        self.accounts = accounts; self.inheritedEnvironment = environment; self.keychain = keychain; self.timeoutSeconds = timeoutSeconds
    }
    private var stagingRoot: URL { accounts.paths.root.appendingPathComponent("signins") }
    private func directory(_ id: UUID) -> URL { stagingRoot.appendingPathComponent(id.uuidString) }
    private func paths(_ pending: PendingSignIn) -> AccPaths {
        AccPaths(root: directory(pending.id), environment: Self.environment(pending.provider,
            directory: directory(pending.id), inherited: inheritedEnvironment))
    }
    public func pendingSignIns() throws -> [PendingSignIn] {
        guard FileManager.default.fileExists(atPath: stagingRoot.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: stagingRoot, includingPropertiesForKeys: nil)
            .compactMap { url in
                guard let id = UUID(uuidString: url.lastPathComponent),
                      FileManager.default.fileExists(atPath: url.appendingPathComponent("pending.json").path) else { return nil }
                let lock: VaultLock
                do { lock = try VaultLock(root: url) }
                catch AccError.busy { return nil }
                defer { withExtendedLifetime(lock) {} }
                return try pending(id)
            }.sorted { $0.createdAt < $1.createdAt }
    }
    private func pending(_ id: UUID) throws -> PendingSignIn {
        let file = directory(id).appendingPathComponent("pending.json")
        do {
            try rejectSymlink(file)
            let record = try JSONDecoder().decode(PendingSignIn.self, from: Data(contentsOf: file))
            guard record.id == id else { throw AccError.storage }
            return record
        } catch { throw AccError.storage }
    }
    /// Recover a staged login without repeating browser authentication. An
    /// interrupted intent with no credentials remains available to discard.
    @discardableResult
    public func completePending(_ id: UUID, asNew: Bool = false) async throws -> UUID {
        try Task.checkCancellation()
        let record = try pending(id)
        let lock = try VaultLock(root: directory(id)); defer { withExtendedLifetime(lock) {} }
        let saved = directory(id).appendingPathComponent("saved-login.json")
        let credential: Credential
        if FileManager.default.fileExists(atPath: saved.path) {
            try rejectSymlink(saved)
            credential = try JSONDecoder().decode(Credential.self, from: Data(contentsOf: saved))
        } else {
            guard let value = try NativeCredentialStore(paths: paths(record), keychain: keychain).read(record.provider)?.credential else {
                throw AccError.loginFailed
            }
            credential = value
            try privateWrite(JSONEncoder().encode(value), to: saved)
        }
        try Task.checkCancellation()
        let result = try await accounts.importCredential(credential, label: record.label, replacing: asNew ? nil : record.replacingID)
        try cleanup(record)
        return result
    }
    public func discardPending(_ id: UUID) throws {
        let record = try pending(id)
        let lock = try VaultLock(root: directory(id)); defer { withExtendedLifetime(lock) {} }
        try cleanup(record)
    }
    private func cleanup(_ record: PendingSignIn) throws {
        if record.provider == .claude { try keychain.delete(service: paths(record).claudeKeychainService, account: paths(record).claudeKeychainAccount) }
        try FileManager.default.removeItem(at: directory(record.id))
    }

    public static func executable(_ provider: Provider, environment: [String: String] = ProcessInfo.processInfo.environment) throws -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var directories = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        directories += [home.appendingPathComponent(".local/bin").path, home.appendingPathComponent(".bun/bin").path,
            "/opt/homebrew/bin", "/usr/local/bin", "/Applications/Codex.app/Contents/Resources"]
        guard let path = directories.filter({ $0.hasPrefix("/") }).map({ URL(fileURLWithPath: $0).appendingPathComponent(provider.rawValue) })
            .first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) else { throw AccError.executableMissing(provider) }
        return path
    }
    public static func arguments(_ provider: Provider) -> [String] {
        provider == .codex ? ["-c", "cli_auth_credentials_store=\"file\"", "login"] : ["auth", "login"]
    }
    public static func environment(_ provider: Provider, directory: URL, inherited: [String: String]) -> [String: String] {
        var env = inherited
        for key in ["OPENAI_API_KEY", "CODEX_API_KEY", "CODEX_ACCESS_TOKEN", "ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN",
                    "CLAUDE_CODE_OAUTH_TOKEN", "CLAUDE_CODE_OAUTH_TOKEN_FILE_DESCRIPTOR", "CLAUDE_CODE_USE_BEDROCK",
                    "CLAUDE_CODE_USE_VERTEX", "CLAUDE_CODE_USE_FOUNDRY", "ANTHROPIC_BASE_URL", "OPENAI_BASE_URL",
                    "CODEX_APP_SERVER_LOGIN_CLIENT_ID", "CODEX_REFRESH_TOKEN_URL_OVERRIDE"] {
            env.removeValue(forKey: key)
        }
        env[provider == .codex ? "CODEX_HOME" : "CLAUDE_CONFIG_DIR"] = directory.path
        if provider == .claude { env["CLAUDE_SECURESTORAGE_CONFIG_DIR"] = directory.path }
        return env
    }
    public func signIn(_ provider: Provider, label: String? = nil, replacing id: UUID? = nil) async throws -> UUID {
        guard !running else { throw AccError.busy }
        try Task.checkCancellation()
        let executable = try Self.executable(provider, environment: inheritedEnvironment)
        running = true
        defer { running = false }
        let record = PendingSignIn(id: UUID(), provider: provider, label: label, replacingID: id, createdAt: Date())
        try await runLogin(record, executable: executable)
        do { return try await completePending(record.id) }
        catch is CancellationError { throw CancellationError() }
        catch { throw AccError.pendingSignIn(record.id) }
    }
    private func runLogin(_ record: PendingSignIn, executable: URL) async throws {
        try privateDirectory(stagingRoot)
        let directory = directory(record.id)
        let lock = try VaultLock(root: directory)
        defer { withExtendedLifetime(lock) {} }
        var completed = false
        defer { if !completed { try? cleanup(record) } }
        // Persist the recovery route before the provider can create credentials.
        // The staging lock hides in-progress intent from other app/CLI instances.
        try privateWrite(JSONEncoder().encode(record), to: directory.appendingPathComponent("pending.json"))
        var env = Self.environment(record.provider, directory: directory, inherited: inheritedEnvironment)
        // Menu-bar apps inherit a minimal PATH; npm CLI wrappers still need node.
        env["PATH"] = ([executable.deletingLastPathComponent().path, env["PATH"] ?? "",
            "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]).joined(separator: ":")
        let process = Process()
        process.executableURL = executable
        process.arguments = Self.arguments(record.provider)
        process.environment = env
        process.currentDirectoryURL = directory
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { throw AccError.loginFailed }
        do {
            let deadline = Date().addingTimeInterval(timeoutSeconds)
            while process.isRunning {
                try Task.checkCancellation()
                guard Date() < deadline else { throw AccError.loginTimedOut }
                try await Task.sleep(for: .milliseconds(250))
            }
        } catch {
            process.terminate()
            // Do not remove the isolated store while the child may still write it.
            // Detached cleanup is deliberately not cancelled with the login task.
            await Task.detached {
                for _ in 0..<20 where process.isRunning { try? await Task.sleep(for: .milliseconds(100)) }
            }.value
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
            throw error
        }
        guard process.terminationStatus == 0 else { throw AccError.loginFailed }
        try Task.checkCancellation()
        // From this point a successful browser login survives storage, Keychain,
        // profile endpoint, or process-lock errors and can be completed later.
        completed = true
    }
}
