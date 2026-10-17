import Foundation
import Testing
@testable import AccCore

@Test func codexWindowsAreClassifiedByDuration() throws {
    let data = try object(["plan_type": "plus", "rate_limit": [
        "primary_window": ["used_percent": 20, "limit_window_seconds": 604800, "reset_at": 1_800_010_000],
        "secondary_window": ["used_percent": 110, "limit_window_seconds": 18000, "reset_after_seconds": 60]]])
    let result = try UsageParser.parse(data, provider: .codex, now: testNow)
    #expect(result.weekly?.remainingPercent == 80)
    #expect(result.fiveHour?.remainingPercent == 0)
    #expect(result.fiveHour?.resetsAt == testNow.addingTimeInterval(60))
}

@Test func missingWindowsStayUnavailable() throws {
    let result = try UsageParser.parse(object(["rate_limit": ["primary_window": NSNull()]]), provider: .codex, now: testNow)
    #expect(result.fiveHour == nil)
    #expect(result.weekly == nil)
    #expect(result.windows.isEmpty)
    #expect(throws: AccError.invalidResponse) {
        try UsageParser.parse(object(["five_hour": ["utilization": "bad"]]), provider: .claude)
    }
}

@Test func claudeFractionalResetsAndModelWindows() throws {
    let result = try UsageParser.parse(object([
        "five_hour": ["utilization": 12.5, "resets_at": "2027-01-15T12:00:00.123Z"],
        "seven_day": ["utilization": 100, "resets_at": NSNull()],
        "seven_day_sonnet": ["utilization": 30], "seven_day_opus": NSNull(),
    ]), provider: .claude, now: testNow)
    #expect(result.windows.count == 3)
    #expect(result.fiveHour?.remainingPercent == 87.5)
    #expect(result.fiveHour?.resetsAt != nil)
    #expect(result.weekly?.remainingPercent == 0)
    #expect(result.isStale(at: testNow.addingTimeInterval(601)))
}

@Test func refreshPreservesUnknownFieldsAndMissingOptionalTokens() async throws {
    let original = try codex()
    let newAccess = try token(["sub": "alice", "exp": testNow.addingTimeInterval(3600).timeIntervalSince1970])
    let transport = QueueTransport([HTTPResponse(data: try object(["access_token": newAccess, "expires_in": 3600]))])
    let result = try await OAuthProviderClient(transport: transport).refresh(original, now: testNow)
    #expect(result.refreshToken == original.refreshToken)
    #expect(result.tokens["id_token"] as? String == original.tokens["id_token"] as? String)
    #expect((result.object["future_field"] as? [String: Bool])?["preserved"] == true)
    #expect(result.expiresAt == testNow.addingTimeInterval(3600))
    let request = try #require(await transport.requests.first)
    #expect(request.url?.host == "auth.openai.com")
    #expect(request.httpMethod == "POST")
}

@Test func claudeRefreshUsesFormEncoding() async throws {
    let original = try claude()
    let transport = QueueTransport([HTTPResponse(data: try object(["access_token": "fixture-next", "refresh_token": "fixture-next-refresh", "expires_in": 7200]))])
    let result = try await OAuthProviderClient(transport: transport).refresh(original, now: testNow)
    #expect(result.refreshToken == "fixture-next-refresh")
    let request = try #require(await transport.requests.first)
    #expect(request.url?.host == "platform.claude.com")
    #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/x-www-form-urlencoded")
    #expect(String(decoding: request.httpBody!, as: UTF8.self).contains("grant_type=refresh_token"))
}

@Test func invalidGrantIsSanitizedAndNeverRetriedByTransport() async throws {
    let transport = QueueTransport([HTTPResponse(data: try object(["error": "invalid_grant", "message": "fixture-secret-echo"]), status: 400)])
    await #expect(throws: AccError.signInRequired) {
        _ = try await OAuthProviderClient(transport: transport).refresh(codex(), now: testNow)
    }
    #expect(await transport.requests.count == 1)
    #expect(!AccError.signInRequired.localizedDescription.contains("fixture-secret"))
}

@Test func rateLimitHonorsRetryAfter() async throws {
    let transport = QueueTransport([HTTPResponse(data: Data(), status: 429, headers: ["retry-after": "900"])])
    await #expect(throws: AccError.rateLimited(testNow.addingTimeInterval(900))) {
        _ = try await OAuthProviderClient(transport: transport).usage(claude(), now: testNow)
    }
}

@Test func usageUsesAccountHeaderAndBetaHeader() async throws {
    let transport = QueueTransport([HTTPResponse(data: try object([:])), HTTPResponse(data: try object([:]))])
    let client = OAuthProviderClient(transport: transport)
    _ = try await client.usage(codex(), now: testNow)
    _ = try await client.usage(claude(), now: testNow)
    let requests = await transport.requests
    #expect(requests[0].value(forHTTPHeaderField: "ChatGPT-Account-Id") == "personal")
    #expect(requests[1].value(forHTTPHeaderField: "anthropic-beta") == "oauth-2025-04-20")
}

@Test func malformedRefreshDoesNotReuseOldAccessTokenAsSuccess() async throws {
    let transport = QueueTransport([HTTPResponse(data: try object(["expires_in": 7200]))])
    await #expect(throws: AccError.refreshUncertain) {
        _ = try await OAuthProviderClient(transport: transport).refresh(codex(), now: testNow)
    }
}

@Test func scopedClaudeWindowsAreAdditiveAndDeduplicated() throws {
    let scoped: [String: Any] = ["kind": "weekly_scoped", "group": "weekly", "percent": 31,
        "is_active": false, "scope": ["model": ["id": "test-model", "display_name": "Test model"]]]
    let result = try UsageParser.parse(object([
        "five_hour": ["utilization": 20], "seven_day": ["utilization": 42], "limits": [scoped, scoped],
    ]), provider: .claude, now: testNow)
    #expect(result.windows.count == 3)
    #expect(result.windows.last?.remainingPercent == 69)
    #expect(result.weekly?.remainingPercent == 58)
}

@Test func malformedCodexExtraWindowsDoNotHidePrimaryLimits() throws {
    let result = try UsageParser.parse(object([
        "rate_limit": ["primary_window": ["used_percent": 20, "limit_window_seconds": 18000]],
        "additional_rate_limits": [["limit_name": "Optional", "rate_limit": ["primary_window": ["used_percent": "bad"]]]],
    ]), provider: .codex, now: testNow)
    #expect(result.fiveHour?.remainingPercent == 80)
    #expect(result.windows.count == 1)
}

@Test func claudeProfileAcceptsNestedAndCamelCaseShapes() async throws {
    for profile in [
        ["account": ["uuid": "verified", "email_address": "verified@example.test"], "organization": ["uuid": "workspace"]],
        ["accountUuid": "verified", "emailAddress": "verified@example.test", "organizationUuid": "workspace"],
    ] as [[String: Any]] {
        let transport = QueueTransport([HTTPResponse(data: try object(profile))])
        let identified = try await OAuthProviderClient(transport: transport).identify(claude())
        #expect(identified.identity.userID == "verified")
        #expect(identified.identity.organizationID == "workspace")
        #expect(identified.identity.email == "verified@example.test")
    }
}

@Test func httpFailuresAndInvalidIdentityAreSanitized() async throws {
    for status in [403, 500, 503] {
        let transport = QueueTransport([HTTPResponse(data: Data("fixture-secret-echo".utf8), status: status)])
        await #expect(throws: AccError.http(status)) { _ = try await OAuthProviderClient(transport: transport).usage(codex(), now: testNow) }
        #expect(await transport.requests.count == 1)
    }
    let transport = QueueTransport([HTTPResponse(data: try object(["access_token": token([
        "https://api.openai.com/auth": ["chatgpt_user_id": "wrong-user"]])]))])
    await #expect(throws: AccError.refreshUncertain) { _ = try await OAuthProviderClient(transport: transport).refresh(codex(), now: testNow) }
}

@Test func codexExternalAndAPIAuthenticationAreNotMisidentifiedAsSubscriptions() throws {
    var doc = try codex().object
    for mode in ["apikey", "chatgptAuthTokens", "agentIdentity", "personalAccessToken"] {
        doc["auth_mode"] = mode
        #expect(throws: AccError.unsupportedAuthentication) { _ = try Credential.parse(object(doc), provider: .codex) }
    }
    doc.removeValue(forKey: "auth_mode")
    doc["OPENAI_API_KEY"] = "fixture-api-key"
    #expect(throws: AccError.unsupportedAuthentication) { _ = try Credential.parse(object(doc), provider: .codex) }
    doc["OPENAI_API_KEY"] = NSNull()
    #expect(try Credential.parse(object(doc), provider: .codex).identity.userID == "alice")
}
