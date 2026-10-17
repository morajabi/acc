import Foundation
import Testing
@testable import AccCore

@Test func passedResetInvalidatesMeasurementWithoutInventingAnAllowance() {
    let snapshot = usageSnapshot()
    #expect(!snapshot.isStale(at: testNow.addingTimeInterval(299)))
    #expect(snapshot.isStale(at: testNow.addingTimeInterval(300)))
    #expect(snapshot.needsRefresh(at: testNow.addingTimeInterval(300), interval: 600))
    #expect(snapshot.fiveHour?.remainingPercent == 75)
    var checked = snapshot
    checked.fetchedAt = testNow.addingTimeInterval(301)
    // If the provider still reports an old reset date, do not spin requests.
    #expect(!checked.needsRefresh(at: testNow.addingTimeInterval(302), interval: 300))
}

@Test func usageRetryRunsAtItsDeadlineInsteadOfWaitingForThePollInterval() async throws {
    let env = TestEnvironment(); defer { env.cleanup() }
    _ = try await env.service.importCredential(codex())
    await env.client.configure(usageError: .network)
    try await env.service.maintain(now: testNow)
    await env.client.configure()
    try await env.service.maintain(now: testNow.addingTimeInterval(59))
    #expect(await env.client.usageCalls == 1)
    try await env.service.maintain(now: testNow.addingTimeInterval(60))
    #expect(await env.client.usageCalls == 2)
    #expect(try await env.service.accounts()[0].usageMessage == nil)
}

@Test func activeUsageUpdatesBeforeInactiveAccounts() async throws {
    let env = TestEnvironment(); defer { env.cleanup() }
    env.active.set(try codex())
    _ = try await env.service.importCurrent(.codex)
    _ = try await env.service.importCredential(codex("bob"))
    try await env.service.maintain(now: testNow)
    #expect(await env.client.usageCalls == 2)
    try await env.service.maintain(now: testNow.addingTimeInterval(120))
    #expect(await env.client.usageCalls == 3)
    let accounts = try await env.service.accounts()
    #expect(accounts.first { $0.isActive }?.usage?.fetchedAt == testNow.addingTimeInterval(120))
    #expect(accounts.first { !$0.isActive }?.usage?.fetchedAt == testNow)
}

@Test func activeAccountIsCheckedBeforeAnEarlierSavedAlternate() async throws {
    let env = TestEnvironment(); defer { env.cleanup() }
    _ = try await env.service.importCredential(codex("bob"))
    env.active.set(try codex())
    _ = try await env.service.importCurrent(.codex)
    try await env.service.maintain(now: testNow)
    #expect(await env.client.usageAccounts == ["alice", "bob"])
}

@Test func foregroundUsageHasAThirtySecondMinimumAndTargetsTheSelectedProvider() async throws {
    let env = TestEnvironment(); defer { env.cleanup() }
    _ = try await env.service.importCredential(codex())
    _ = try await env.service.importCredential(claude())
    try await env.service.maintain(now: testNow)
    try await env.service.maintain(now: testNow.addingTimeInterval(29), foregroundUsageInterval: 0, foregroundUsageProvider: .claude)
    #expect(await env.client.usageCalls == 2)
    try await env.service.maintain(now: testNow.addingTimeInterval(30), foregroundUsageInterval: 0, foregroundUsageProvider: .claude)
    #expect(await env.client.usageCalls == 3)
    let accounts = try await env.service.accounts()
    #expect(accounts.first { $0.provider == .claude }?.usage?.fetchedAt == testNow.addingTimeInterval(30))
    #expect(accounts.first { $0.provider == .codex }?.usage?.fetchedAt == testNow)
}

@Test func foregroundAndConnectivityChecksRespectUsageRateLimits() async throws {
    let env = TestEnvironment(); defer { env.cleanup() }
    _ = try await env.service.importCredential(codex())
    await env.client.configure(usageError: .rateLimited(testNow.addingTimeInterval(600)))
    try await env.service.maintain(now: testNow)
    await env.client.configure()
    try await env.service.maintain(now: testNow.addingTimeInterval(40), connectivityRestored: true, foregroundUsageInterval: 30)
    #expect(await env.client.usageCalls == 1)
    try await env.service.maintain(now: testNow.addingTimeInterval(600))
    #expect(await env.client.usageCalls == 2)
}

@Test func restoredConnectivityRetriesOfflineUsageImmediately() async throws {
    let env = TestEnvironment(); defer { env.cleanup() }
    _ = try await env.service.importCredential(codex())
    await env.client.configure(usageError: .requestNotSent)
    try await env.service.maintain(now: testNow)
    await env.client.configure()
    try await env.service.maintain(now: testNow.addingTimeInterval(1), connectivityRestored: true)
    #expect(await env.client.usageCalls == 2)
}

@Test func renewalBackoffDoesNotBlockUsageOrGetClearedByUsageSuccess() async throws {
    let env = TestEnvironment(); defer { env.cleanup() }
    _ = try await env.service.importCredential(codex(expires: testNow.addingTimeInterval(30 * 86400)))
    let renewalDue = testNow.addingTimeInterval(5 * 86400)
    await env.client.configure(refreshError: .network)
    try await env.service.maintain(now: renewalDue)
    #expect(await env.client.refreshCalls == 1)
    #expect(await env.client.usageCalls == 0)
    try await env.service.maintain(now: renewalDue.addingTimeInterval(1))
    #expect(await env.client.refreshCalls == 1)
    #expect(await env.client.usageCalls == 1)
    let account = try #require(try await env.service.accounts().first)
    #expect(account.renewalHealth == .retrying)
    #expect(account.nextRenewalRetryAt == renewalDue.addingTimeInterval(60))
    #expect(account.usage?.fetchedAt == renewalDue.addingTimeInterval(1))
}

@Test func detachedAccountsStayDetachedDuringForegroundUsageChecks() async throws {
    let env = TestEnvironment(); defer { env.cleanup() }
    env.active.set(try codex())
    let id = try await env.service.importCurrent(.codex)
    try await env.service.setPaused(id, true)
    try await env.service.maintain(now: testNow.addingTimeInterval(8000), foregroundUsageInterval: 30)
    #expect(await env.client.refreshCalls == 0)
    #expect(await env.client.usageCalls == 0)
}

@Test func usageRateLimitDuringRenewalBackoffIsStillRecorded() async throws {
    let env = TestEnvironment(); defer { env.cleanup() }
    _ = try await env.service.importCredential(codex(expires: testNow.addingTimeInterval(30 * 86400)))
    let due = testNow.addingTimeInterval(5 * 86400)
    await env.client.configure(refreshError: .network)
    try await env.service.maintain(now: due)
    await env.client.configure(refreshError: .network, usageError: .rateLimited(due.addingTimeInterval(600)))
    try await env.service.maintain(now: due.addingTimeInterval(1))
    try await env.service.maintain(now: due.addingTimeInterval(30), foregroundUsageInterval: 30)
    #expect(await env.client.usageCalls == 1)
    let account = try #require(try await env.service.accounts().first)
    #expect(account.renewalHealth == .retrying)
    #expect(account.usageMessage?.contains("rate limiting") == true)
}

@Test func claudeDefaultMigratesOnceAndKeepsLaterExplicitChoices() throws {
    #expect(Preferences().refreshBeforeExpirySeconds == 3600)
    let legacy = try JSONDecoder().decode(Preferences.self, from: object(["refreshBeforeExpirySeconds": 600]))
    #expect(legacy.refreshBeforeExpirySeconds == 3600)
    let custom = try JSONDecoder().decode(Preferences.self, from: object(["refreshBeforeExpirySeconds": 1800]))
    #expect(custom.refreshBeforeExpirySeconds == 1800)
    var explicit = Preferences()
    explicit.refreshBeforeExpirySeconds = 600
    let reloaded = try JSONDecoder().decode(Preferences.self, from: JSONEncoder().encode(explicit))
    #expect(reloaded.refreshBeforeExpirySeconds == 600)
}
