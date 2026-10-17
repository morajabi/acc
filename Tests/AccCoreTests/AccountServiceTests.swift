import Foundation
import Testing
@testable import AccCore

@Test func duplicateImportAndSharedWorkspaceIdentity() async throws {
    let env = TestEnvironment(); defer { env.cleanup() }
    let first = try await env.service.importCredential(codex())
    let second = try await env.service.importCredential(codex(), label: "Personal")
    #expect(first == second)
    _ = try await env.service.importCredential(codex("bob"))
    let summaries = try await env.service.accounts()
    #expect(summaries.count == 2)
    #expect(summaries[0].label == "Personal")
    let json = String(decoding: try JSONEncoder().encode(summaries), as: UTF8.self)
    #expect(!json.contains("fixture-refresh"))
    #expect(!json.contains("access_token"))
    #expect(!String(reflecting: try codex()).contains("fixture-refresh"))
}

@Test func switchesAndCapturesUnsavedOutgoingAccount() async throws {
    let env = TestEnvironment(); defer { env.cleanup() }
    env.active.set(try codex("alice"))
    let bob = try await env.service.importCredential(codex("bob"))
    try await env.service.switchAccount(bob, now: testNow)
    let accounts = try await env.service.accounts()
    #expect(accounts.count == 2)
    #expect(accounts.first { $0.id == bob }?.isActive == true)
    #expect(try env.active.read(.codex)?.credential.identity.userID == "bob")
    let alice = try #require(accounts.first { $0.identity.userID == "alice" })
    try await env.service.switchAccount(alice.id, now: testNow)
    #expect(try env.active.read(.codex)?.credential.identity.userID == "alice")
}

@Test func expiredSwitchRefreshesAndPersistsRotation() async throws {
    let env = TestEnvironment(); defer { env.cleanup() }
    let id = try await env.service.importCredential(codex(expires: testNow.addingTimeInterval(-1)))
    try await env.service.switchAccount(id, now: testNow)
    #expect(await env.client.refreshCalls == 1)
    let vault = try VaultStore(root: env.paths.root).load()
    #expect(vault.accounts[0].credential.refreshToken == "fixture-refresh-alice-1")
    #expect(try env.active.read(.codex)?.credential.refreshToken == "fixture-refresh-alice-1")
    let permissions = try FileManager.default.attributesOfItem(atPath: env.paths.root.appendingPathComponent("accounts.json").path)[.posixPermissions] as? Int
    #expect(permissions == 0o600)
}

@Test func failedPublicationRetainsRotationAndRecoversWithoutAnotherRefresh() async throws {
    let env = TestEnvironment(); defer { env.cleanup() }
    env.active.set(try codex(expires: testNow.addingTimeInterval(-1)))
    let id = try await env.service.importCurrent(.codex)
    env.active.setFailWrite(true)
    await #expect(throws: AccError.storage) { try await env.service.refresh(id, includeUsage: false, now: testNow) }
    #expect(try VaultStore(root: env.paths.root).load().accounts[0].credential.refreshToken == "fixture-refresh-alice-1")
    env.active.setFailWrite(false)
    try await env.service.refresh(id, includeUsage: false, now: testNow)
    #expect(await env.client.refreshCalls == 1)
    #expect(try env.active.read(.codex)?.credential.refreshToken == "fixture-refresh-alice-1")
}

@Test func externalSwitchDuringRefreshIsPreserved() async throws {
    let env = TestEnvironment(); defer { env.cleanup() }
    env.active.set(try codex(expires: testNow.addingTimeInterval(-1)))
    let id = try await env.service.importCurrent(.codex)
    let other = try codex("bob")
    await env.client.configure(onRefresh: { env.active.set(other) })
    await #expect(throws: AccError.externalChange) { try await env.service.refresh(id, includeUsage: false, now: testNow) }
    #expect(try env.active.read(.codex)?.credential.identity.userID == "bob")
    #expect(try VaultStore(root: env.paths.root).load().accounts[0].credential.refreshToken == "fixture-refresh-alice-1")
}

@Test func activeCLIRefreshReconcilesBeforeNetwork() async throws {
    let env = TestEnvironment(); defer { env.cleanup() }
    env.active.set(try codex(expires: testNow.addingTimeInterval(-1)))
    let id = try await env.service.importCurrent(.codex)
    env.active.set(try codex(rotation: 7))
    try await env.service.refresh(id, includeUsage: false, now: testNow)
    #expect(await env.client.refreshCalls == 0)
    #expect(try VaultStore(root: env.paths.root).load().accounts[0].credential.refreshToken == "fixture-refresh-alice-7")
}

@Test func failedUsagePreservesLastSnapshotAndBacksOff() async throws {
    let env = TestEnvironment(); defer { env.cleanup() }
    let id = try await env.service.importCredential(codex())
    try await env.service.refresh(id, now: testNow)
    await env.client.configure(usageError: .rateLimited(testNow.addingTimeInterval(900)))
    await #expect(throws: AccError.rateLimited(testNow.addingTimeInterval(900))) {
        try await env.service.refresh(id, now: testNow)
    }
    let account = try #require(try await env.service.accounts().first)
    #expect(account.usage?.fiveHour?.remainingPercent == 75)
    #expect(account.nextRetryAt == testNow.addingTimeInterval(900))
    try await env.service.maintain(now: testNow.addingTimeInterval(10))
    #expect(await env.client.usageCalls == 2)
}

@Test func invalidGrantNeedsSignInAndDoesNotLoop() async throws {
    let env = TestEnvironment(); defer { env.cleanup() }
    _ = try await env.service.importCredential(codex(expires: testNow.addingTimeInterval(-1)))
    await env.client.configure(refreshError: .signInRequired)
    try await env.service.maintain(now: testNow)
    try await env.service.maintain(now: testNow.addingTimeInterval(7200))
    #expect(await env.client.refreshCalls == 1)
    #expect(try await env.service.accounts().first?.health == .needsSignIn)
}

@Test func removeAndSignOutHaveDistinctEffects() async throws {
    let env = TestEnvironment(); defer { env.cleanup() }
    env.active.set(try codex())
    let id = try await env.service.importCurrent(.codex)
    try await env.service.remove(id)
    #expect(try env.active.read(.codex) != nil)
    try await env.service.signOut(.codex)
    #expect(try env.active.read(.codex) == nil)
    #expect(try await env.service.accounts().isEmpty)
}

@Test func reauthenticationCannotReplaceDifferentIdentity() async throws {
    let env = TestEnvironment(); defer { env.cleanup() }
    let id = try await env.service.importCredential(codex())
    await #expect(throws: AccError.identityMismatch) {
        _ = try await env.service.importCredential(codex("bob"), replacing: id)
    }
    #expect(try await env.service.accounts().count == 1)
}

@Test func disabledSettingsMakeMaintenanceOffline() async throws {
    let env = TestEnvironment(); defer { env.cleanup() }
    _ = try await env.service.importCredential(codex(expires: testNow.addingTimeInterval(-1)))
    var settings = Preferences(); settings.keepFresh = false; settings.showUsage = false
    try await env.service.setPreferences(settings)
    try await env.service.maintain(now: testNow)
    #expect(await env.client.refreshCalls == 0)
    #expect(await env.client.usageCalls == 0)
}

@Test func overlappingProcessesCannotRotateSameToken() async throws {
    let env = TestEnvironment(); defer { env.cleanup() }
    let id = try await env.service.importCredential(codex(expires: testNow.addingTimeInterval(-1)))
    await env.client.configure(pause: .milliseconds(150))
    let other = AccountService(paths: env.paths, active: env.active, client: env.client)
    let first = Task { try await env.service.refresh(id, includeUsage: false, now: testNow) }
    while await env.client.refreshCalls == 0 { await Task.yield() }
    await #expect(throws: AccError.busy) { try await other.refresh(id, includeUsage: false, now: testNow) }
    try await first.value
    #expect(await env.client.refreshCalls == 1)
}

@Test func externallyActivatedAccountRecoversFailedPublication() async throws {
    let env = TestEnvironment(); defer { env.cleanup() }
    let credential = try codex(expires: testNow.addingTimeInterval(-1))
    let id = try await env.service.importCredential(credential)
    env.active.set(credential)
    env.active.setFailWrite(true)
    await #expect(throws: AccError.storage) { try await env.service.refresh(id, includeUsage: false, now: testNow) }
    env.active.setFailWrite(false)
    try await env.service.refresh(id, includeUsage: false, now: testNow)
    #expect(await env.client.refreshCalls == 1)
    #expect(try env.active.read(.codex)?.credential.refreshToken == "fixture-refresh-alice-1")
}

@Test func maintenanceRecoversPendingPublicationWhenUsageIsDisabled() async throws {
    let env = TestEnvironment(); defer { env.cleanup() }
    env.active.set(try codex(expires: testNow.addingTimeInterval(-1)))
    let id = try await env.service.importCurrent(.codex)
    var settings = Preferences(); settings.showUsage = false
    try await env.service.setPreferences(settings)
    env.active.setFailWrite(true)
    await #expect(throws: AccError.storage) { try await env.service.refresh(id, now: testNow) }
    env.active.setFailWrite(false)
    try await env.service.maintain(now: testNow.addingTimeInterval(400))
    #expect(await env.client.refreshCalls == 1)
    #expect(try env.active.read(.codex)?.credential.refreshToken == "fixture-refresh-alice-1")
    #expect(try await env.service.accounts().first?.health == .ready)
}

@Test func inaccessibleNativeLoginDoesNotHideSavedAccounts() async throws {
    let env = TestEnvironment(); defer { env.cleanup() }
    let id = try await env.service.importCredential(codex())
    env.active.setFailRead(true)
    let account = try #require(try await env.service.accounts().first)
    #expect(account.id == id)
    #expect(account.message?.contains("Active login unavailable") == true)
    try await env.service.rename(id, label: "Still editable")
    #expect(try await env.service.accounts().first?.label == "Still editable")
}

@Test func usageBackoffDoesNotDelayExpiringToken() async throws {
    let env = TestEnvironment(); defer { env.cleanup() }
    let id = try await env.service.importCredential(codex(expires: testNow.addingTimeInterval(700)))
    await env.client.configure(usageError: .rateLimited(testNow.addingTimeInterval(3600)))
    await #expect(throws: AccError.rateLimited(testNow.addingTimeInterval(3600))) {
        try await env.service.refresh(id, now: testNow)
    }
    try await env.service.maintain(now: testNow.addingTimeInterval(400))
    #expect(await env.client.refreshCalls == 1)
    #expect(await env.client.usageCalls == 1)
    let account = try #require(try await env.service.accounts().first)
    #expect(account.nextRetryAt == testNow.addingTimeInterval(3600))
    #expect(account.message?.contains("rate limiting") == true)
}

@Test func rejectedUsageDoesNotRotateTwiceOrDisableFreshness() async throws {
    let env = TestEnvironment(); defer { env.cleanup() }
    let id = try await env.service.importCredential(codex(expires: testNow.addingTimeInterval(-1)))
    await env.client.configure(usageError: .signInRequired)
    await #expect(throws: AccError.signInRequired) { try await env.service.refresh(id, now: testNow) }
    #expect(await env.client.refreshCalls == 1)
    #expect(try await env.service.accounts().first?.health == .retrying)
    try await env.service.maintain(now: testNow.addingTimeInterval(7200))
    #expect(await env.client.refreshCalls == 2)
}

@Test func nativeReauthenticationRecoversBeforeBackoffDeadline() async throws {
    let env = TestEnvironment(); defer { env.cleanup() }
    env.active.set(try codex(expires: testNow.addingTimeInterval(-1)))
    let id = try await env.service.importCurrent(.codex)
    await env.client.configure(refreshError: .signInRequired)
    await #expect(throws: AccError.signInRequired) { try await env.service.refresh(id, now: testNow) }
    env.active.set(try codex(rotation: 8))
    try await env.service.maintain(now: testNow.addingTimeInterval(1))
    #expect(try await env.service.accounts().first?.health == .ready)
    #expect(await env.client.refreshCalls == 1)
}

@Test func addWorksWhenNativeKeychainIsUnavailable() async throws {
    let env = TestEnvironment(); defer { env.cleanup() }
    env.active.setFailRead(true)
    let id = try await env.service.importCredential(codex())
    #expect(try await env.service.accounts().first?.id == id)
}

@Test func successfulSwitchClearsAuthenticationBackoff() async throws {
    let env = TestEnvironment(); defer { env.cleanup() }
    let id = try await env.service.importCredential(codex(expires: testNow.addingTimeInterval(-1)))
    await env.client.configure(refreshError: .network)
    await #expect(throws: AccError.network) { try await env.service.refresh(id, now: testNow) }
    await env.client.configure()
    try await env.service.switchAccount(id, now: testNow)
    #expect(try await env.service.accounts().first?.nextRetryAt == nil)
    #expect(try await env.service.accounts().first?.health == .ready)
}

@Test func partialNativePublicationRetriesEvenWhenPrimaryTokensMatch() async throws {
    let env = TestEnvironment(); defer { env.cleanup() }
    env.active.set(try codex(expires: testNow.addingTimeInterval(-1)))
    let id = try await env.service.importCurrent(.codex)
    env.active.setPartialWrite(true)
    await #expect(throws: AccError.storage) { try await env.service.refresh(id, includeUsage: false, now: testNow) }
    #expect(try env.active.read(.codex)?.credential.refreshToken == "fixture-refresh-alice-1")
    #expect(try VaultStore(root: env.paths.root).load().accounts[0].pendingNativePublication == true)
    env.active.setPartialWrite(false)
    try await env.service.refresh(id, includeUsage: false, now: testNow)
    #expect(await env.client.refreshCalls == 1)
    #expect(try VaultStore(root: env.paths.root).load().accounts[0].pendingNativePublication == false)
}

@Test func discoversUnsavedLoginsWithoutWritingOrRefreshing() async throws {
    let env = TestEnvironment(); defer { env.cleanup() }
    env.active.set(try codex())
    env.active.set(try claude())
    let current = try await env.service.currentLogins()
    #expect(current.count == 2)
    #expect(current.allSatisfy { $0.identity?.userID == "alice" && $0.savedAccountID == nil })
    _ = try await env.service.currentUsage(.codex, now: testNow)
    #expect(await env.client.refreshCalls == 0)
    #expect(!FileManager.default.fileExists(atPath: env.paths.root.path))
    #expect(try await env.service.accounts().isEmpty)
}

@Test func detachLeavesNativeLoginAloneAndPausesAllMaintenance() async throws {
    let env = TestEnvironment(); defer { env.cleanup() }
    let credential = try codex(expires: testNow.addingTimeInterval(-1))
    env.active.set(credential)
    let id = try await env.service.importCurrent(.codex)
    try await env.service.setPaused(id, true)
    try await env.service.maintain(now: testNow)
    #expect(try env.active.read(.codex)?.fingerprint == credential.fingerprint)
    #expect(await env.client.refreshCalls == 0)
    #expect(await env.client.usageCalls == 0)
    env.active.set(try codex("bob"))
    try await env.service.maintain(now: testNow)
    #expect(try await env.service.accounts().first?.isActive == false)
    #expect(try await env.service.currentLogins().first?.identity?.userID == "bob")
    try await env.service.setPaused(id, false)
    try await env.service.maintain(now: testNow)
    #expect(await env.client.refreshCalls == 1)
    #expect(try env.active.read(.codex)?.credential.identity.userID == "bob")
}

@Test func switchReattachesPausedAccount() async throws {
    let env = TestEnvironment(); defer { env.cleanup() }
    let id = try await env.service.importCredential(codex())
    try await env.service.setPaused(id, true)
    try await env.service.switchAccount(id, now: testNow)
    #expect(try await env.service.accounts().first?.isPaused == false)
    #expect(try await env.service.currentLogins().first?.savedAccountID == id)
}

@Test func replacingActiveCredentialPublishesNewLoginAndKeepsRecordID() async throws {
    let env = TestEnvironment(); defer { env.cleanup() }
    env.active.set(try codex())
    let id = try await env.service.importCurrent(.codex, label: "My account")
    let file = env.root.appendingPathComponent("replacement.json")
    try privateWrite(codex(rotation: 2).document, to: file)
    let replacementID = try await env.service.importFile(file, provider: .codex, replacing: id)
    #expect(replacementID == id)
    #expect(try await env.service.accounts().first?.label == "My account")
    #expect(try env.active.read(.codex)?.credential.refreshToken == "fixture-refresh-alice-2")
    #expect(try VaultStore(root: env.paths.root).load().accounts[0].pendingNativePublication == false)
}

@Test func forceRenewRotatesHealthyTokenOnce() async throws {
    let env = TestEnvironment(); defer { env.cleanup() }
    let id = try await env.service.importCredential(codex())
    try await env.service.refresh(id, force: true, includeUsage: false, now: testNow)
    #expect(await env.client.refreshCalls == 1)
    #expect(await env.client.usageCalls == 0)
    #expect(try env.active.read(.codex) == nil)
}

@Test func reauthPublicationFailureRetainsReplacementAndRetries() async throws {
    let env = TestEnvironment(); defer { env.cleanup() }
    env.active.set(try codex())
    let id = try await env.service.importCurrent(.codex)
    env.active.setFailWrite(true)
    await #expect(throws: AccError.storage) { _ = try await env.service.importCredential(codex(rotation: 4), replacing: id) }
    env.active.setFailWrite(false)
    try await env.service.refresh(id, includeUsage: false, now: testNow)
    #expect(await env.client.refreshCalls == 0)
    #expect(try env.active.read(.codex)?.credential.refreshToken == "fixture-refresh-alice-4")
}

@Test func expiredUsageRejectionHasOneBoundedRecovery() async throws {
    let env = TestEnvironment(); defer { env.cleanup() }
    let id = try await env.service.importCredential(codex())
    await env.client.configure(usageError: .signInRequired)
    await #expect(throws: AccError.signInRequired) { try await env.service.refresh(id, now: testNow) }
    #expect(await env.client.refreshCalls == 1)
    #expect(await env.client.usageCalls == 2)
    #expect(try await env.service.accounts().first?.health == .retrying)
}

@Test func removedActiveAccountIsNotRecapturedDuringSwitch() async throws {
    let env = TestEnvironment(); defer { env.cleanup() }
    env.active.set(try codex())
    let alice = try await env.service.importCurrent(.codex)
    let bob = try await env.service.importCredential(codex("bob"))
    try await env.service.remove(alice)
    try await env.service.switchAccount(bob, now: testNow)
    #expect(try await env.service.accounts().count == 1)
    _ = try await env.service.importCredential(codex())
    #expect(try await env.service.accounts().count == 2)
}

@Test func usageCanStayEnabledWhileAutomaticRenewalIsOff() async throws {
    let env = TestEnvironment(); defer { env.cleanup() }
    _ = try await env.service.importCredential(codex(expires: testNow.addingTimeInterval(-1)))
    var preferences = Preferences(); preferences.keepFresh = false
    try await env.service.setPreferences(preferences)
    try await env.service.maintain(now: testNow)
    #expect(await env.client.refreshCalls == 0)
    #expect(await env.client.usageCalls == 1)
}
