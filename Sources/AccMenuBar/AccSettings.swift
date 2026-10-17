import SwiftUI
import ServiceManagement
import AccCore

struct AccSettings: View {
    @Bindable var model: AppModel

    var body: some View {
        TabView {
            GeneralSettings(model: model).tabItem { Label("General", systemImage: "gearshape") }
            RenewalSettings(model: model).tabItem { Label("Renewal", systemImage: "arrow.triangle.2.circlepath") }
        }.padding(16).frame(minWidth: 500, maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct GeneralSettings: View {
    @Bindable var model: AppModel

    var body: some View {
        Form {
            Section {
                Picker("Show Acc in", selection: Binding(get: { model.presentation }, set: { model.setPresentation($0) })) {
                    Text("Menu bar").tag(AppPresentation.menuBar)
                    Text("Window and Dock").tag(AppPresentation.window)
                }
                Toggle("Open at login", isOn: Binding(get: { model.loginAtStartup }, set: { model.setLoginAtStartup($0) }))
                if let status = model.loginStatusMessage {
                    Text(status).font(.caption).foregroundStyle(.secondary)
                    if !model.loginAtStartup {
                        Button("Open Login Items") { SMAppService.openSystemSettingsLoginItems() }
                    }
                }
            } footer: { Text("Acc keeps your saved accounts fresh while it’s running.") }
            Section {
                Toggle("Show remaining usage", isOn: Binding(get: { model.preferences.showUsage }, set: { model.setPreference(\.showUsage, $0) }))
                    .disabled(model.busy)
            } footer: { Text("Updates every five minutes. Turning this off keeps automatic renewal on.") }
            Section {
                LabeledContent("Version", value: AppVersion.display)
                Link("Source Code on GitHub", destination: URL(string: "https://github.com/morajabi/acc")!)
            }
            if model.isDemo { Text("Preview mode. Account changes are not saved.").font(.caption).foregroundStyle(.secondary) }
            if let message = model.message { Text(message).font(.caption).foregroundStyle(.orange) }
        }.formStyle(.grouped)
    }
}

private struct RenewalSettings: View {
    @Bindable var model: AppModel
    @State private var advanced = false

    var body: some View {
        Form {
            Section {
                Toggle("Keep saved accounts fresh", isOn: Binding(get: { model.preferences.keepFresh }, set: { model.setPreference(\.keepFresh, $0) }))
                    .disabled(model.busy)
            } footer: { Text("Checks every minute and after wake or reconnect. Detached accounts stay paused.") }
            Section("Renewal schedule") {
                IntervalPicker(title: "Renew at least every", value: model.preferences.maximumRefreshIntervalSeconds,
                    options: [.init("1 day", 86400), .init("3 days", 259200), .init("5 days (recommended)", 432000), .init("7 days", 604800)]) {
                        model.setPreference(\.maximumRefreshIntervalSeconds, $0)
                    }
                IntervalPicker(title: "Codex: before expiry", value: model.preferences.codexRefreshBeforeExpirySeconds,
                    options: [.init("5 days (recommended)", 432000), .init("2 days", 172800), .init("1 day", 86400), .init("1 hour", 3600)]) {
                        model.setPreference(\.codexRefreshBeforeExpirySeconds, $0)
                    }
                IntervalPicker(title: "Claude: before expiry", value: model.preferences.refreshBeforeExpirySeconds,
                    options: [.init("10 minutes", 600), .init("30 minutes", 1800), .init("1 hour", 3600)]) {
                        model.setPreference(\.refreshBeforeExpirySeconds, $0)
                    }
            }.disabled(model.busy || !model.preferences.keepFresh)
            Section {
                DisclosureGroup("Advanced", isExpanded: $advanced) {
                    Toggle("Renew when the native login is unavailable",
                        isOn: Binding(get: { model.preferences.refreshWhenNativeUnavailable }, set: { model.setPreference(\.refreshWhenNativeUnavailable, $0) }))
                    Text("Continue renewing saved accounts while Keychain or the provider’s login file is unavailable.")
                        .font(.caption).foregroundStyle(.secondary)
                    Toggle("Retry renewals with an unknown outcome",
                        isOn: Binding(get: { model.preferences.retryUncertainRefresh }, set: { model.setPreference(\.retryUncertainRefresh, $0) }))
                    Text("Off by default. A lost response may have consumed the refresh token. Retrying cannot recover tokens the provider returned but Acc never received.")
                        .font(.caption).foregroundStyle(.secondary)
                }.disabled(model.busy)
            } footer: { Text("The earlier renewal date wins. Short-lived Codex tokens renew halfway through their lifetime.") }
        }.formStyle(.grouped)
    }
}

private struct IntervalPicker: View {
    struct Option: Identifiable {
        let label: String
        let seconds: Double
        var id: Double { seconds }
        init(_ label: String, _ seconds: Double) { self.label = label; self.seconds = seconds }
    }
    let title: String
    let value: Double
    let options: [Option]
    let onChange: (Double) -> Void

    var body: some View {
        Picker(title, selection: Binding(get: { value }, set: { onChange($0) })) {
            ForEach(options) { Text($0.label).tag($0.seconds) }
            if !options.contains(where: { $0.seconds == value }) {
                Text("Custom (\(Int(value / 60)) minutes)").tag(value)
            }
        }
    }
}

enum AppVersion {
    static var display: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.2"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "5"
        return "\(version) (\(build))"
    }
}
