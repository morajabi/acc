import SwiftUI
import AppKit
import AccCore

struct AccountPanel: View {
    @Bindable var model: AppModel
    let compact: Bool

    var body: some View {
        VStack(spacing: 0) {
            if compact { PanelHeader(model: model) }
            else {
                ProviderPicker(selection: $model.selectedProvider)
                    .frame(height: 28).padding(.horizontal, 14).padding(.vertical, 10)
            }
            Divider()
            ScrollView {
                VStack(spacing: 0) {
                    if let login = model.selectedCurrent, login.savedAccountID == nil,
                       login.identity != nil || login.message != nil {
                        CurrentLoginRow(login: login, model: model)
                    }
                    ForEach(model.selectedPending) { PendingLoginRow(pending: $0, model: model) }
                    ForEach(model.selectedAccounts) { account in
                        VStack(spacing: 0) {
                            AccountRow(account: account, model: model)
                            if account.id != model.selectedAccounts.last?.id { Divider().padding(.horizontal, 14) }
                        }
                    }
                    if model.selectedAccounts.isEmpty && model.selectedCurrent?.identity == nil
                        && model.selectedCurrent?.message == nil && model.selectedPending.isEmpty {
                        EmptyAccountsView(provider: model.selectedProvider, model: model)
                    }
                }
                .frame(maxWidth: compact ? .infinity : 580)
                .padding(.vertical, 4).frame(maxWidth: .infinity)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
            OperationBanner(model: model)
            Divider()
            PanelFooter(model: model, compact: compact)
            if compact { PanelResizeHandle(model: model) }
        }
        .frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onChange(of: model.selectedProvider) { model.refreshWhenPresented() }
    }
}

/// AppKit's segmented control retains both provider names and template marks.
/// SwiftUI's macOS segmented picker can omit the image in a custom label.
struct ProviderPicker: NSViewRepresentable {
    @Binding var selection: Provider

    func makeCoordinator() -> Coordinator { Coordinator(selection: $selection) }
    func makeNSView(context: Context) -> NSSegmentedControl {
        let control = NSSegmentedControl(labels: ["ChatGPT", "Claude"], trackingMode: .selectOne,
            target: context.coordinator, action: #selector(Coordinator.selectProvider(_:)))
        control.segmentDistribution = .fillEqually
        control.setContentHuggingPriority(.defaultLow, for: .horizontal)
        control.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        for (index, provider) in Provider.allCases.enumerated() {
            control.setImage(ProviderIcon.image(for: provider), forSegment: index)
            control.setImageScaling(.scaleProportionallyDown, forSegment: index)
            control.setToolTip("Show \(provider == .codex ? "ChatGPT" : "Claude") accounts", forSegment: index)
        }
        control.setAccessibilityLabel("Account provider")
        return control
    }
    func updateNSView(_ control: NSSegmentedControl, context: Context) {
        context.coordinator.selection = $selection
        control.selectedSegment = selection == .codex ? 0 : 1
    }
    @MainActor final class Coordinator: NSObject {
        var selection: Binding<Provider>
        init(selection: Binding<Provider>) { self.selection = selection }
        @objc func selectProvider(_ sender: NSSegmentedControl) {
            selection.wrappedValue = sender.selectedSegment == 0 ? .codex : .claude
        }
    }
}

struct PanelHeader: View {
    @Bindable var model: AppModel

    var body: some View {
        HStack(spacing: 12) {
            ProviderPicker(selection: $model.selectedProvider).frame(height: 28)
            Button { model.refreshAll() } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.borderless).help("Check accounts and update usage")
                .accessibilityLabel("Refresh accounts").disabled(model.busy || model.updating)
            AddAccountMenu(model: model)
        }.padding(.horizontal, 14).padding(.vertical, 10)
    }
}

struct AddAccountMenu: View {
    let model: AppModel

    var body: some View {
        Menu {
            Button("Sign In with Browser…") { model.signIn(model.selectedProvider) }
            if model.selectedCurrent?.identity != nil && model.selectedCurrent?.savedAccountID == nil {
                Button("Save Current Account") { model.saveCurrent(model.selectedProvider) }
            }
            Divider()
            Button("Import from File…") { model.importFile(model.selectedProvider) }
        } label: { Image(systemName: "plus") }
        .menuStyle(.borderlessButton).fixedSize().disabled(model.busy)
        .help("Add an account").accessibilityLabel("Add account")
    }
}

struct EmptyAccountsView: View {
    let provider: Provider
    let model: AppModel

    var body: some View {
        VStack(spacing: 12) {
            ProviderMark(provider: provider).fill(.secondary).frame(width: 36, height: 36)
                .accessibilityHidden(true)
            Text("Add a \(provider == .codex ? "ChatGPT" : "Claude") account").font(.title3.weight(.semibold))
            Text("Keep your login fresh and switch accounts when you need to.")
                .foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button("Sign In with Browser…") { model.signIn(provider) }
                .buttonStyle(.borderedProminent).controlSize(.large)
            Button("Import from File…") { model.importFile(provider) }.buttonStyle(.link)
        }.padding(.horizontal, 16).padding(.vertical, 32).frame(maxWidth: .infinity)
            .disabled(model.busy)
    }
}

struct CurrentLoginRow: View {
    let login: CurrentLogin
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let identity = login.identity {
                VStack(alignment: .leading, spacing: 4) {
                    Text(identity.email ?? "Current \(login.provider.title) account").font(.headline).textSelection(.enabled)
                    Text("Active · Not managed by Acc").font(.caption).foregroundStyle(.secondary)
                }
                if model.preferences.showUsage {
                    UsageSection(usage: model.observedUsage[login.provider],
                        stale: model.observedErrors[login.provider] != nil, expanded: true)
                    if let error = model.observedErrors[login.provider] {
                        Text(error).font(.caption).foregroundStyle(.secondary)
                    }
                }
                HStack {
                    Text("Save this account to keep it fresh.").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Save Account") { model.saveCurrent(login.provider) }
                        .buttonStyle(.borderedProminent).disabled(model.busy)
                }
            } else if let message = login.message {
                Label("Current login unavailable", systemImage: "exclamationmark.triangle")
                    .font(.headline).foregroundStyle(.orange)
                Text(message).font(.callout).foregroundStyle(.secondary)
                if login.requiresKeychainAccess == true {
                    Button("Allow Keychain Access…") { model.authorizeKeychain(login.provider) }.disabled(model.busy)
                }
            }
        }.accountCard()
    }
}

struct OperationBanner: View {
    let model: AppModel

    var body: some View {
        if let provider = model.signingIn {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Finish \(provider.title) sign-in in your browser.").font(.callout)
                Spacer(minLength: 4)
                Button("Cancel", action: model.cancelSignIn)
            }.padding(12)
        } else if let message = model.message ?? model.maintenanceMessage ?? model.notice {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: model.message != nil || model.maintenanceMessage != nil ? "exclamationmark.triangle" : "checkmark.circle")
                    .foregroundStyle(model.message != nil || model.maintenanceMessage != nil ? Color.orange : Color.secondary)
                Text(message).font(.callout).textSelection(.enabled)
                Spacer(minLength: 0)
                Button { model.message = nil; model.maintenanceMessage = nil; model.notice = nil } label: {
                    Image(systemName: "xmark")
                }.buttonStyle(.borderless).accessibilityLabel("Dismiss message")
            }.padding(12)
        }
    }
}

struct PendingLoginRow: View {
    let pending: PendingSignIn
    let model: AppModel
    @State private var discard = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Sign-in ready to add", systemImage: "person.crop.circle.badge.checkmark").font(.headline)
            Text("Your browser sign-in is saved. Finish adding it to start managing this account.")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                Button("Finish Adding") { model.finishPending(pending.id) }.buttonStyle(.borderedProminent)
                Menu {
                    if pending.replacingID != nil { Button("Add as New Account") { model.finishPending(pending.id, asNew: true) } }
                    Button("Discard…", role: .destructive) { discard = true }
                } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).fixedSize()
                    .accessibilityLabel("Pending sign-in actions")
            }.disabled(model.busy)
        }.accountCard()
            .alert("Discard completed sign-in?", isPresented: $discard) {
                Button("Discard", role: .destructive) { model.discardPending(pending.id) }
                Button("Cancel", role: .cancel) {}
            } message: { Text("You will need to sign in again to add this account.") }
    }
}

struct PanelFooter: View {
    let model: AppModel
    let compact: Bool

    var body: some View {
        HStack(spacing: 8) {
            if model.busy || model.updating { ProgressView().controlSize(.mini) }
            else {
                Image(systemName: model.needsAttention ? "exclamationmark.circle" : model.preferences.keepFresh ? "checkmark.circle" : "pause.circle")
                    .foregroundStyle(model.needsAttention ? Color.orange : Color.secondary)
            }
            Text(model.busy ? model.activityTitle ?? "Updating accounts…" : model.maintenanceStatus)
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            Spacer(minLength: 4)
            if compact {
                Button { model.openAccounts?() } label: { Image(systemName: "macwindow") }
                    .buttonStyle(.borderless).help("Open Accounts window").accessibilityLabel("Open Accounts window")
                Menu {
                    SettingsLink { Text("Settings…") }.keyboardShortcut(",")
                    Divider()
                    Button("Quit Acc") { NSApp.terminate(nil) }.keyboardShortcut("q")
                } label: { Image(systemName: "gearshape") }
                .menuStyle(.borderlessButton).fixedSize().accessibilityLabel("App options")
            }
        }
        .help(model.lastMaintenanceAt.map { "Last checked \($0.formatted(date: .abbreviated, time: .shortened)). Checks every minute and after wake or reconnect." }
            ?? "Saved accounts are checked every minute and after wake or reconnect.")
        .padding(.horizontal, 14).padding(.vertical, 8)
    }
}

struct PanelResizeHandle: View {
    let model: AppModel
    @State private var startingHeight: CGFloat?

    var body: some View {
        Capsule().fill(.tertiary).frame(width: 32, height: 3)
            .frame(maxWidth: .infinity).frame(height: 11).contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .global)
                .onChanged { value in
                    if startingHeight == nil { startingHeight = model.panelHeight }
                    model.resizePanel?((startingHeight ?? 430) + value.translation.height)
                }.onEnded { _ in startingHeight = nil })
            .onHover { hovering in if hovering { NSCursor.resizeUpDown.push() } else { NSCursor.pop() } }
            .help("Drag to resize the panel").accessibilityLabel("Panel height")
            .accessibilityAdjustableAction { direction in
                model.resizePanel?(model.panelHeight + (direction == .increment ? 60 : -60))
            }
    }
}

private struct AccountCard: ViewModifier {
    func body(content: Content) -> some View {
        content.padding(.horizontal, 14).padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension View {
    func accountCard() -> some View { modifier(AccountCard()) }
}
