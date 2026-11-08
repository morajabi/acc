import AppKit
import Observation
import Sparkle

@MainActor @Observable
final class AppUpdater: NSObject, SPUUpdaterDelegate, @preconcurrency SPUStandardUserDriverDelegate {
    private(set) var isAvailable = false
    private(set) var canCheck = false
    private(set) var updateWaiting = false
    @ObservationIgnored private var controller: SPUStandardUpdaterController?
    @ObservationIgnored private var canCheckObservation: NSKeyValueObservation?

    init(enabled: Bool) {
        super.init()
        guard enabled, Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") != nil else { return }
        let controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: self, userDriverDelegate: self)
        self.controller = controller
        isAvailable = true
        canCheck = controller.updater.canCheckForUpdates
        canCheckObservation = controller.updater.observe(\.canCheckForUpdates, options: [.new]) { [weak self] updater, _ in
            let value = updater.canCheckForUpdates
            Task { @MainActor in self?.canCheck = value }
        }
    }

    var checksAutomatically: Bool {
        get { access(keyPath: \.checksAutomatically); return controller?.updater.automaticallyChecksForUpdates ?? false }
        set { withMutation(keyPath: \.checksAutomatically) { controller?.updater.automaticallyChecksForUpdates = newValue } }
    }

    var installsAutomatically: Bool {
        get { access(keyPath: \.installsAutomatically); return controller?.updater.automaticallyDownloadsUpdates ?? false }
        set { withMutation(keyPath: \.installsAutomatically) { controller?.updater.automaticallyDownloadsUpdates = newValue } }
    }

    func checkForUpdates() {
        NSApp.activate(ignoringOtherApps: true)
        controller?.checkForUpdates(nil)
    }

    func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
                             immediateInstallationBlock immediateInstallHandler: @escaping () -> Void) -> Bool {
        immediateInstallHandler()
        return true
    }

    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool) -> Bool {
        immediateFocus
    }

    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        updateWaiting = !handleShowingUpdate
    }

    func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        updateWaiting = false
    }

    func standardUserDriverWillFinishUpdateSession() {
        updateWaiting = false
    }
}
