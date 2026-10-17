import Foundation

/// Shared by the app and CLI. The actor guards in-process work; a short-lived file
/// lock also coordinates independent Acc processes, including across network awaits.
public actor AccountService {
    public let paths: AccPaths
    private let store: VaultStore
    private let active: any ActiveCredentialStore
    private let client: any ProviderClient
    public init(paths: AccPaths = AccPaths(), active: (any ActiveCredentialStore)? = nil,
                client: any ProviderClient = OAuthProviderClient()) {
        self.paths = paths
        store = VaultStore(root: paths.root)
        self.active = active ?? NativeCredentialStore(paths: paths)
        self.client = client
    }
    public func preferences() throws -> Preferences { try store.load().preferences }
    public func setPreferences(_ preferences: Preferences) throws {
        guard preferences.usageIntervalSeconds.isFinite, preferences.usageIntervalSeconds >= 60,
              preferences.refreshBeforeExpirySeconds.isFinite, (60...3600).contains(preferences.refreshBeforeExpirySeconds),
              preferences.codexRefreshBeforeExpirySeconds.isFinite, (600...604800).contains(preferences.codexRefreshBeforeExpirySeconds),
              preferences.maximumRefreshIntervalSeconds.isFinite, (3600...2592000).contains(preferences.maximumRefreshIntervalSeconds) else {
            throw AccError.invalidArgument("Choose valid renewal and usage intervals.")
        }
        let lock = try store.lock(); defer { withExtendedLifetime(lock) {} }
        var vault = try store.load(); vault.preferences = preferences; try store.save(vault)
    }
    public func accounts() throws -> [AccountSummary] {
        let vault = try store.load()
        var current: [Provider: ActiveSnapshot] = [:]
        var activeErrors: [Provider: String] = [:]
        for provider in Set(vault.accounts.map { $0.credential.provider }) {
            do { current[provider] = try readActive(provider, in: vault) }
            catch { activeErrors[provider] = "Active login unavailable. " + safeMessage(error) }
        }
        return vault.accounts.map { record in
            let credential = record.credential
            var summary = AccountSummary(id: record.id, provider: credential.provider, label: record.label,
                identity: credential.identity, expiresAt: credential.expiresAt,
                isActive: current[credential.provider].map { matches(credential, $0.credential) } ?? false,
                health: activeErrors[credential.provider] == nil && record.usageMessage == nil ? record.health
                    : [.needsSignIn, .uncertain].contains(record.health) ? record.health : .retrying,
                message: record.message ?? activeErrors[credential.provider] ?? record.syncMessage ?? record.usageMessage, usage: record.usage,
                nextRetryAt: [record.nextRetryAt, record.usageRetryAt].compactMap { $0 }.min(), isPaused: record.isPaused)
            summary.nextRenewalRetryAt = record.nextRetryAt
            summary.lastCheckedAt = record.lastCheckedAt
            summary.lastRefreshAttemptAt = record.lastRefreshAttemptAt
            summary.lastRefreshedAt = record.lastRefreshedAt ?? credential.refreshedAt
            summary.renewalHealth = record.health
            summary.refreshHistory = record.refreshHistory
            if vault.preferences.keepFresh, record.isPaused != true, record.health != .needsSignIn, record.health != .uncertain || vault.preferences.retryUncertainRefresh {
                summary.nextRefreshAt = max(record.renewalDate(vault.preferences), record.nextRetryAt ?? .distantPast)
            }
            return summary
        }
    }
    public func currentLogins(_ providers: [Provider] = Provider.allCases) throws -> [CurrentLogin] {
        let vault = try store.load()
        return providers.map { provider in
            do {
                let native = try readActive(provider, in: vault)
                return CurrentLogin(provider: provider, identity: native?.credential.identity,
                    expiresAt: native?.credential.expiresAt,
                    savedAccountID: native.flatMap { snapshot in vault.accounts.first { matches($0.credential, snapshot.credential) }?.id },
                    revision: native?.fingerprint)
            } catch {
                let needsAccess: Bool
                if case .keychain = error as? AccError { needsAccess = true } else { needsAccess = false }
                return CurrentLogin(provider: provider, message: safeMessage(error), requiresKeychainAccess: needsAccess)
            }
        }
    }
    /// An explicit foreground action; passive discovery never opens a permission dialog.
    public func authorizeKeychain(_ provider: Provider) throws {
        _ = try NativeCredentialStore(paths: paths, allowInteraction: true).read(provider)
    }
    /// Observes an unsaved login without rotating or retaining its credentials.
    public func currentUsage(_ provider: Provider, now: Date = Date()) async throws -> UsageSnapshot {
        guard let before = try active.read(provider) else { throw AccError.invalidCredentials }
        let usage = try await client.usage(before.credential, now: now)
        guard try active.read(provider)?.fingerprint == before.fingerprint else { throw AccError.externalChange }
        return usage
    }
    /// Leaves the native login intact and pauses all automatic work on this saved copy.
    public func setPaused(_ id: UUID, _ paused: Bool) throws {
        let lock = try store.lock(); defer { withExtendedLifetime(lock) {} }
        var vault = try store.load(); let i = try index(id, in: vault)
        vault.accounts[i].isPaused = paused
        try store.save(vault)
    }
    @discardableResult
    public func importFile(_ file: URL, provider: Provider, label: String? = nil, replacing id: UUID? = nil) async throws -> UUID {
        let data: Data
        do { data = try Data(contentsOf: file) } catch { throw AccError.invalidCredentials }
        return try await importCredential(Credential.parse(data, provider: provider), label: label, replacing: id)
    }
    @discardableResult
    public func importCurrent(_ provider: Provider, label: String? = nil) async throws -> UUID {
        guard let snapshot = try active.read(provider) else { throw AccError.invalidCredentials }
        return try await importCredential(snapshot.credential, label: label)
    }
    @discardableResult
    public func importCredential(_ input: Credential, label: String? = nil, replacing id: UUID? = nil) async throws -> UUID {
        let lock = try store.lock(); defer { withExtendedLifetime(lock) {} }
        var vault = try store.load()
        var credential = input
        if credential.provider == .claude, credential.identity.userID.isEmpty { credential = try await client.identify(credential) }
        guard !credential.identity.userID.isEmpty else { throw AccError.invalidCredentials }
        vault.forgottenIdentities?.removeAll { $0 == credential.provider.rawValue + "|" + credential.identity.key }
        let index = vault.accounts.firstIndex { $0.credential.provider == credential.provider && $0.credential.identity.key == credential.identity.key }
        if let id {
            guard let record = vault.accounts.first(where: { $0.id == id }) else { throw AccError.missingAccount }
            guard record.credential.provider == credential.provider, record.credential.identity.key == credential.identity.key else {
                throw AccError.identityMismatch
            }
        }
        // Adding an inactive login must work even while the native Keychain is unavailable.
        let native = try? readActive(credential.provider, in: vault)
        let wasActive = native.map { matches(credential, $0.credential) } ?? false
        let result: UUID
        if let index {
            let unchangedUncertainToken = (vault.accounts[index].health == .uncertain || vault.accounts[index].refreshInFlight == true)
                && credential.refreshToken == vault.accounts[index].credential.refreshToken
            // Reimporting an old JSON copy cannot turn a consumed/unknown token
            // back into a healthy session. Only genuinely new credentials can.
            if unchangedUncertainToken {
                if let label, !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { vault.accounts[index].label = label }
                try recoverInterruptedAttempt(index, vault: &vault, now: Date())
                try store.save(vault)
                return vault.accounts[index].id
            }
            // Importing an old copy must not replace a newer saved rotation.
            if let oldDate = vault.accounts[index].credential.refreshedAt, let newDate = credential.refreshedAt,
               oldDate > newDate { throw AccError.externalChange }
            vault.accounts[index].credential = credential
            vault.accounts[index].lastRefreshedAt = credential.refreshedAt
            vault.accounts[index].pendingNativePublication = false
            vault.accounts[index].refreshInFlight = false
            if let label, !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { vault.accounts[index].label = label }
            vault.accounts[index].isPaused = false
            clearFailure(index, vault: &vault)
            clearUsageFailure(index, vault: &vault)
            vault.accounts[index].nativeFingerprint = wasActive ? native?.fingerprint : nil
            result = vault.accounts[index].id
        } else {
            var record = AccountRecord(label: normalizedLabel(label, credential), credential: credential)
            record.nativeFingerprint = wasActive ? native?.fingerprint : nil
            vault.accounts.append(record)
            result = record.id
        }
        try store.save(vault)
        // A re-login of the active account publishes the new session immediately.
        if id != nil, wasActive, let i = vault.accounts.firstIndex(where: { $0.id == result }) {
            vault.accounts[i].pendingNativePublication = true
            try store.save(vault)
            try active.replace(credential, expected: native)
            vault.accounts[i].pendingNativePublication = false
            vault.accounts[i].nativeFingerprint = credential.fingerprint
            try store.save(vault)
        }
        return result
    }
    public func rename(_ id: UUID, label: String) throws {
        let label = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty else { throw AccError.invalidArgument("Enter an account name.") }
        let lock = try store.lock(); defer { withExtendedLifetime(lock) {} }
        var vault = try store.load(); let i = try index(id, in: vault)
        vault.accounts[i].label = label; try store.save(vault)
    }
    /// Forgets Acc's saved login. The provider's current login is left signed in.
    public func remove(_ id: UUID) throws {
        let lock = try store.lock(); defer { withExtendedLifetime(lock) {} }
        var vault = try store.load(); let i = try index(id, in: vault)
        let credential = vault.accounts[i].credential
        let key = credential.provider.rawValue + "|" + credential.identity.key
        if !(vault.forgottenIdentities ?? []).contains(key) { vault.forgottenIdentities = (vault.forgottenIdentities ?? []) + [key] }
        vault.accounts.remove(at: i); try store.save(vault)
    }
    public func signOut(_ provider: Provider) async throws {
        let lock = try store.lock(); defer { withExtendedLifetime(lock) {} }
        var vault = try store.load()
        let snapshot = try readActive(provider, in: vault)
        if let snapshot { try await capture(snapshot, in: &vault) }
        try store.save(vault)
        try active.clear(provider, expected: snapshot)
    }
    public func switchAccount(_ id: UUID, now: Date = Date()) async throws {
        let lock = try store.lock(); defer { withExtendedLifetime(lock) {} }
        var vault = try store.load(); let i = try index(id, in: vault)
        let provider = vault.accounts[i].credential.provider
        let before = try readActive(provider, in: vault)
        if let before { try await capture(before, in: &vault) }
        try store.save(vault)
        do {
            _ = try await refreshRecord(i, vault: &vault, now: now, force: false, native: before)
            vault.accounts[i].pendingNativePublication = true
            try store.save(vault)
            try active.replace(vault.accounts[i].credential, expected: try activeSnapshotAfterRefresh(before, record: vault.accounts[i]))
            vault.accounts[i].nativeFingerprint = vault.accounts[i].credential.fingerprint
            vault.accounts[i].pendingNativePublication = false
            vault.accounts[i].isPaused = false
            clearFailure(i, vault: &vault)
            try store.save(vault)
        } catch {
            recordFailure(error, at: i, vault: &vault, now: now); try store.save(vault); throw error
        }
    }
    private func activeSnapshotAfterRefresh(_ before: ActiveSnapshot?, record: AccountRecord) throws -> ActiveSnapshot? {
        let after = try active.read(record.credential.provider)
        // refreshRecord may have published this account, but an external switch must be preserved.
        if before?.fingerprint == after?.fingerprint { return after }
        if let before, matches(record.credential, before.credential), after?.fingerprint == record.credential.fingerprint { return after }
        throw AccError.externalChange
    }
    /// Explicit refresh also retries a previous error. Force rotates even a healthy token.
    public func refresh(_ id: UUID, force: Bool = false, includeUsage: Bool? = nil, now: Date = Date()) async throws {
        let lock = try store.lock(); defer { withExtendedLifetime(lock) {} }
        var vault = try store.load(); let i = try index(id, in: vault)
        try await update(i, vault: &vault, now: now, force: force, includeUsage: includeUsage ?? vault.preferences.showUsage)
    }
    /// One maintenance pass. Suitable for a menu-bar timer or a CLI scheduler.
    public func maintain(now: Date = Date(), connectivityRestored: Bool = false) async throws {
        let lock = try store.lock(); defer { withExtendedLifetime(lock) {} }
        var vault = try store.load()
        for i in vault.accounts.indices {
            try Task.checkCancellation()
            if vault.accounts[i].isPaused == true { continue }
            // Reconcile before retry deadlines: a new CLI login can recover immediately.
            do {
                vault.accounts[i].lastCheckedAt = now
                try recoverInterruptedAttempt(i, vault: &vault, now: now)
                let native = try maintenanceNative(i, vault: &vault)
                try reconcile(i, native: native, vault: &vault)
                if vault.accounts[i].health == .needsSignIn { continue }
                if vault.accounts[i].health == .uncertain && !vault.preferences.retryUncertainRefresh { continue }
                if connectivityRestored, vault.accounts[i].retryOnConnectivity == true { vault.accounts[i].nextRetryAt = nil }
                guard vault.accounts[i].nextRetryAt.map({ $0 <= now }) ?? true else { continue }
                let usageDue = vault.preferences.showUsage
                    && (vault.accounts[i].usageRetryAt.map { $0 <= now } ?? true)
                    && now.timeIntervalSince(vault.accounts[i].lastUsageAttempt ?? .distantPast) >= vault.preferences.usageIntervalSeconds
                let refreshDue = vault.preferences.keepFresh && (vault.accounts[i].renewalDate(vault.preferences) <= now
                    || (vault.accounts[i].health == .uncertain && vault.preferences.retryUncertainRefresh))
                let pendingPublication = vault.preferences.keepFresh && native.map {
                    matches(vault.accounts[i].credential, $0.credential)
                        && (vault.accounts[i].pendingNativePublication == true
                            || ($0.fingerprint != vault.accounts[i].credential.fingerprint
                                && $0.fingerprint == vault.accounts[i].nativeFingerprint))
                } == true
                if usageDue || refreshDue || pendingPublication {
                    do {
                        try await update(i, vault: &vault, now: now, force: false, includeUsage: usageDue,
                            allowRefresh: vault.preferences.keepFresh)
                    } catch { if error is CancellationError { throw error } }
                }
            } catch {
                if error is CancellationError { throw error }
                recordFailure(error, at: i, vault: &vault, now: now)
                try store.save(vault)
            }
        }
        try store.save(vault)
    }
    private func update(_ i: Int, vault: inout Vault, now: Date, force: Bool, includeUsage: Bool, allowRefresh: Bool = true) async throws {
        var refreshed = false
        do {
            vault.accounts[i].lastCheckedAt = now
            try recoverInterruptedAttempt(i, vault: &vault, now: now)
            let native = try maintenanceNative(i, vault: &vault)
            try reconcile(i, native: native, vault: &vault)
            if allowRefresh { refreshed = try await refreshRecord(i, vault: &vault, now: now, force: force || vault.accounts[i].health == .needsSignIn || (vault.accounts[i].health == .uncertain && vault.preferences.retryUncertainRefresh), native: native) }
            if allowRefresh || ![.uncertain, .needsSignIn].contains(vault.accounts[i].health) { clearFailure(i, vault: &vault) }
            try store.save(vault)
        } catch {
            recordFailure(error, at: i, vault: &vault, now: now); try store.save(vault); throw error
        }
        guard includeUsage else { return }
        vault.accounts[i].lastUsageAttempt = now
        do {
            do { vault.accounts[i].usage = try await client.usage(vault.accounts[i].credential, now: now) }
            catch AccError.signInRequired where allowRefresh && !refreshed {
                // At most one rotation per update, including expiry-driven refresh.
                do {
                    _ = try await refreshRecord(i, vault: &vault, now: now, force: true,
                        native: try maintenanceNative(i, vault: &vault))
                } catch {
                    recordFailure(error, at: i, vault: &vault, now: now)
                    throw error
                }
                vault.accounts[i].usage = try await client.usage(vault.accounts[i].credential, now: now)
            }
            clearUsageFailure(i, vault: &vault)
            try store.save(vault)
        } catch {
            // Usage permission/rate-limit errors must not disable token maintenance.
            if vault.accounts[i].message == nil { recordUsageFailure(error, at: i, vault: &vault, now: now) }
            try store.save(vault)
            throw error
        }
    }
    @discardableResult
    private func refreshRecord(_ i: Int, vault: inout Vault, now: Date, force: Bool, native: ActiveSnapshot?) async throws -> Bool {
        try recoverInterruptedAttempt(i, vault: &vault, now: now)
        if vault.accounts[i].health == .uncertain, !force, !vault.preferences.retryUncertainRefresh { throw AccError.refreshUncertain }
        let credential = vault.accounts[i].credential
        if let native, matches(credential, native.credential),
           vault.accounts[i].pendingNativePublication == true
            || (credential.fingerprint != native.fingerprint && vault.accounts[i].nativeFingerprint == native.fingerprint) {
            // Also repairs partial multi-store publication after the primary write succeeded.
            do {
                try active.replace(credential, expected: native)
                vault.accounts[i].nativeFingerprint = credential.fingerprint
                vault.accounts[i].pendingNativePublication = false
                try store.save(vault)
            } catch {
                // A failed publication must not stop a later, due renewal.
                guard force || vault.accounts[i].renewalDate(vault.preferences) <= now,
                      vault.preferences.refreshWhenNativeUnavailable else { throw error }
                vault.accounts[i].syncMessage = "Native login sync is waiting. " + safeMessage(error)
            }
        }
        guard force || vault.accounts[i].renewalDate(vault.preferences) <= now else { return false }
        try Task.checkCancellation()
        let before = try maintenanceNative(i, vault: &vault)
        if let before, matches(credential, before.credential) {
            vault.accounts[i].nativeFingerprint = before.fingerprint
            try store.save(vault)
        }
        vault.accounts[i].lastRefreshAttemptAt = now
        vault.accounts[i].refreshInFlight = true
        try store.save(vault)
        // Once sent, cancellation cannot safely undo a rotating OAuth exchange.
        // An unstructured task finishes the request even if its caller is cancelled.
        let client = self.client
        let updated = try await Task { try await client.refresh(credential, now: now) }.value
        guard updated.identity.key == credential.identity.key else { throw AccError.refreshUncertain }
        // The recovery copy is an additional durable path. If it cannot be
        // created, still attempt the primary vault write with the new tokens.
        try? store.saveRotation(accountID: vault.accounts[i].id, previous: credential.fingerprint, credential: updated, at: now)
        vault.accounts[i].credential = updated
        vault.accounts[i].refreshInFlight = false
        vault.accounts[i].lastRefreshedAt = now
        appendEvent("renewed", message: nil, at: i, vault: &vault, now: now)
        vault.accounts[i].pendingNativePublication = before.map { matches(credential, $0.credential) }
            ?? (vault.accounts[i].syncMessage != nil || vault.accounts[i].nativeFingerprint != nil)
        if vault.accounts[i].pendingNativePublication == true, vault.accounts[i].nativeFingerprint == nil {
            vault.accounts[i].nativeFingerprint = credential.fingerprint
        }
        // Durable before touching the provider's store or doing another network request.
        try store.save(vault)
        if let before, matches(credential, before.credential) {
            try active.replace(updated, expected: before)
            vault.accounts[i].nativeFingerprint = updated.fingerprint
            vault.accounts[i].pendingNativePublication = false
            try store.save(vault)
        }
        return true
    }
    private func reconcile(_ i: Int, native: ActiveSnapshot?, vault: inout Vault) throws {
        if let native, vault.accounts[i].health == .uncertain || vault.accounts[i].refreshInFlight == true,
           native.credential.refreshToken == vault.accounts[i].credential.refreshToken { return }
        guard let native, matches(vault.accounts[i].credential, native.credential),
              native.fingerprint != vault.accounts[i].credential.fingerprint,
              native.fingerprint != vault.accounts[i].nativeFingerprint else { return }
        var credential = native.credential
        if credential.identity.userID.isEmpty { credential.identity = vault.accounts[i].credential.identity }
        vault.accounts[i].credential = credential
        vault.accounts[i].lastRefreshedAt = credential.refreshedAt
        vault.accounts[i].refreshInFlight = false
        vault.accounts[i].nativeFingerprint = native.fingerprint
        vault.accounts[i].pendingNativePublication = false
        clearFailure(i, vault: &vault)
        clearUsageFailure(i, vault: &vault)
        try store.save(vault)
    }
    private func capture(_ native: ActiveSnapshot, in vault: inout Vault) async throws {
        if let i = vault.accounts.firstIndex(where: { matches($0.credential, native.credential) }) {
            try reconcile(i, native: native, vault: &vault)
        } else {
            var credential = native.credential
            if credential.provider == .claude, credential.identity.userID.isEmpty { credential = try await client.identify(credential) }
            // A later switch must not resurrect an account the user explicitly removed.
            guard !(vault.forgottenIdentities ?? []).contains(credential.provider.rawValue + "|" + credential.identity.key) else { return }
            var record = AccountRecord(label: normalizedLabel(nil, credential), credential: credential)
            record.nativeFingerprint = native.fingerprint
            vault.accounts.append(record)
        }
    }
    private func readActive(_ provider: Provider, in vault: Vault) throws -> ActiveSnapshot? {
        guard var snapshot = try active.read(provider) else { return nil }
        // Claude stores identity separately. After a partial write, exact token
        // matches in our durable store are stronger evidence than stale metadata.
        if provider == .claude, let known = vault.accounts.first(where: {
            $0.credential.provider == provider && $0.credential.accessToken == snapshot.credential.accessToken
        }) { snapshot.credential.identity = known.credential.identity }
        return snapshot
    }
    /// Native-store availability controls publication, not whether saved accounts
    /// can stay alive. The stricter behavior remains an explicit user preference.
    private func recoverInterruptedAttempt(_ i: Int, vault: inout Vault, now: Date) throws {
        guard vault.accounts[i].refreshInFlight == true else { return }
        recordFailure(AccError.refreshUncertain, at: i, vault: &vault, now: now)
        try store.save(vault)
    }
    private func maintenanceNative(_ i: Int, vault: inout Vault) throws -> ActiveSnapshot? {
        do {
            let native = try readActive(vault.accounts[i].credential.provider, in: vault)
            vault.accounts[i].syncMessage = nil
            return native
        } catch {
            guard vault.preferences.refreshWhenNativeUnavailable else { throw error }
            vault.accounts[i].syncMessage = "Saved login is maintained; native login sync is waiting. " + safeMessage(error)
            return nil
        }
    }
    private func appendEvent(_ outcome: String, message: String?, at i: Int, vault: inout Vault, now: Date) {
        var history = vault.accounts[i].refreshHistory ?? []
        history.append(RefreshEvent(date: now, outcome: outcome, message: message))
        vault.accounts[i].refreshHistory = Array(history.suffix(20))
    }
    private func clearFailure(_ i: Int, vault: inout Vault) {
        vault.accounts[i].health = .ready; vault.accounts[i].message = nil
        vault.accounts[i].nextRetryAt = nil; vault.accounts[i].failures = 0; vault.accounts[i].retryOnConnectivity = nil
    }
    private func clearUsageFailure(_ i: Int, vault: inout Vault) {
        vault.accounts[i].usageMessage = nil; vault.accounts[i].usageRetryAt = nil; vault.accounts[i].usageFailures = nil
    }
    private func recordUsageFailure(_ error: Error, at i: Int, vault: inout Vault, now: Date) {
        guard !(error is CancellationError) else { return }
        let failures = (vault.accounts[i].usageFailures ?? 0) + 1
        vault.accounts[i].usageFailures = failures
        vault.accounts[i].usageMessage = error as? AccError == .signInRequired
            ? "Usage access was rejected. Sign in again if it continues." : safeMessage(error)
        if case let .rateLimited(until) = error as? AccError { vault.accounts[i].usageRetryAt = until }
        else { vault.accounts[i].usageRetryAt = now.addingTimeInterval(min(3600, 30 * pow(2, Double(min(7, failures))))) }
    }
    private func recordFailure(_ error: Error, at i: Int, vault: inout Vault, now: Date) {
        if error is CancellationError { return }
        // A local error or an undelivered explicit retry cannot resolve an
        // earlier request whose result was lost.
        let error: Error = vault.accounts[i].health == .uncertain && error as? AccError != .signInRequired
            ? AccError.refreshUncertain : error
        vault.accounts[i].refreshInFlight = false
        vault.accounts[i].retryOnConnectivity = error as? AccError == .network
        appendEvent(error as? AccError == .refreshUncertain ? "unknown" : "retry", message: safeMessage(error), at: i, vault: &vault, now: now)
        vault.accounts[i].failures += 1
        vault.accounts[i].health = error as? AccError == .refreshUncertain ? .uncertain
            : error as? AccError == .signInRequired ? .needsSignIn : .retrying
        vault.accounts[i].message = safeMessage(error)
        if case let .rateLimited(until) = error as? AccError { vault.accounts[i].nextRetryAt = until }
        else { vault.accounts[i].nextRetryAt = now.addingTimeInterval(min(3600, 30 * pow(2, Double(min(7, vault.accounts[i].failures))))) }
        if vault.accounts[i].health == .needsSignIn || (vault.accounts[i].health == .uncertain && !vault.preferences.retryUncertainRefresh) {
            vault.accounts[i].nextRetryAt = nil
        }
    }
    private func index(_ id: UUID, in vault: Vault) throws -> Int {
        guard let i = vault.accounts.firstIndex(where: { $0.id == id }) else { throw AccError.missingAccount }; return i
    }
}

private func normalizedLabel(_ label: String?, _ credential: Credential) -> String {
    let label = label?.trimmingCharacters(in: .whitespacesAndNewlines)
    return label.flatMap { $0.isEmpty ? nil : $0 } ?? credential.identity.email ?? credential.provider.title
}
private func matches(_ lhs: Credential, _ rhs: Credential) -> Bool {
    guard lhs.provider == rhs.provider else { return false }
    if !lhs.identity.userID.isEmpty, !rhs.identity.userID.isEmpty { return lhs.identity.key == rhs.identity.key }
    return lhs.accessToken == rhs.accessToken || (!lhs.refreshToken.isEmpty && lhs.refreshToken == rhs.refreshToken)
}
