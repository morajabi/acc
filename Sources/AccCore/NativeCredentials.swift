import Foundation
import Security
import LocalAuthentication
import Darwin

public struct ActiveSnapshot: Sendable {
    public var credential: Credential
    var location: String
    var fingerprint: String { credential.fingerprint }
    public init(credential: Credential, location: String = "memory") {
        self.credential = credential
        self.location = location
    }
}

public protocol ActiveCredentialStore: Sendable {
    func read(_ provider: Provider) throws -> ActiveSnapshot?
    func replace(_ credential: Credential, expected: ActiveSnapshot?) throws
    func clear(_ provider: Provider, expected: ActiveSnapshot?) throws
}

protocol KeychainAccess: Sendable {
    func read(service: String, account: String) throws -> Data?
    func write(_ data: Data, service: String, account: String) throws
    func delete(service: String, account: String) throws
}

/// Legacy Keychain APIs can ignore per-query no-UI hints. Serialize the
/// process-wide interaction policy and restore it immediately after each call.
private enum KeychainInteraction {
    static let lock = NSLock()
    static func run<T>(allowed: Bool, _ operation: () throws -> T) rethrows -> T {
        try lock.withLock {
            typealias Get = @convention(c) (UnsafeMutablePointer<DarwinBoolean>) -> OSStatus
            typealias Set = @convention(c) (DarwinBoolean) -> OSStatus
            let handle = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_LAZY)
            defer { if let handle { dlclose(handle) } }
            var previous: DarwinBoolean = true
            let getter = handle.flatMap { dlsym($0, "SecKeychainGetUserInteractionAllowed") }.map { unsafeBitCast($0, to: Get.self) }
            let setter = handle.flatMap { dlsym($0, "SecKeychainSetUserInteractionAllowed") }.map { unsafeBitCast($0, to: Set.self) }
            _ = getter?(&previous)
            _ = setter?(DarwinBoolean(allowed))
            defer { _ = setter?(previous) }
            return try operation()
        }
    }
}

struct Keychain: KeychainAccess {
    var allowInteraction = false
    func read(service: String, account: String) throws -> Data? {
        var result: CFTypeRef?
        var query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account,
            kSecMatchLimit: kSecMatchLimitOne, kSecReturnData: true,
        ]
        if !allowInteraction {
            let context = LAContext(); context.interactionNotAllowed = true
            query[kSecUseAuthenticationContext] = context
        }
        let status = KeychainInteraction.run(allowed: allowInteraction) { SecItemCopyMatching(query as CFDictionary, &result) }
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw AccError.keychain(status) }
        return data
    }
    func write(_ data: Data, service: String, account: String) throws {
        let query: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account]
        var status = KeychainInteraction.run(allowed: allowInteraction) { SecItemUpdate(query as CFDictionary, [kSecValueData: data] as CFDictionary) }
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData] = data
            item[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = KeychainInteraction.run(allowed: allowInteraction) { SecItemAdd(item as CFDictionary, nil) }
        }
        guard status == errSecSuccess else { throw AccError.keychain(status) }
    }
    func delete(service: String, account: String) throws {
        let status = KeychainInteraction.run(allowed: allowInteraction) {
            SecItemDelete([kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account] as CFDictionary)
        }
        guard status == errSecSuccess || status == errSecItemNotFound else { throw AccError.keychain(status) }
    }
}

public struct NativeCredentialStore: ActiveCredentialStore {
    public let paths: AccPaths
    private let keychain: any KeychainAccess
    public init(paths: AccPaths = AccPaths(), allowInteraction: Bool = false) {
        self.paths = paths; self.keychain = Keychain(allowInteraction: allowInteraction)
    }
    init(paths: AccPaths, keychain: any KeychainAccess) { self.paths = paths; self.keychain = keychain }
    private var codexAccount: String {
        "cli|" + digest(Data(paths.codexHome.resolvingSymlinksInPath().path.utf8)).prefix(16)
    }
    private var user: String { paths.claudeKeychainAccount }
    private func file(_ provider: Provider) -> URL {
        provider == .codex ? paths.codexHome.appendingPathComponent("auth.json") : paths.claudeCredentialsHome.appendingPathComponent(".credentials.json")
    }
    private func codexMode() throws -> String {
        let config = paths.codexHome.appendingPathComponent("config.toml")
        guard FileManager.default.fileExists(atPath: config.path) else { return "file" }
        let text = try String(contentsOf: config, encoding: .utf8)
        for line in text.components(separatedBy: .newlines) {
            let line = line.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") { break }
            let keyPattern = #"^(?:cli_auth_credentials_store|"cli_auth_credentials_store"|'cli_auth_credentials_store')\s*="#
            if line.range(of: keyPattern, options: .regularExpression) != nil {
                let regex = try NSRegularExpression(pattern: #"^(?:cli_auth_credentials_store|"cli_auth_credentials_store"|'cli_auth_credentials_store')\s*=\s*["'](file|keyring|auto)["']\s*(?:#.*)?$"#)
                let range = NSRange(line.startIndex..., in: line)
                guard let match = regex.firstMatch(in: line, range: range), let value = Range(match.range(at: 1), in: line) else {
                    throw AccError.unsupportedStorage
                }
                return String(line[value])
            }
        }
        return "file"
    }
    public func read(_ provider: Provider) throws -> ActiveSnapshot? {
        var data: Data?
        var location = "file"
        let mode = provider == .codex ? try codexMode() : "auto"
        if mode != "file" {
            do {
                data = try keychain.read(service: provider == .codex ? "Codex Auth" : paths.claudeKeychainService,
                    account: provider == .codex ? codexAccount : user)
            } catch {
                // Both CLIs can read their file fallback when Keychain is locked.
                // Keep an inaccessible, absent Claude fallback visible as an error.
                guard (provider == .codex && mode == "auto")
                    || (provider == .claude && FileManager.default.fileExists(atPath: file(provider).path)) else { throw error }
            }
            if data != nil { location = "keychain" }
        }
        if data == nil, mode != "keyring", FileManager.default.fileExists(atPath: file(provider).path) {
            try rejectSymlink(file(provider))
            data = try Data(contentsOf: file(provider))
        }
        guard let data else { return nil }
        var credential = try Credential.parse(data, provider: provider)
        if provider == .claude, credential.identity.userID.isEmpty,
           let configData = try? Data(contentsOf: paths.claudeConfig),
           let config = try? JSONSerialization.jsonObject(with: configData) as? [String: Any],
           let account = config["oauthAccount"] as? [String: Any] {
            credential.identity = AccountIdentity(userID: account["accountUuid"] as? String ?? "",
                organizationID: account["organizationUuid"] as? String, email: account["emailAddress"] as? String,
                plan: credential.identity.plan)
        }
        return ActiveSnapshot(credential: credential, location: location)
    }
    public func replace(_ credential: Credential, expected: ActiveSnapshot?) throws {
        let provider = credential.provider
        try check(provider, expected)
        let mode = provider == .codex ? try codexMode() : "auto"
        let useKeychain = expected?.location == "keychain" || (provider == .codex && mode != "file")
            || (expected == nil && mode != "file")
        // Prepare metadata before replacing credentials, so invalid config cannot
        // cause an avoidable partial switch.
        let metadata = provider == .claude ? try claudeMetadata(credential.identity) : nil
        if useKeychain {
            var wroteKeychain = false
            do {
                try keychain.write(credential.document, service: provider == .codex ? "Codex Auth" : paths.claudeKeychainService,
                    account: provider == .codex ? codexAccount : user)
                wroteKeychain = true
            } catch {
                guard provider == .codex, mode == "auto", expected?.location != "keychain" else { throw error }
                try privateWrite(credential.document, to: file(provider))
            }
            if provider == .codex, wroteKeychain, FileManager.default.fileExists(atPath: file(provider).path) {
                // Match Codex's keyring writer: do not leave an older fallback that
                // could resurface if Keychain becomes unavailable later.
                try FileManager.default.removeItem(at: file(provider))
            }
            if provider == .claude, FileManager.default.fileExists(atPath: file(provider).path) {
                try privateWrite(credential.document, to: file(provider))
            }
        } else {
            try privateWrite(credential.document, to: file(provider))
        }
        if let metadata { try privateWrite(metadata, to: paths.claudeConfig) }
    }
    private func claudeMetadata(_ identity: AccountIdentity?) throws -> Data {
        var config: [String: Any] = [:]
        if FileManager.default.fileExists(atPath: paths.claudeConfig.path) {
            try rejectSymlink(paths.claudeConfig)
            guard let parsed = try JSONSerialization.jsonObject(with: Data(contentsOf: paths.claudeConfig)) as? [String: Any] else {
                throw AccError.storage
            }
            config = parsed
        }
        if let identity {
            let previous = config["oauthAccount"] as? [String: Any] ?? [:]
            // Keep provider metadata during refresh, but never carry another
            // account's organization permissions into a switch.
            var account: [String: Any] = previous["accountUuid"] as? String == identity.userID
                && previous["organizationUuid"] as? String == identity.organizationID ? previous : [:]
            account["accountUuid"] = identity.userID
            account["organizationUuid"] = identity.organizationID
            account["emailAddress"] = identity.email
            config["oauthAccount"] = account
        } else { config.removeValue(forKey: "oauthAccount") }
        return try JSONSerialization.data(withJSONObject: config, options: [.sortedKeys])
    }
    public func clear(_ provider: Provider, expected: ActiveSnapshot?) throws {
        try check(provider, expected)
        let metadata = provider == .claude ? try claudeMetadata(nil) : nil
        let usesKeychain = provider == .claude ? true : try codexMode() != "file"
        if usesKeychain {
            try keychain.delete(service: provider == .codex ? "Codex Auth" : paths.claudeKeychainService,
                account: provider == .codex ? codexAccount : user)
        }
        if FileManager.default.fileExists(atPath: file(provider).path) { try FileManager.default.removeItem(at: file(provider)) }
        if let metadata { try privateWrite(metadata, to: paths.claudeConfig) }
    }
    private func check(_ provider: Provider, _ expected: ActiveSnapshot?) throws {
        let current = try read(provider)
        guard current?.fingerprint == expected?.fingerprint, current?.location == expected?.location else {
            throw AccError.externalChange
        }
    }
}
