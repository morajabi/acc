import SwiftUI
import AppKit
import Observation
import ServiceManagement
import Network
import AccCore

enum AppPresentation: String, CaseIterable {
    case menuBar, window
}

@MainActor @Observable
final class AppModel {
    var accounts: [AccountSummary] = []
    var current: [CurrentLogin] = []
    var pending: [PendingSignIn] = []
    var observedUsage: [Provider: UsageSnapshot] = [:]
    var observedErrors: [Provider: String] = [:]
    /// Keeps menu-meter age/reset decisions observable even when no request ends.
    var usageClock = Date()
    var preferences = Preferences()
    var selectedProvider: Provider = .codex
    var message: String?
    var notice: String?
    var activityTitle: String?
    var isQuitting = false
    var busy = false
    var updating = false
    var signingIn: Provider?
    var maintenanceMessage: String?
    var lastMaintenanceAt: Date?
    var loginStatusMessage: String?
    var openAccounts: (() -> Void)?
    var resizePanel: ((CGFloat) -> Void)?
    var changePresentation: (() -> Void)?
    var presentation: AppPresentation
    var panelHeight: CGFloat = 580
    var loginAtStartup = SMAppService.mainApp.status == .enabled
    let isDemo: Bool
    private let service = AccountService()
    private var loginTask: Task<Void, Never>?
    private var maintenance: Task<Void, Never>?
    private var clockTask: Task<Void, Never>?
    private var background: Task<Void, Never>?
    private var wakeObserver: NSObjectProtocol?
    private let networkMonitor = NWPathMonitor()
    private var networkWasAvailable = false
    private let scheduler = NSBackgroundActivityScheduler(identifier: "dev.mo.acc.credential-maintenance")
    private var observedRetryAt: [Provider: Date] = [:]
    private var observedRetryOnConnectivity: Set<Provider> = []
    private var foregroundCheckPending = false
    private var connectivityCheckPending = false

    var selectedAccounts: [AccountSummary] {
        accounts.filter { $0.provider == selectedProvider }.sorted {
            if $0.isActive != $1.isActive { return $0.isActive }
            return $0.label.localizedStandardCompare($1.label) == .orderedAscending
        }
    }
    var selectedCurrent: CurrentLogin? { current.first { $0.provider == selectedProvider } }
    var selectedPending: [PendingSignIn] { pending.filter { $0.provider == selectedProvider } }
    func activeUsage(_ provider: Provider) -> UsageSnapshot? {
        _ = usageClock
        if let account = accounts.first(where: { $0.provider == provider && $0.isActive }) {
            return account.usage
        }
        return observedUsage[provider]
    }
    func activeUsageIsStale(_ provider: Provider) -> Bool {
        if let account = accounts.first(where: { $0.provider == provider && $0.isActive }) {
            return account.isPaused == true || account.usageMessage != nil || account.usage?.isStale(at: usageClock) != false
        }
        return observedErrors[provider] != nil || observedUsage[provider]?.isStale(at: usageClock) != false
    }
    init(demo: Bool = CommandLine.arguments.contains("--demo")) {
        isDemo = demo
        presentation = CommandLine.arguments.contains("--window") ? .window
            : AppPresentation(rawValue: UserDefaults.standard.string(forKey: "presentation") ?? "") ?? .menuBar
        if demo {
            loginAtStartup = true
            accounts = DemoAccounts.make()
            current = accounts.filter(\.isActive).map {
                CurrentLogin(provider: $0.provider, identity: $0.identity, expiresAt: $0.expiresAt, savedAccountID: $0.id)
            }
            return
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in await self?.tick() }
        }
        networkMonitor.pathUpdateHandler = { [weak self] path in
            let available = path.status == .satisfied
            Task { @MainActor in
                guard let self else { return }
                let restored = available && !self.networkWasAvailable
                self.networkWasAvailable = available
                if restored { await self.tick(connectivityRestored: true) }
            }
        }
        networkMonitor.start(queue: DispatchQueue(label: "dev.mo.acc.connectivity"))
        scheduler.interval = 600; scheduler.tolerance = 60; scheduler.repeats = true
        scheduler.qualityOfService = .utility
        scheduler.schedule { [weak self] completion in
            Task { @MainActor in
                await self?.tick()
                completion(.finished)
            }
        }
        clockTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(30)) } catch { return }
                self?.usageClock = Date()
            }
        }
        maintenance = Task { [weak self] in
            // Show local state before any provider request.
            do { try await self?.reload() } catch { self?.message = safeMessage(error) }
            while !Task.isCancelled {
                await self?.tick()
                do { try await Task.sleep(for: .seconds(60)) } catch { return }
            }
        }
    }
    func reload() async throws {
        guard !isDemo else { return }
        accounts = try await service.accounts()
        preferences = try await service.preferences()
        let next = try await service.currentLogins()
        for login in next where current.first(where: { $0.provider == login.provider })?.revision != login.revision {
            observedUsage[login.provider] = nil; observedErrors[login.provider] = nil; observedRetryAt[login.provider] = nil
            observedRetryOnConnectivity.remove(login.provider)
        }
        current = next
        pending = try await SignInService(accounts: service).pendingSignIns()
    }
    /// Presentation is read-mostly: it follows normal renewal policy and asks
    /// only for usage older than thirty seconds. Repeated opens are coalesced.
    func refreshWhenPresented() {
        guard !isDemo else { return }
        Task { await tick(foreground: true) }
    }
    private func tick(connectivityRestored: Bool = false, foreground: Bool = false) async {
        usageClock = Date()
        foregroundCheckPending = foregroundCheckPending || foreground
        connectivityCheckPending = connectivityCheckPending || connectivityRestored
        // Browser consent can take minutes; it must not pause other accounts.
        guard !isQuitting, (!busy || signingIn != nil), background == nil else { return }
        let task = Task {
            updating = true
            let activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiatedAllowingIdleSystemSleep, .suddenTerminationDisabled, .automaticTerminationDisabled], reason: "Save scheduled credential renewals")
            defer { updating = false; ProcessInfo.processInfo.endActivity(activity) }
            repeat {
                let foreground = foregroundCheckPending
                let connectivityRestored = connectivityCheckPending
                foregroundCheckPending = false; connectivityCheckPending = false
                do {
                    try await reload()
                    try await service.maintain(connectivityRestored: connectivityRestored,
                        foregroundUsageInterval: foreground ? 30 : nil, foregroundUsageProvider: selectedProvider)
                    lastMaintenanceAt = Date()
                    maintenanceMessage = nil
                    try await reload()
                    try await refreshObservedUsage(force: false, foreground: foreground, connectivityRestored: connectivityRestored)
                } catch AccError.busy { }
                catch is CancellationError { }
                catch { maintenanceMessage = safeMessage(error) }
                usageClock = Date()
            } while !isQuitting && (!busy || signingIn != nil) && (foregroundCheckPending || connectivityCheckPending)
        }
        background = task
        await task.value
        background = nil
    }
    private func refreshObservedUsage(force: Bool, foreground: Bool = false, connectivityRestored: Bool = false) async throws {
        guard preferences.showUsage else { return }
        for login in current where login.identity != nil && login.savedAccountID == nil {
            try Task.checkCancellation()
            let provider = login.provider
            let now = Date()
            if !force {
                if let retry = observedRetryAt[provider] {
                    if retry > now && !(connectivityRestored && observedRetryOnConnectivity.contains(provider)) { continue }
                } else if observedUsage[provider]?.needsRefresh(at: now,
                    interval: min(preferences.usageIntervalSeconds, foreground && provider == selectedProvider ? 30 : 120)) == false { continue }
            }
            do {
                observedUsage[provider] = try await service.currentUsage(provider)
                observedErrors[provider] = nil
                observedRetryAt[provider] = nil
                observedRetryOnConnectivity.remove(provider)
            } catch is CancellationError { throw CancellationError() }
            catch {
                observedErrors[provider] = safeMessage(error)
                if error as? AccError == .externalChange || error as? AccError == .signInRequired {
                    observedUsage[provider] = nil
                }
                if error as? AccError == .network || error as? AccError == .requestNotSent {
                    observedRetryOnConnectivity.insert(provider)
                } else { observedRetryOnConnectivity.remove(provider) }
                if case .rateLimited(let until) = error as? AccError { observedRetryAt[provider] = until }
                else { observedRetryAt[provider] = Date().addingTimeInterval(60) }
            }
        }
    }
    func perform(title: String = "Updating accounts…", success: String? = nil,
                 _ operation: @escaping @Sendable (AccountService) async throws -> Void) {
        guard !busy, !isDemo else { return }
        busy = true; message = nil; notice = nil; activityTitle = title
        let previous = background
        Task {
            await previous?.value
            defer { busy = false; activityTitle = nil; refreshWhenPresented() }
            do { try await operation(service); try await reload(); notice = success }
            catch { message = safeMessage(error); try? await reload() }
        }
    }
    func refreshAll() {
        guard !busy else { return }
        if isDemo {
            for i in accounts.indices { accounts[i].usage?.fetchedAt = Date() }
            notice = "Preview usage updated."
            return
        }
        busy = true; message = nil; notice = nil; activityTitle = "Checking accounts…"
        let previous = background
        Task {
            await previous?.value
            defer { busy = false; activityTitle = nil }
            do {
                try await reload()
                var firstError: Error?
                for account in accounts where account.isPaused != true {
                    do { try await service.refresh(account.id) } catch { if firstError == nil { firstError = error } }
                }
                try await reload()
                try await refreshObservedUsage(force: true)
                if let firstError { message = safeMessage(firstError) }
            } catch { message = safeMessage(error) }
        }
    }
    func signIn(_ provider: Provider, replacing id: UUID? = nil) {
        guard !busy else { return }
        if isDemo { notice = "Browser sign-in is available in normal mode."; return }
        busy = true; signingIn = provider; message = nil; notice = nil
        let previous = background
        loginTask = Task {
            await previous?.value
            defer { busy = false; signingIn = nil; loginTask = nil; refreshWhenPresented() }
            do { _ = try await SignInService(accounts: service).signIn(provider, replacing: id) }
            catch is CancellationError { }
            catch { message = safeMessage(error) }
            try? await reload()
        }
    }
    func cancelSignIn() { loginTask?.cancel() }
    func finishPending(_ id: UUID, asNew: Bool = false) {
        perform { service in _ = try await SignInService(accounts: service).completePending(id, asNew: asNew) }
    }
    func discardPending(_ id: UUID) {
        perform { service in try await SignInService(accounts: service).discardPending(id) }
    }
    func importFile(_ provider: Provider, replacing id: UUID? = nil) {
        guard !busy else { return }
        if isDemo { notice = "File import is available in normal mode."; return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.title = id == nil ? "Import \(provider.title) login" : "Replace \(provider.title) login"
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        perform(title: "Importing account…", success: "Account saved in Acc.") {
            _ = try await $0.importFile(url, provider: provider, replacing: id)
        }
    }
    func setPreference<Value: Sendable>(_ key: WritableKeyPath<Preferences, Value>, _ enabled: Value) {
        var value = preferences; value[keyPath: key] = enabled
        perform { [value] in try await $0.setPreferences(value) }
        if isDemo { preferences = value }
        else { Task { while busy { try? await Task.sleep(for: .milliseconds(100)) }; await tick() } }
    }
    func setPresentation(_ value: AppPresentation) {
        guard presentation != value else { return }
        presentation = value
        if !isDemo { UserDefaults.standard.set(value.rawValue, forKey: "presentation") }
        changePresentation?()
    }
    func configureLoginAtStartup() {
        guard !isDemo else { return }
        let defaults = UserDefaults.standard
        let key = "launchAtLoginRequested"
        // First launch opts in. Later launches respect an explicit off preference
        // and changes made in macOS Login Items rather than repeatedly registering.
        if defaults.object(forKey: key) == nil {
            defaults.set(true, forKey: key)
            if SMAppService.mainApp.status == .notRegistered { setLoginAtStartup(true) }
        }
        updateLoginStatus()
    }
    func updateLoginStatus() {
        guard !isDemo else { return }
        loginAtStartup = SMAppService.mainApp.status == .enabled
        switch SMAppService.mainApp.status {
        case .requiresApproval: loginStatusMessage = "Allow Acc in System Settings → General → Login Items."
        case .notFound: loginStatusMessage = "Move Acc.app to Applications to enable launch at login."
        case .notRegistered: loginStatusMessage = "Launch at login is off."
        default: loginStatusMessage = nil
        }
    }
    func setLoginAtStartup(_ enabled: Bool) {
        guard !isDemo else { loginAtStartup = enabled; return }
        UserDefaults.standard.set(enabled, forKey: "launchAtLoginRequested")
        do {
            if enabled, SMAppService.mainApp.status != .enabled { try SMAppService.mainApp.register() }
            if !enabled, SMAppService.mainApp.status != .notRegistered { try SMAppService.mainApp.unregister() }
            updateLoginStatus()
        } catch {
            updateLoginStatus()
            loginStatusMessage = "Could not change launch at login. Move Acc.app to Applications and try again."
        }
    }
    var needsAttention: Bool {
        message != nil || maintenanceMessage != nil || !preferences.keepFresh || accounts.contains {
            $0.isPaused != true && ($0.renewalHealth == .needsSignIn || $0.renewalHealth == .retrying || $0.renewalHealth == .uncertain
                || ($0.expiresAt.map { $0 < Date() } ?? false))
        }
    }
    var maintenanceStatus: String {
        if !preferences.keepFresh { return "Automatic renewal is off" }
        if accounts.isEmpty { return "Save accounts to enable renewal" }
        if accounts.allSatisfy({ $0.isPaused == true }) { return "All accounts are detached" }
        if needsAttention { return "Needs attention" }
        return "Keeping accounts fresh"
    }
    func waitForMaintenance() async { await background?.value }
}
