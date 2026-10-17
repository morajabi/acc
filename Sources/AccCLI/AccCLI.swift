import Foundation
import AccCore
import Darwin

@main
struct AccCLI {
    static func main() async {
        let operation = Task { try await run(Array(CommandLine.arguments.dropFirst())) }
        // Let structured cancellation stop the isolated login child and clean up.
        signal(SIGINT, SIG_IGN); signal(SIGTERM, SIG_IGN)
        let signals = [SIGINT, SIGTERM].map { number in
            let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
            // This callback runs on a global Dispatch queue, not the main actor.
            source.setEventHandler { @Sendable in operation.cancel() }
            source.resume()
            return source
        }
        defer { signals.forEach { $0.cancel() } }
        do { try await operation.value }
        catch is CancellationError { exit(130) }
        catch {
            FileHandle.standardError.write(Data(("acc: " + safeMessage(error) + "\n").utf8))
            exit(1)
        }
    }
    static func run(_ arguments: [String]) async throws {
        var args = arguments
        let json = takeFlag("--json", from: &args)
        let root = try takeOption("--store", from: &args).map { URL(fileURLWithPath: $0) }
        let service = AccountService(paths: AccPaths(root: root))
        let command = args.first ?? "help"
        if !args.isEmpty { args.removeFirst() }
        switch command {
        case "help", "--help", "-h": print(help)
        case "version", "--version": print("acc 0.2.1")
        case "list":
            try requireEmpty(args)
            try output(await service.accounts(), json: json)
        case "current":
            let usage = takeFlag("--usage", from: &args)
            let provider = args.isEmpty ? nil : try takeProvider(from: &args)
            try requireEmpty(args)
            if usage {
                guard let provider else { throw AccError.invalidArgument("Usage: acc current <codex|claude> --usage") }
                try printJSON(await service.currentUsage(provider))
            } else {
                let logins = try await service.currentLogins(provider.map { [$0] } ?? Provider.allCases)
                if json { try printJSON(logins) }
                else { for login in logins { print("\(login.provider.title): \(login.identity?.email ?? (login.identity == nil ? "Not signed in" : "Signed in"))\(login.message.map { " · " + $0 } ?? "")") } }
            }
        case "authorize":
            let provider = try takeProvider(from: &args); try requireEmpty(args)
            try await service.authorizeKeychain(provider)
            try printJSON(await service.currentLogins([provider]))
        case "replace":
            guard !args.isEmpty else { throw AccError.invalidArgument("Usage: acc replace <id-or-name> --file <login.json>") }
            let id = try await resolve(args.removeFirst(), service)
            guard let file = try takeOption("--file", from: &args),
                  let account = try await service.accounts().first(where: { $0.id == id }) else { throw AccError.invalidArgument("Provide --file <login.json>.") }
            try requireEmpty(args)
            _ = try await service.importFile(URL(fileURLWithPath: file), provider: account.provider, replacing: id)
            try output(await service.accounts(), json: json)
        case "add", "import":
            let provider = try takeProvider(from: &args)
            let file = try takeOption("--file", from: &args)
            let label = try takeOption("--name", from: &args)
            try requireEmpty(args)
            let id: UUID
            if let file { id = try await service.importFile(URL(fileURLWithPath: file), provider: provider, label: label) }
            else { id = try await service.importCurrent(provider, label: label) }
            try output(await service.accounts().filter { $0.id == id }, json: json)
        case "login":
            let provider = try takeProvider(from: &args)
            let label = try takeOption("--name", from: &args)
            let replacing = try await takeOption("--replace", from: &args).asyncMap { try await resolve($0, service) }
            try requireEmpty(args)
            if !json { print("Complete \(provider.title) sign-in in your browser. Waiting up to ten minutes…") }
            let id = try await SignInService(accounts: service).signIn(provider, label: label, replacing: replacing)
            try output(await service.accounts().filter { $0.id == id }, json: json)
        case "pending":
            try requireEmpty(args)
            let pending = try await SignInService(accounts: service).pendingSignIns()
            if json { try printJSON(pending) }
            else {
                if pending.isEmpty { print("No sign-ins waiting to be added.") }
                for login in pending { print("\(login.id.uuidString) · \(login.provider.title) · \(login.label ?? "Ready to finish adding")") }
            }
        case "login-resume", "login-discard":
            guard !args.isEmpty, let id = UUID(uuidString: args.removeFirst()) else {
                throw AccError.invalidArgument("Provide a pending sign-in ID from acc pending.")
            }
            let asNew = command == "login-resume" ? takeFlag("--as-new", from: &args) : false
            try requireEmpty(args)
            let login = SignInService(accounts: service)
            if command == "login-resume" { _ = try await login.completePending(id, asNew: asNew) }
            else { try await login.discardPending(id) }
            try output(await service.accounts(), json: json)
        case "switch", "remove", "rename", "refresh", "usage", "detach", "resume":
            guard !args.isEmpty else { throw AccError.invalidArgument("Provide an account ID or unique name.") }
            let id = try await resolve(args.removeFirst(), service)
            let force = command == "refresh" ? takeFlag("--force", from: &args) : false
            if command == "rename" {
                guard args.count == 1 else { throw AccError.invalidArgument("Usage: acc rename <id> <name>") }
                try await service.rename(id, label: args.removeFirst())
            }
            try requireEmpty(args)
            if command == "detach" || command == "resume" { try await service.setPaused(id, command == "detach") }
            if command == "switch" { try await service.switchAccount(id) }
            if command == "remove" { try await service.remove(id) }
            if command == "refresh" || command == "usage" { try await service.refresh(id, force: force, includeUsage: command == "usage" ? true : nil) }
            try output(await service.accounts(), json: json)
        case "signout":
            let provider = try takeProvider(from: &args); try requireEmpty(args)
            try await service.signOut(provider)
            try output(await service.accounts(), json: json)
        case "maintain", "watch":
            try requireEmpty(args)
            repeat {
                do { try await service.maintain() } catch AccError.busy { }
                if command == "watch" { try await Task.sleep(for: .seconds(60)) }
            } while command == "watch"
            try output(await service.accounts(), json: json)
        case "settings":
            var preferences = try await service.preferences()
            let changing = !args.isEmpty
            if let value = try takeOption("--usage", from: &args) { preferences.showUsage = try onOff(value) }
            if let value = try takeOption("--keep-fresh", from: &args) { preferences.keepFresh = try onOff(value) }
            if let value = try takeOption("--renew-days", from: &args) { preferences.maximumRefreshIntervalSeconds = try number(value) * 86400 }
            if let value = try takeOption("--codex-lead-hours", from: &args) { preferences.codexRefreshBeforeExpirySeconds = try number(value) * 3600 }
            if let value = try takeOption("--claude-lead-minutes", from: &args) { preferences.refreshBeforeExpirySeconds = try number(value) * 60 }
            if let value = try takeOption("--retry-uncertain", from: &args) { preferences.retryUncertainRefresh = try onOff(value) }
            if let value = try takeOption("--renew-without-native", from: &args) { preferences.refreshWhenNativeUnavailable = try onOff(value) }
            try requireEmpty(args)
            if changing { try await service.setPreferences(preferences) }
            if json { try printJSON(preferences) }
            else { print("Usage: \(preferences.showUsage ? "on" : "off"); keep fresh: \(preferences.keepFresh ? "on" : "off")") }
        default: throw AccError.invalidArgument("Unknown command. Run acc help.")
        }
    }
    static func output(_ accounts: [AccountSummary], json: Bool) throws {
        if json { try printJSON(accounts); return }
        if accounts.isEmpty { print("No saved accounts. Use acc login codex or acc add claude.") }
        for account in accounts {
            print("\(account.isActive ? "●" : "○") \(account.label) · \(account.provider.title) · \(account.id.uuidString.prefix(8)) · \(account.health.rawValue)")
            if let usage = account.usage {
                for window in usage.windows {
                    let reset = window.resetsAt.map { " · resets " + $0.formatted(date: .abbreviated, time: .shortened) } ?? ""
                    print("  \(window.title): \(Int(window.remainingPercent))% remaining\(usage.isStale() || account.message != nil ? " (stale)" : "")\(reset)")
                }
                if usage.windows.isEmpty { print("  Usage windows unavailable") }
            }
            if let expiry = account.expiresAt { print("  Access token expires: \(expiry.formatted())") }
            if let refreshed = account.lastRefreshedAt { print("  Last renewed: \(refreshed.formatted())") }
            if let next = account.nextRefreshAt { print("  Next renewal: \(next.formatted())") }
            if let checked = account.lastCheckedAt { print("  Last checked: \(checked.formatted())") }
            if account.isPaused == true { print("  Detached — automatic updates paused") }
            if let message = account.message { print("  \(message)") }
        }
    }
    static func printJSON<T: Encodable>(_ value: T) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
        print(String(decoding: try encoder.encode(value), as: UTF8.self))
    }
    static func resolve(_ value: String, _ service: AccountService) async throws -> UUID {
        let accounts = try await service.accounts().filter {
            $0.id.uuidString.lowercased().hasPrefix(value.lowercased()) || $0.label == value
        }
        guard accounts.count == 1 else { throw AccError.invalidArgument("Account name or ID must match exactly one saved account.") }
        return accounts[0].id
    }
    static func takeProvider(from args: inout [String]) throws -> Provider {
        guard let first = args.first, let provider = Provider(rawValue: first) else { throw AccError.invalidArgument("Choose codex or claude.") }
        args.removeFirst(); return provider
    }
    static func takeFlag(_ flag: String, from args: inout [String]) -> Bool {
        guard let i = args.firstIndex(of: flag) else { return false }; args.remove(at: i); return true
    }
    static func takeOption(_ flag: String, from args: inout [String]) throws -> String? {
        guard let i = args.firstIndex(of: flag) else { return nil }
        guard i + 1 < args.count, !args[i + 1].hasPrefix("--") else { throw AccError.invalidArgument("Missing value for \(flag).") }
        args.remove(at: i); return args.remove(at: i)
    }
    static func requireEmpty(_ args: [String]) throws {
        guard args.isEmpty else { throw AccError.invalidArgument("Unexpected argument. Run acc help.") }
    }
    static func number(_ value: String) throws -> Double {
        guard let number = Double(value), number.isFinite else { throw AccError.invalidArgument("Enter a finite number for the renewal interval.") }
        return number
    }
    static func onOff(_ value: String) throws -> Bool {
        guard ["on", "off"].contains(value) else { throw AccError.invalidArgument("Choose on or off.") }; return value == "on"
    }
    static let help = """
    Acc 0.2 — Codex and Claude accounts

      acc list [--json]
      acc authorize <codex|claude>         Allow macOS Keychain access interactively
      acc current [codex|claude] [--json]   Read the active login without saving it
      acc current <codex|claude> --usage    Read usage without rotating credentials
      acc login <codex|claude> [--name <name>] [--replace <id>]
      acc pending [--json]            Completed browser logins waiting to be added
      acc login-resume <id> [--as-new]
      acc login-discard <id>
      acc add <codex|claude> [--file <auth.json>] [--name <name>]
      acc switch <id-or-name>
      acc replace <id-or-name> --file <login.json>
      acc detach <id-or-name>         Pause automatic work; leave provider signed in
      acc resume <id-or-name>         Resume automatic work
      acc rename <id-or-name> <new-name>
      acc remove <id-or-name>          Forget saved login; leave active login intact
      acc signout <codex|claude>       Save and clear the active local login
      acc refresh <id-or-name> [--force]
      acc usage <id-or-name> [--json]
      acc maintain                    Refresh due tokens and usage once
      acc watch                       Keep accounts fresh while this process runs
      acc settings [--usage on|off] [--keep-fresh on|off]
                   [--renew-days 5] [--codex-lead-hours 120] [--claude-lead-minutes 60]
                   [--renew-without-native on|off] [--retry-uncertain on|off]

    Global: --store <directory> (or ACC_HOME), --json (accounts, pending sign-ins, or settings).
    Switching updates local credentials. Restart an already-running provider client
    to ensure it picks up the selected account. Existing conversations are preserved.
    """
}

extension Optional where Wrapped == String {
    func asyncMap<T>(_ transform: (String) async throws -> T) async rethrows -> T? {
        guard let self else { return nil }; return try await transform(self)
    }
}
