import Foundation

/// Opaque native credential document. Descriptions and reflection are always redacted.
public struct Credential: Codable, Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public let provider: Provider
    public var identity: AccountIdentity
    var document: Data
    public var expiresAt: Date?
    var refreshedAt: Date?
    public var description: String { "Credential(\(provider.rawValue), redacted)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: ["provider": provider.rawValue, "tokens": "redacted"]) }

    var object: [String: Any] { (try? JSONSerialization.jsonObject(with: document) as? [String: Any]) ?? [:] }
    var tokens: [String: Any] { object[provider == .codex ? "tokens" : "claudeAiOauth"] as? [String: Any] ?? [:] }
    var accessToken: String { tokens[provider == .codex ? "access_token" : "accessToken"] as? String ?? "" }
    var refreshToken: String { tokens[provider == .codex ? "refresh_token" : "refreshToken"] as? String ?? "" }
    var fingerprint: String { digest(document) }

    public static func parse(_ data: Data, provider: Provider, identity: AccountIdentity? = nil) throws -> Credential {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw AccError.invalidCredentials }
        if provider == .codex {
            let mode = root["auth_mode"] as? String
            if let mode, mode != "chatgpt" { throw AccError.unsupportedAuthentication }
            if mode == nil, ["OPENAI_API_KEY", "personal_access_token", "bedrock_api_key", "bedrock_access_keys"].contains(where: {
                root[$0] != nil && !(root[$0] is NSNull)
            }) { throw AccError.unsupportedAuthentication }
        }
        guard let tokens = root[provider == .codex ? "tokens" : "claudeAiOauth"] as? [String: Any],
              let access = tokens[provider == .codex ? "access_token" : "accessToken"] as? String,
              !access.isEmpty else { throw AccError.invalidCredentials }
        if provider == .codex {
            let id = jwt(tokens["id_token"] as? String ?? "")
            let claims = jwt(access)
            let auth = id["https://api.openai.com/auth"] as? [String: Any]
                ?? claims["https://api.openai.com/auth"] as? [String: Any] ?? [:]
            let profile = claims["https://api.openai.com/profile"] as? [String: Any] ?? [:]
            let accountID = tokens["account_id"] as? String ?? auth["chatgpt_account_id"] as? String
            let user = auth["chatgpt_user_id"] as? String ?? id["sub"] as? String ?? claims["sub"] as? String
            guard let accountID, !accountID.isEmpty, let user, !user.isEmpty else { throw AccError.invalidCredentials }
            let parsed = AccountIdentity(userID: user, organizationID: accountID,
                email: id["email"] as? String ?? profile["email"] as? String,
                plan: auth["chatgpt_plan_type"] as? String)
            return Credential(provider: provider, identity: parsed, document: data,
                expiresAt: (claims["exp"] as? Double).map(Date.init(timeIntervalSince1970:)),
                refreshedAt: date(root["last_refresh"] as? String))
        }
        let account = root["oauthAccount"] as? [String: Any] ?? [:]
        let parsed = identity ?? AccountIdentity(userID: account["accountUuid"] as? String ?? "",
            organizationID: account["organizationUuid"] as? String,
            email: account["emailAddress"] as? String, plan: tokens["subscriptionType"] as? String)
        return Credential(provider: provider, identity: parsed, document: data,
            expiresAt: (tokens["expiresAt"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) })
    }

    func replacingTokens(_ response: Data, now: Date) throws -> Credential {
        guard let reply = try? JSONSerialization.jsonObject(with: response) as? [String: Any],
              let access = reply["access_token"] as? String, !access.isEmpty else { throw AccError.invalidResponse }
        if provider == .codex {
            for value in [access, reply["id_token"] as? String].compactMap({ $0 }) {
                let claims = jwt(value)
                let auth = claims["https://api.openai.com/auth"] as? [String: Any] ?? [:]
                if let user = auth["chatgpt_user_id"] as? String, user != identity.userID { throw AccError.identityMismatch }
                if let account = auth["chatgpt_account_id"] as? String, account != identity.organizationID { throw AccError.identityMismatch }
            }
        }
        var root = object
        var token = tokens
        let codex = provider == .codex
        token[codex ? "access_token" : "accessToken"] = access
        if let refresh = reply["refresh_token"] as? String, !refresh.isEmpty {
            token[codex ? "refresh_token" : "refreshToken"] = refresh
        }
        if let id = reply["id_token"] as? String, !id.isEmpty { token["id_token"] = id }
        if let ttl = reply["expires_in"] as? Double, ttl > 0, !codex {
            token["expiresAt"] = now.addingTimeInterval(ttl).timeIntervalSince1970 * 1000
        }
        if codex { root["last_refresh"] = ISO8601DateFormatter().string(from: now) }
        root[codex ? "tokens" : "claudeAiOauth"] = token
        var updated = try Self.parse(JSONSerialization.data(withJSONObject: root), provider: provider, identity: identity)
        guard updated.identity.key == identity.key else { throw AccError.identityMismatch }
        if let ttl = reply["expires_in"] as? Double, ttl > 0 { updated.expiresAt = now.addingTimeInterval(ttl) }
        updated.refreshedAt = now
        return updated
    }

    func renewalDate(preferences: Preferences, lastRenewal: Date? = nil, firstObservedAt: Date? = nil) -> Date {
        let issuedAt = (jwt(accessToken)["iat"] as? Double).map(Date.init(timeIntervalSince1970:))
        let renewed = lastRenewal ?? refreshedAt ?? issuedAt
        if renewed == nil && expiresAt == nil { return .distantPast }
        var margin = provider == .codex ? preferences.codexRefreshBeforeExpirySeconds : preferences.refreshBeforeExpirySeconds
        // An unusually short-lived replacement must not stay permanently inside
        // a five-day window. Renew halfway through that shorter lifetime instead.
        if let renewed, let expiresAt, expiresAt > renewed, margin > 600,
           margin >= expiresAt.timeIntervalSince(renewed) {
            margin = min(margin, expiresAt.timeIntervalSince(renewed) / 2)
        }
        let expiryDue = expiresAt?.addingTimeInterval(-margin)
        let ageDue = (renewed ?? firstObservedAt)?.addingTimeInterval(preferences.maximumRefreshIntervalSeconds)
        return [expiryDue, ageDue].compactMap { $0 }.min() ?? .distantPast
    }

    func needsRefresh(at now: Date, leeway: TimeInterval) -> Bool {
        if let expiresAt { return expiresAt.timeIntervalSince(now) <= leeway }
        return now.timeIntervalSince(refreshedAt ?? .distantPast) > 86400
    }
}

func jwt(_ token: String) -> [String: Any] {
    let parts = token.split(separator: ".")
    guard parts.count == 3 else { return [:] }
    var payload = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
    guard let data = Data(base64Encoded: payload) else { return [:] }
    return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
}

func date(_ text: String?) -> Date? {
    guard let text else { return nil }
    let formatter = ISO8601DateFormatter()
    if let date = formatter.date(from: text) { return date }
    formatter.formatOptions.insert(.withFractionalSeconds)
    return formatter.date(from: text)
}
