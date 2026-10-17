import Foundation
import Testing
@testable import AccCore

@Test func isolatedSignInImportsWithoutSwitching() async throws {
    let env = TestEnvironment(); defer { env.cleanup() }
    let bin = env.root.appendingPathComponent("bin")
    try privateDirectory(bin)
    let fixture = env.root.appendingPathComponent("fixture.json")
    try privateWrite(codex("bob").document, to: fixture)
    let executable = bin.appendingPathComponent("codex")
    try Data("#!/bin/sh\n/bin/cp \"$ACC_LOGIN_FIXTURE\" \"$CODEX_HOME/auth.json\"\n".utf8).write(to: executable)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    env.active.set(try codex("alice"))
    let login = SignInService(accounts: env.service, environment: ["PATH": bin.path, "ACC_LOGIN_FIXTURE": fixture.path])
    let id = try await login.signIn(.codex)
    #expect(try await env.service.accounts().first { $0.id == id }?.identity.userID == "bob")
    #expect(try env.active.read(.codex)?.credential.identity.userID == "alice")
    let remaining = try FileManager.default.contentsOfDirectory(atPath: env.paths.root.appendingPathComponent("signins").path)
    #expect(remaining.isEmpty)
}

@Test func cancelledSignInCleansUpItsChildAndStore() async throws {
    let env = TestEnvironment(); defer { env.cleanup() }
    let bin = env.root.appendingPathComponent("bin")
    try privateDirectory(bin)
    let executable = bin.appendingPathComponent("codex")
    try Data("#!/bin/sh\nexec /bin/sleep 30\n".utf8).write(to: executable)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    let login = SignInService(accounts: env.service, environment: ["PATH": bin.path])
    let task = Task { try await login.signIn(.codex) }
    try await Task.sleep(for: .milliseconds(100))
    task.cancel()
    await #expect(throws: CancellationError.self) { _ = try await task.value }
    #expect(try await env.service.accounts().isEmpty)
    let remaining = try FileManager.default.contentsOfDirectory(atPath: env.paths.root.appendingPathComponent("signins").path)
    #expect(remaining.isEmpty)
}

@Test func completedSignInSurvivesBusyVaultAndResumesWithoutBrowser() async throws {
    let env = TestEnvironment(); defer { env.cleanup() }
    let bin = env.root.appendingPathComponent("bin")
    try privateDirectory(bin)
    let fixture = env.root.appendingPathComponent("fixture.json")
    try privateWrite(codex("bob").document, to: fixture)
    let executable = bin.appendingPathComponent("codex")
    try Data("#!/bin/sh\n/bin/cp \"$ACC_LOGIN_FIXTURE\" \"$CODEX_HOME/auth.json\"\n".utf8).write(to: executable)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    let login = SignInService(accounts: env.service, environment: ["PATH": bin.path, "ACC_LOGIN_FIXTURE": fixture.path])
    do {
        let lock = try VaultStore(root: env.paths.root).lock()
        do { _ = try await login.signIn(.codex); Issue.record("Expected a pending login") }
        catch { guard case .pendingSignIn = error as? AccError else { throw error } }
        withExtendedLifetime(lock) {}
    }
    let pending = try #require(try await login.pendingSignIns().first)
    try FileManager.default.removeItem(at: executable)
    let id = try await login.completePending(pending.id)
    #expect(try await env.service.accounts().first?.id == id)
    #expect(try await login.pendingSignIns().isEmpty)
}

@Test func isolatedClaudeSignInUsesCustomConfigAndCanDiscardPending() async throws {
    let env = TestEnvironment(); defer { env.cleanup() }
    let bin = env.root.appendingPathComponent("bin")
    try privateDirectory(bin)
    let fixture = env.root.appendingPathComponent("fixture.json")
    try privateWrite(claude("bob").document, to: fixture)
    let executable = bin.appendingPathComponent("claude")
    try Data("#!/bin/sh\n/bin/cp \"$ACC_LOGIN_FIXTURE\" \"$CLAUDE_CONFIG_DIR/.credentials.json\"\n".utf8).write(to: executable)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    let login = SignInService(accounts: env.service, environment: ["PATH": bin.path, "ACC_LOGIN_FIXTURE": fixture.path], keychain: MemoryKeychain())
    let alice = try await env.service.importCredential(claude())
    do { _ = try await login.signIn(.claude, replacing: alice); Issue.record("Expected wrong identity to stay pending") }
    catch { guard case .pendingSignIn = error as? AccError else { throw error } }
    let pending = try #require(try await login.pendingSignIns().first)
    #expect(pending.provider == .claude)
    await #expect(throws: AccError.identityMismatch) { _ = try await login.completePending(pending.id) }
    let bob = try await login.completePending(pending.id, asNew: true)
    #expect(try await env.service.accounts().first { $0.id == bob }?.identity.userID == "bob")
    #expect(try await env.service.accounts().count == 2)
}

@Test func failedProviderLoginLeavesNoPendingCredentials() async throws {
    let env = TestEnvironment(); defer { env.cleanup() }
    let bin = env.root.appendingPathComponent("bin")
    try privateDirectory(bin)
    let executable = bin.appendingPathComponent("codex")
    try Data("#!/bin/sh\nexit 1\n".utf8).write(to: executable)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    let login = SignInService(accounts: env.service, environment: ["PATH": bin.path])
    await #expect(throws: AccError.loginFailed) { _ = try await login.signIn(.codex) }
    #expect(try await login.pendingSignIns().isEmpty)
    #expect(try FileManager.default.contentsOfDirectory(atPath: env.paths.root.appendingPathComponent("signins").path).isEmpty)
}

@Test func discardingPendingDoesNotChangeSavedOrNativeAccounts() async throws {
    let env = TestEnvironment(); defer { env.cleanup() }
    let bin = env.root.appendingPathComponent("bin")
    try privateDirectory(bin)
    let fixture = env.root.appendingPathComponent("fixture.json")
    try privateWrite(codex("bob").document, to: fixture)
    let executable = bin.appendingPathComponent("codex")
    try Data("#!/bin/sh\n/bin/cp \"$ACC_LOGIN_FIXTURE\" \"$CODEX_HOME/auth.json\"\n".utf8).write(to: executable)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    env.active.set(try codex())
    let id = try await env.service.importCurrent(.codex)
    let login = SignInService(accounts: env.service, environment: ["PATH": bin.path, "ACC_LOGIN_FIXTURE": fixture.path])
    do { _ = try await login.signIn(.codex, replacing: id); Issue.record("Expected pending login") }
    catch { guard case .pendingSignIn = error as? AccError else { throw error } }
    let pending = try #require(try await login.pendingSignIns().first)
    try await login.discardPending(pending.id)
    #expect(try await login.pendingSignIns().isEmpty)
    #expect(try await env.service.accounts().count == 1)
    #expect(try env.active.read(.codex)?.credential.identity.userID == "alice")
}

@Test func timedOutSignInStopsChildAndRemovesStore() async throws {
    let env = TestEnvironment(); defer { env.cleanup() }
    let bin = env.root.appendingPathComponent("bin")
    try privateDirectory(bin)
    let executable = bin.appendingPathComponent("codex")
    try Data("#!/bin/sh\nexec /bin/sleep 30\n".utf8).write(to: executable)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    let login = SignInService(accounts: env.service, environment: ["PATH": bin.path], keychain: MemoryKeychain(), timeoutSeconds: 0.01)
    await #expect(throws: AccError.loginTimedOut) { _ = try await login.signIn(.codex) }
    #expect(try await login.pendingSignIns().isEmpty)
    #expect(try FileManager.default.contentsOfDirectory(atPath: env.paths.root.appendingPathComponent("signins").path).isEmpty)
}
