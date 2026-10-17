import Foundation

public struct HTTPResponse: Sendable {
    public var data: Data
    public var status: Int
    public var headers: [String: String]
    public init(data: Data, status: Int = 200, headers: [String: String] = [:]) {
        self.data = data; self.status = status; self.headers = headers
    }
}
public protocol HTTPTransport: Sendable { func send(_ request: URLRequest) async throws -> HTTPResponse }

private final class RedirectPolicy: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

public struct URLSessionTransport: HTTPTransport {
    private let session: URLSession
    public init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 45
        session = URLSession(configuration: configuration, delegate: RedirectPolicy(), delegateQueue: nil)
    }
    public func send(_ request: URLRequest) async throws -> HTTPResponse {
        do {
            let (data, response) = try await session.data(for: request)
            guard let response = response as? HTTPURLResponse else { throw AccError.invalidResponse }
            var headers: [String: String] = [:]
            for (key, value) in response.allHeaderFields { headers[String(describing: key).lowercased()] = String(describing: value) }
            return HTTPResponse(data: data, status: response.statusCode, headers: headers)
        } catch is CancellationError { throw CancellationError() }
        catch let error as URLError where error.code == .cancelled { throw CancellationError() }
        catch let error as URLError where [.notConnectedToInternet, .cannotFindHost, .dnsLookupFailed, .cannotConnectToHost].contains(error.code) {
            throw AccError.requestNotSent
        }
        catch let error as AccError { throw error }
        catch { throw AccError.network }
    }
}

public protocol ProviderClient: Sendable {
    func refresh(_ credential: Credential, now: Date) async throws -> Credential
    func usage(_ credential: Credential, now: Date) async throws -> UsageSnapshot
    func identify(_ credential: Credential) async throws -> Credential
}

public struct OAuthProviderClient: ProviderClient {
    let transport: any HTTPTransport
    public init(transport: any HTTPTransport = URLSessionTransport()) { self.transport = transport }
    public func refresh(_ credential: Credential, now: Date) async throws -> Credential {
        guard !credential.refreshToken.isEmpty else { throw AccError.signInRequired }
        let codex = credential.provider == .codex
        var request = URLRequest(url: URL(string: codex ? "https://auth.openai.com/oauth/token" : "https://platform.claude.com/v1/oauth/token")!)
        request.httpMethod = "POST"
        let fields = ["grant_type": "refresh_token", "refresh_token": credential.refreshToken,
            "client_id": codex ? "app_EMoamEEZ73f0CkXaXp7hrann" : "9d1c250a-e61b-44d9-88ed-5944d1962f5e"]
        if codex {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: fields)
        } else {
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
            request.httpBody = Data(fields.sorted { $0.key < $1.key }.map {
                $0.key + "=" + $0.value.addingPercentEncoding(withAllowedCharacters: allowed)!
            }.joined(separator: "&").utf8)
        }
        let response: HTTPResponse
        do { response = try await transport.send(request) }
        catch AccError.requestNotSent { throw AccError.network }
        catch { throw AccError.refreshUncertain }
        // A timeout/lost response, gateway failure, or malformed success does
        // not prove the refresh token is still usable. Never silently replay it.
        if response.status >= 500 { throw AccError.refreshUncertain }
        try validate(response, refreshing: true, now: now)
        do { return try credential.replacingTokens(response.data, now: now) }
        catch { throw AccError.refreshUncertain }
    }
    public func identify(_ credential: Credential) async throws -> Credential {
        guard credential.provider == .claude else { return credential }
        let response = try await transport.send(request(credential, url: "https://api.anthropic.com/api/oauth/profile"))
        try validate(response, now: Date())
        guard let root = try? JSONSerialization.jsonObject(with: response.data) as? [String: Any] else { throw AccError.invalidResponse }
        let account = root["account"] as? [String: Any] ?? root
        let org = root["organization"] as? [String: Any] ?? [:]
        guard let id = account["uuid"] as? String ?? account["account_uuid"] as? String ?? root["accountUuid"] as? String, !id.isEmpty else { throw AccError.invalidResponse }
        var result = credential
        result.identity = AccountIdentity(userID: id, organizationID: org["uuid"] as? String ?? root["organizationUuid"] as? String ?? root["organization_uuid"] as? String,
            email: account["email"] as? String ?? account["email_address"] as? String ?? account["emailAddress"] as? String,
            plan: credential.identity.plan)
        return result
    }
    public func usage(_ credential: Credential, now: Date) async throws -> UsageSnapshot {
        let url = credential.provider == .codex ? "https://chatgpt.com/backend-api/wham/usage" : "https://api.anthropic.com/api/oauth/usage"
        let response = try await transport.send(request(credential, url: url))
        try validate(response, now: now)
        return try UsageParser.parse(response.data, provider: credential.provider, now: now)
    }
    private func request(_ credential: Credential, url: String) -> URLRequest {
        var request = URLRequest(url: URL(string: url)!)
        request.setValue("Bearer \(credential.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Acc/0.1", forHTTPHeaderField: "User-Agent")
        if credential.provider == .codex {
            request.setValue(credential.identity.organizationID, forHTTPHeaderField: "ChatGPT-Account-Id")
        } else {
            request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
            // Match the provider CLI convention used by the OAuth usage endpoint.
            request.setValue("claude-code/2.1.0", forHTTPHeaderField: "User-Agent")
        }
        return request
    }
    private func validate(_ response: HTTPResponse, refreshing: Bool = false, now: Date) throws {
        if (200..<300).contains(response.status) { return }
        if response.status == 401 { throw AccError.signInRequired }
        if refreshing,
           let json = try? JSONSerialization.jsonObject(with: response.data) as? [String: Any] {
            let code = json["error"] as? String ?? (json["error"] as? [String: Any])?["code"] as? String ?? json["code"] as? String
            if ["invalid_grant", "refresh_token_expired", "refresh_token_reused", "refresh_token_invalidated"].contains(code?.lowercased()) {
                throw AccError.signInRequired
            }
        }
        if response.status == 429 {
            var retryAt = now.addingTimeInterval(300)
            if let value = response.headers["retry-after"] {
                if let seconds = TimeInterval(value), seconds.isFinite, seconds >= 0 { retryAt = now.addingTimeInterval(seconds) }
                else {
                    let formatter = DateFormatter()
                    formatter.locale = Locale(identifier: "en_US_POSIX")
                    formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
                    retryAt = formatter.date(from: value) ?? retryAt
                }
            }
            throw AccError.rateLimited(max(now.addingTimeInterval(30), retryAt))
        }
        throw AccError.http(response.status)
    }
}

public enum UsageParser {
    public static func parse(_ data: Data, provider: Provider, now: Date = Date()) throws -> UsageSnapshot {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw AccError.invalidResponse }
        var windows: [UsageWindow] = []
        if provider == .codex {
            func append(_ limit: [String: Any], prefix: String = "", title: String? = nil, optional: Bool = false) throws {
                for name in ["primary_window", "secondary_window"] {
                    guard let raw = limit[name], !(raw is NSNull) else { continue }
                    guard let w = raw as? [String: Any], let used = w["used_percent"] as? Double, used.isFinite, used >= 0 else {
                        if optional { continue }
                        throw AccError.invalidResponse
                    }
                    let duration = w["limit_window_seconds"] as? Int
                    let id = duration == 18000 ? "fiveHour" : duration == 604800 ? "weekly" : name
                    let label = duration == 18000 ? "5 hours" : duration == 604800 ? "Weekly" : "Usage window"
                    let reset = (w["reset_at"] as? Double).map(Date.init(timeIntervalSince1970:))
                        ?? (w["reset_after_seconds"] as? Double).map { now.addingTimeInterval($0) }
                    windows.append(UsageWindow(id: prefix + id, title: title.map { $0 + " · " + label } ?? label,
                        usedPercent: used, resetsAt: reset, durationSeconds: duration))
                }
            }
            if let limit = root["rate_limit"] as? [String: Any] { try append(limit) }
            for (i, extra) in ((root["additional_rate_limits"] as? [[String: Any]]) ?? []).enumerated() {
                if let limit = extra["rate_limit"] as? [String: Any] {
                    try append(limit, prefix: "extra\(i).", title: extra["limit_name"] as? String ?? "Additional", optional: true)
                }
            }
        } else {
            let keys = [("five_hour", "fiveHour", "5 hours", 18000), ("seven_day", "weekly", "Weekly", 604800),
                ("seven_day_sonnet", "sonnet", "Sonnet weekly", 604800), ("seven_day_opus", "opus", "Opus weekly", 604800),
                ("seven_day_oauth_apps", "oauthApps", "OAuth apps weekly", 604800)]
            for (key, id, title, duration) in keys {
                guard let raw = root[key], !(raw is NSNull) else { continue }
                guard let w = raw as? [String: Any], let used = w["utilization"] as? Double, used.isFinite, used >= 0 else {
                    throw AccError.invalidResponse
                }
                windows.append(UsageWindow(id: id, title: title, usedPercent: used,
                    resetsAt: date(w["resets_at"] as? String), durationSeconds: duration))
            }
            // CodexBar's newer Claude mapping treats scoped weekly windows as
            // additive, including entries marked is_active=false by the provider.
            for limit in root["limits"] as? [[String: Any]] ?? [] {
                guard limit["kind"] as? String == "weekly_scoped", limit["group"] as? String == "weekly",
                      let used = limit["percent"] as? Double, used.isFinite, used >= 0,
                      let scope = limit["scope"] as? [String: Any], let model = scope["model"] as? [String: Any],
                      let name = model["display_name"] as? String, !name.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
                let modelID = (model["id"] as? String ?? name).lowercased()
                guard name.lowercased() != "all models", !modelID.hasSuffix("all-models") else { continue }
                let id = "scoped." + modelID
                guard !windows.contains(where: { $0.id == id }) else { continue }
                if ["sonnet", "opus"].contains(modelID) { windows.removeAll { $0.id == modelID } }
                windows.append(UsageWindow(id: id, title: name + " weekly", usedPercent: used,
                    resetsAt: date(limit["resets_at"] as? String), durationSeconds: 604800))
            }
        }
        var seen: Set<String> = []
        windows = windows.filter { seen.insert($0.id).inserted }
        return UsageSnapshot(windows: windows, fetchedAt: now, plan: root["plan_type"] as? String)
    }
}
