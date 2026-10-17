import Foundation
import CryptoKit
import Darwin

func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

public struct AccPaths: Sendable {
    public var root: URL
    public var codexHome: URL
    public var claudeHome: URL
    public var claudeCredentialsHome: URL
    public var claudeConfig: URL
    public var claudeKeychainService: String
    public var claudeKeychainAccount: String
    public init(root: URL? = nil, home: URL? = nil,
                environment: [String: String] = ProcessInfo.processInfo.environment) {
        let home = home ?? environment["HOME"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser
        self.root = root ?? environment["ACC_HOME"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
            ?? home.appendingPathComponent("Library/Application Support/Acc")
        codexHome = environment["CODEX_HOME"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
            ?? home.appendingPathComponent(".codex")
        let custom = environment["CLAUDE_CONFIG_DIR"].flatMap { $0.isEmpty ? nil : $0 }
        claudeHome = custom.map { URL(fileURLWithPath: $0) } ?? home.appendingPathComponent(".claude")
        if let secureRoot = environment["CLAUDE_SECURESTORAGE_CONFIG_DIR"] {
            claudeCredentialsHome = secureRoot.isEmpty ? home.appendingPathComponent(".claude") : URL(fileURLWithPath: secureRoot)
        } else { claudeCredentialsHome = claudeHome }
        let legacyConfig = claudeHome.appendingPathComponent(".config.json")
        claudeConfig = FileManager.default.fileExists(atPath: legacyConfig.path) ? legacyConfig
            : custom == nil ? home.appendingPathComponent(".claude.json") : claudeHome.appendingPathComponent(".claude.json")
        claudeKeychainService = Self.claudeService(configDirectory: custom,
            secureStorageDirectory: environment["CLAUDE_SECURESTORAGE_CONFIG_DIR"])
        claudeKeychainAccount = environment["USER"].flatMap { $0.isEmpty ? nil : $0 } ?? NSUserName()
    }
    public static func claudeService(configDirectory: String?, secureStorageDirectory: String? = nil) -> String {
        // Claude's explicit secure-storage override wins, including an empty
        // value selecting the default store. It hashes the NFC-normalized path.
        let directory = secureStorageDirectory ?? configDirectory
        guard let directory, !directory.isEmpty else { return "Claude Code-credentials" }
        return "Claude Code-credentials-" + digest(Data(directory.precomposedStringWithCanonicalMapping.utf8)).prefix(8)
    }
}

struct VaultStore: Sendable {
    let root: URL
    var file: URL { root.appendingPathComponent("accounts.json") }
    private var rotations: URL { root.appendingPathComponent("rotations") }
    func lock() throws -> VaultLock { try VaultLock(root: root) }
    func load() throws -> Vault {
        guard FileManager.default.fileExists(atPath: file.path) else { return Vault() }
        do {
            try rejectSymlink(file)
            var vault = try JSONDecoder().decode(Vault.self, from: Data(contentsOf: file))
            guard vault.version == 1 else { throw AccError.storage }
            for rotation in try pendingRotations() {
                guard let i = vault.accounts.firstIndex(where: { $0.id == rotation.accountID }),
                      vault.accounts[i].credential.fingerprint == rotation.previous else { continue }
                vault.accounts[i].credential = rotation.credential
                vault.accounts[i].lastRefreshedAt = rotation.date
                vault.accounts[i].pendingNativePublication = vault.accounts[i].nativeFingerprint != nil
                vault.accounts[i].refreshInFlight = false
                vault.accounts[i].health = .ready
                vault.accounts[i].message = nil
                vault.accounts[i].nextRetryAt = nil
                var events = vault.accounts[i].refreshHistory ?? []
                events.append(RefreshEvent(date: rotation.date, outcome: "recovered", message: "Recovered a saved token renewal."))
                vault.accounts[i].refreshHistory = Array(events.suffix(20))
            }
            return vault
        } catch { throw AccError.storage }
    }
    func save(_ vault: Vault) throws {
        try privateWrite(JSONEncoder().encode(vault), to: file)
        // Only remove recovery material after the complete vault is durable.
        for rotation in (try? pendingRotations()) ?? [] {
            let record = vault.accounts.first { $0.id == rotation.accountID }
            if record == nil || record?.credential.fingerprint == rotation.credential.fingerprint {
                try? FileManager.default.removeItem(at: rotations.appendingPathComponent(rotation.accountID.uuidString + ".json"))
            }
        }
    }
    func saveRotation(accountID: UUID, previous: String, credential: Credential, at date: Date) throws {
        try privateDirectory(rotations)
        let rotation = RotationRecovery(accountID: accountID, previous: previous, credential: credential, date: date)
        try privateWrite(JSONEncoder().encode(rotation), to: rotations.appendingPathComponent(accountID.uuidString + ".json"))
    }
    private func pendingRotations() throws -> [RotationRecovery] {
        guard FileManager.default.fileExists(atPath: rotations.path) else { return [] }
        try rejectSymlink(rotations)
        return try FileManager.default.contentsOfDirectory(at: rotations, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }.map {
                try rejectSymlink($0)
                return try JSONDecoder().decode(RotationRecovery.self, from: Data(contentsOf: $0))
            }
    }
}

private struct RotationRecovery: Codable {
    let accountID: UUID
    let previous: String
    let credential: Credential
    let date: Date
}

final class VaultLock: Sendable {
    let fd: Int32
    init(root: URL) throws {
        try privateDirectory(root)
        let path = root.appendingPathComponent(".lock").path
        fd = open(path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw AccError.storage }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { close(fd); throw AccError.busy }
    }
    deinit { flock(fd, LOCK_UN); close(fd) }
}

func rejectSymlink(_ url: URL) throws {
    var info = stat()
    if lstat(url.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFLNK { throw AccError.storage }
}
func privateDirectory(_ url: URL) throws {
    try rejectSymlink(url)
    do {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard chmod(url.path, 0o700) == 0 else { throw AccError.storage }
    } catch { throw AccError.storage }
}

/// Same-directory replacement; never leaves a half-written credential document.
func privateWrite(_ data: Data, to url: URL) throws {
    try rejectSymlink(url)
    let parent = url.deletingLastPathComponent()
    if !FileManager.default.fileExists(atPath: parent.path) { try privateDirectory(parent) }
    let temporary = parent.appendingPathComponent(".acc-" + UUID().uuidString)
    let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
    guard fd >= 0 else { throw AccError.storage }
    defer { close(fd); unlink(temporary.path) }
    try data.withUnsafeBytes { bytes in
        var offset = 0
        while offset < bytes.count {
            let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { throw AccError.storage }
            offset += count
        }
    }
    guard fsync(fd) == 0, rename(temporary.path, url.path) == 0 else { throw AccError.storage }
    // Persist the replacement directory entry, not only the file contents.
    let parentFD = open(parent.path, O_RDONLY)
    if parentFD >= 0 { _ = fsync(parentFD); close(parentFD) }
}
