import Foundation
import Testing
@testable import AccCore

@Test func defaultsAndOlderVaultPreferencesMigrateWithoutResettingChoices() throws {
    let preferences = try JSONDecoder().decode(Preferences.self, from: object([
        "keepFresh": false, "showUsage": false, "usageIntervalSeconds": 900, "refreshBeforeExpirySeconds": 1800]))
    #expect(!preferences.keepFresh && !preferences.showUsage)
    #expect(preferences.usageIntervalSeconds == 900)
    #expect(preferences.refreshBeforeExpirySeconds == 1800)
    #expect(preferences.codexRefreshBeforeExpirySeconds == 120 * 3600)
    #expect(preferences.maximumRefreshIntervalSeconds == 5 * 86400)
    #expect(preferences.refreshWhenNativeUnavailable)
    #expect(Preferences().keepFresh)
}

@Test func codexRenewsBeforeNativeEightDayAndFiveMinuteThresholds() throws {
    let preferences = Preferences()
    let long = try codex(expires: testNow.addingTimeInterval(30 * 86400))
    #expect(long.renewalDate(preferences: preferences) == testNow.addingTimeInterval(5 * 86400))
    let nineDays = try codex(expires: testNow.addingTimeInterval(9 * 86400))
    #expect(nineDays.renewalDate(preferences: preferences) == testNow.addingTimeInterval(4 * 86400))
    let short = try codex(expires: testNow.addingTimeInterval(7200))
    #expect(short.renewalDate(preferences: preferences) == testNow.addingTimeInterval(3600))
    #expect(try claude().renewalDate(preferences: preferences) == testNow.addingTimeInterval(3600))
}

@Test func maximumAgeRenewsInactiveAccountsWithUsageDisabledAndPersistsHistory() async throws {
    let env = TestEnvironment(); defer { env.cleanup() }
    var preferences = Preferences(); preferences.showUsage = false
    try await env.service.setPreferences(preferences)
    let id = try await env.service.importCredential(codex(expires: testNow.addingTimeInterval(30 * 86400)))
    try await env.service.maintain(now: testNow.addingTimeInterval(5 * 86400 - 1))
    #expect(await env.client.refreshCalls == 0)
    let due = testNow.addingTimeInterval(5 * 86400)
    try await env.service.maintain(now: due)
    #expect(await env.client.refreshCalls == 1)
    #expect(await env.client.usageCalls == 0)
    let restarted = AccountService(paths: env.paths, active: env.active, client: env.client)
    let summary = try #require(try await restarted.accounts().first)
    #expect(summary.id == id)
    #expect(summary.lastCheckedAt == due)
    #expect(summary.lastRefreshAttemptAt == due)
    #expect(summary.lastRefreshedAt == due)
    #expect(summary.nextRefreshAt == due.addingTimeInterval(3600))
    #expect(summary.refreshHistory?.last?.outcome == "renewed")
    try await restarted.maintain(now: due.addingTimeInterval(60))
    #expect(await env.client.refreshCalls == 1)
}

@Test func lockedNativeStoreDoesNotPreventRenewalAndLaterPublication() async throws {
    let env = TestEnvironment(); defer { env.cleanup() }
    env.active.set(try codex(expires: testNow.addingTimeInterval(-1)))
    _ = try await env.service.importCurrent(.codex)
    env.active.setFailRead(true)
    try await env.service.maintain(now: testNow)
    #expect(await env.client.refreshCalls == 1)
    #expect(try VaultStore(root: env.paths.root).load().accounts[0].pendingNativePublication == true)
    env.active.setFailRead(false)
    try await env.service.maintain(now: testNow.addingTimeInterval(60))
    #expect(await env.client.refreshCalls == 1)
    #expect(try env.active.read(.codex)?.credential.refreshToken == "fixture-refresh-alice-1")
}

@Test func strictNativeAvailabilityIsAnExplicitPreference() async throws {
    let env = TestEnvironment(); defer { env.cleanup() }
    _ = try await env.service.importCredential(codex(expires: testNow.addingTimeInterval(-1)))
    var preferences = Preferences(); preferences.refreshWhenNativeUnavailable = false
    try await env.service.setPreferences(preferences)
    env.active.setFailRead(true)
    try await env.service.maintain(now: testNow)
    #expect(await env.client.refreshCalls == 0)
    #expect(try await env.service.accounts()[0].renewalHealth == .retrying)
}

@Test func networkRecoveryRetriesImmediatelyButPreservesRateLimits() async throws {
    let env = TestEnvironment(); defer { env.cleanup() }
    _ = try await env.service.importCredential(codex(expires: testNow.addingTimeInterval(-1)))
    await env.client.configure(refreshError: .network)
    try await env.service.maintain(now: testNow)
    await env.client.configure()
    try await env.service.maintain(now: testNow.addingTimeInterval(1))
    #expect(await env.client.refreshCalls == 1)
    try await env.service.maintain(now: testNow.addingTimeInterval(2), connectivityRestored: true)
    #expect(await env.client.refreshCalls == 2)
    await env.client.configure(refreshError: .rateLimited(testNow.addingTimeInterval(10000)))
    try await env.service.maintain(now: testNow.addingTimeInterval(8000))
    try await env.service.maintain(now: testNow.addingTimeInterval(8001), connectivityRestored: true)
    #expect(await env.client.refreshCalls == 3)
}

@Test func cancellationAfterExchangeStartsStillSavesAndPublishesRotation() async throws {
    let env = TestEnvironment(); defer { env.cleanup() }
    env.active.set(try codex(expires: testNow.addingTimeInterval(-1)))
    let id = try await env.service.importCurrent(.codex)
    await env.client.configure(pause: .milliseconds(150))
    let operation = Task { try await env.service.refresh(id, includeUsage: false, now: testNow) }
    while await env.client.refreshCalls == 0 { try await Task.sleep(for: .milliseconds(5)) }
    operation.cancel()
    try await operation.value
    #expect(try env.active.read(.codex)?.credential.refreshToken == "fixture-refresh-alice-1")
    #expect(try VaultStore(root: env.paths.root).load().accounts[0].lastRefreshedAt == testNow)
}

@Test func journalRecoversInterruptedVaultSaveWithoutRepeatingExchange() async throws {
    let env = TestEnvironment(); defer { env.cleanup() }
    env.active.set(try codex(expires: testNow.addingTimeInterval(-1)))
    let id = try await env.service.importCurrent(.codex)
    let store = VaultStore(root: env.paths.root)
    let saved = try Data(contentsOf: store.file)
    await env.client.configure(onRefresh: {
        try? FileManager.default.removeItem(at: store.file)
        try? FileManager.default.createDirectory(at: store.file, withIntermediateDirectories: false)
    })
    await #expect(throws: AccError.storage) { try await env.service.refresh(id, includeUsage: false, now: testNow) }
    try FileManager.default.removeItem(at: store.file)
    try saved.write(to: store.file)
    await env.client.configure()
    let restarted = AccountService(paths: env.paths, active: env.active, client: env.client)
    try await restarted.maintain(now: testNow.addingTimeInterval(60))
    #expect(await env.client.refreshCalls == 1)
    #expect(try env.active.read(.codex)?.credential.refreshToken == "fixture-refresh-alice-1")
    #expect(try await restarted.accounts()[0].refreshHistory?.last?.outcome == "recovered")
}

@Test func recoveryCopyFailureStillAttemptsPrimaryVaultSave() async throws {
    let env = TestEnvironment(); defer { env.cleanup() }
    let id = try await env.service.importCredential(codex(expires: testNow.addingTimeInterval(-1)))
    // A fault confined to the recovery directory must not throw away a response.
    let directory = env.paths.root.appendingPathComponent("rotations")
    await env.client.configure(onRefresh: { try? Data().write(to: directory) })
    try await env.service.refresh(id, includeUsage: false, now: testNow)
    try FileManager.default.removeItem(at: directory)
    // Primary vault write completed despite the recovery-directory error.
    #expect(try VaultStore(root: env.paths.root).load().accounts[0].credential.refreshToken == "fixture-refresh-alice-1")
}

@Test func persistentPublicationFailureDoesNotStarveLaterRenewals() async throws {
    let env = TestEnvironment(); defer { env.cleanup() }
    env.active.set(try codex(expires: testNow.addingTimeInterval(-1)))
    _ = try await env.service.importCurrent(.codex)
    env.active.setFailWrite(true)
    try await env.service.maintain(now: testNow)
    try await env.service.maintain(now: testNow.addingTimeInterval(7200))
    #expect(await env.client.refreshCalls == 2)
    env.active.setFailWrite(false)
    try await env.service.maintain(now: testNow.addingTimeInterval(7400))
    #expect(try env.active.read(.codex)?.credential.refreshToken == "fixture-refresh-alice-2")
}

@Test func maintenanceFailureForOneAccountDoesNotStarveAnother() async throws {
    let env = TestEnvironment(); defer { env.cleanup() }
    _ = try await env.service.importCredential(codex(expires: testNow.addingTimeInterval(-1)))
    _ = try await env.service.importCredential(codex("bob", expires: testNow.addingTimeInterval(-1)))
    await env.client.configure(refreshError: .network)
    try await env.service.maintain(now: testNow)
    #expect(await env.client.refreshCalls == 2)
    let accounts = try await env.service.accounts()
    #expect(accounts.allSatisfy { $0.lastRefreshAttemptAt == testNow && $0.nextRetryAt != nil })
}

@Test func refreshHistoryIsBoundedAndContainsNoCredentials() async throws {
    let env = TestEnvironment(); defer { env.cleanup() }
    let id = try await env.service.importCredential(codex())
    await env.client.configure(refreshError: .network)
    for second in 0..<25 {
        await #expect(throws: AccError.network) { try await env.service.refresh(id, force: true, includeUsage: false, now: testNow.addingTimeInterval(Double(second))) }
    }
    let accounts = try await env.service.accounts()
    #expect(accounts[0].refreshHistory?.count == 20)
    let json = String(decoding: try JSONEncoder().encode(accounts), as: UTF8.self)
    #expect(!json.contains("fixture-refresh"))
    #expect(!json.contains("access_token"))
}

private struct FailingTransport: HTTPTransport {
    let error: AccError
    func send(_ request: URLRequest) async throws -> HTTPResponse { throw error }
}

@Test func lostRefreshResponseIsNotAReusableOldTokenBackup() async throws {
    let env = TestEnvironment(); defer { env.cleanup() }
    let transport = QueueTransport([]) // request recorded, response lost
    let service = AccountService(paths: env.paths, active: env.active, client: OAuthProviderClient(transport: transport))
    _ = try await service.importCredential(codex(expires: testNow.addingTimeInterval(-1)))
    try await service.maintain(now: testNow)
    let account = try #require(try await service.accounts().first)
    #expect(account.renewalHealth == .uncertain)
    #expect(account.nextRefreshAt == nil)
    #expect(account.refreshHistory?.last?.outcome == "unknown")
    for offset in [3600.0, 86400, 864000] {
        try await service.maintain(now: testNow.addingTimeInterval(offset), connectivityRestored: true)
    }
    #expect(await transport.requests.count == 1)
}

@Test func preconnectionFailureCanRetryButLostResponseCannot() async throws {
    let credential = try codex()
    await #expect(throws: AccError.network) {
        _ = try await OAuthProviderClient(transport: FailingTransport(error: .requestNotSent)).refresh(credential, now: testNow)
    }
    await #expect(throws: AccError.refreshUncertain) {
        _ = try await OAuthProviderClient(transport: FailingTransport(error: .network)).refresh(credential, now: testNow)
    }
    for status in [500, 502, 503] {
        let transport = QueueTransport([HTTPResponse(data: Data(), status: status)])
        await #expect(throws: AccError.refreshUncertain) {
            _ = try await OAuthProviderClient(transport: transport).refresh(credential, now: testNow)
        }
    }
}

@Test func crashDuringRefreshDoesNotReplayTheOldTokenOnRestart() async throws {
    let env = TestEnvironment(); defer { env.cleanup() }
    _ = try await env.service.importCredential(codex(expires: testNow.addingTimeInterval(-1)))
    let store = VaultStore(root: env.paths.root)
    var vault = try store.load()
    vault.accounts[0].refreshInFlight = true
    vault.accounts[0].lastRefreshAttemptAt = testNow
    try store.save(vault)
    let restarted = AccountService(paths: env.paths, active: env.active, client: env.client)
    try await restarted.maintain(now: testNow.addingTimeInterval(600))
    #expect(await env.client.refreshCalls == 0)
    #expect(try await restarted.accounts()[0].renewalHealth == .uncertain)
    env.active.set(try codex(rotation: 12))
    try await restarted.maintain(now: testNow.addingTimeInterval(601))
    #expect(try await restarted.accounts()[0].renewalHealth == .ready)
    #expect(await env.client.refreshCalls == 0)
}

@Test func explicitUnknownOutcomeRetryPreferenceIsRequiredForReplay() async throws {
    let env = TestEnvironment(); defer { env.cleanup() }
    _ = try await env.service.importCredential(codex(expires: testNow.addingTimeInterval(-1)))
    await env.client.configure(refreshError: .refreshUncertain)
    try await env.service.maintain(now: testNow)
    try await env.service.maintain(now: testNow.addingTimeInterval(500))
    #expect(await env.client.refreshCalls == 1)
    var preferences = Preferences(); preferences.retryUncertainRefresh = true
    try await env.service.setPreferences(preferences)
    await env.client.configure()
    try await env.service.maintain(now: testNow.addingTimeInterval(501))
    #expect(await env.client.refreshCalls == 2)
    #expect(try await env.service.accounts()[0].renewalHealth == .ready)
}

@Test func successfulRotationRecoveryTakesPrecedenceOverInterruptedAttemptMarker() async throws {
    let env = TestEnvironment(); defer { env.cleanup() }
    let original = try codex(expires: testNow.addingTimeInterval(-1))
    let id = try await env.service.importCredential(original)
    let store = VaultStore(root: env.paths.root)
    var vault = try store.load(); vault.accounts[0].refreshInFlight = true
    try store.save(vault)
    try store.saveRotation(accountID: id, previous: original.fingerprint, credential: codex(rotation: 1), at: testNow)
    try await env.service.maintain(now: testNow.addingTimeInterval(60))
    #expect(await env.client.refreshCalls == 0)
    #expect(try await env.service.accounts()[0].renewalHealth == .ready)
    #expect(try VaultStore(root: env.paths.root).load().accounts[0].refreshInFlight == false)
}

@Test func oldFileReimportAndMetadataEditsCannotClearUnknownOutcome() async throws {
    let env = TestEnvironment(); defer { env.cleanup() }
    let original = try codex(expires: testNow.addingTimeInterval(-1))
    let id = try await env.service.importCredential(original)
    await env.client.configure(refreshError: .refreshUncertain)
    try await env.service.maintain(now: testNow)
    _ = try await env.service.importCredential(original, replacing: id)
    var document = original.object; document["unrelated_metadata"] = true
    env.active.set(try Credential.parse(object(document), provider: .codex))
    try await env.service.maintain(now: testNow.addingTimeInterval(86400))
    #expect(await env.client.refreshCalls == 1)
    #expect(try await env.service.accounts()[0].renewalHealth == .uncertain)
    #expect(try await env.service.accounts()[0].nextRenewalRetryAt == nil)
}

@Test func localFailureCannotDowngradeAnUnknownOutcomeIntoAutomaticRetry() async throws {
    let env = TestEnvironment(); defer { env.cleanup() }
    _ = try await env.service.importCredential(codex(expires: testNow.addingTimeInterval(-1)))
    await env.client.configure(refreshError: .refreshUncertain)
    try await env.service.maintain(now: testNow)
    var preferences = Preferences(); preferences.refreshWhenNativeUnavailable = false
    try await env.service.setPreferences(preferences)
    env.active.setFailRead(true)
    try await env.service.maintain(now: testNow.addingTimeInterval(600))
    env.active.setFailRead(false)
    try await env.service.maintain(now: testNow.addingTimeInterval(7200))
    #expect(await env.client.refreshCalls == 1)
    #expect(try await env.service.accounts()[0].renewalHealth == .uncertain)
}

@Test func unknownIssueDateStillHasMaximumAgeFromFirstObservation() throws {
    var credential = try claude()
    credential.expiresAt = testNow.addingTimeInterval(30 * 86400)
    #expect(credential.renewalDate(preferences: Preferences(), firstObservedAt: testNow) == testNow.addingTimeInterval(5 * 86400))
    credential.expiresAt = nil
    #expect(credential.renewalDate(preferences: Preferences(), firstObservedAt: testNow) == .distantPast)
}
