import AppKit
import RationCore
import SwiftUI

/// The macOS 27 SDK declares a `@State` macro alongside the property wrapper, and its plugin
/// (SwiftUIMacros) is missing from the Command Line Tools. Naming the wrapper through an alias
/// sidesteps the macro, as Ripple does.
private typealias ViewState<Value> = SwiftUI.State<Value>

enum SettingsTab: String { case general, accounts }

/// Holds the selected tab so the menu can open Settings on a given pane.
@MainActor
final class SettingsSelection: ObservableObject {
    @Published var tab: SettingsTab = .general
}

@MainActor
final class SettingsWindowController {
    private let selection = SettingsSelection()
    private let model: UsageModel
    private let updates: Updates
    private var window: NSWindow?

    init(model: UsageModel, updates: Updates) {
        self.model = model
        self.updates = updates
    }

    func show(tab: SettingsTab? = nil) {
        if let tab { selection.tab = tab }
        if window == nil {
            let view = SettingsView(selection: selection, model: model, updates: updates)
            let window = NSWindow(contentViewController: NSHostingController(rootView: view))
            window.title = "Ration Settings"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

struct SettingsView: View {
    @ObservedObject var selection: SettingsSelection
    @ObservedObject var model: UsageModel
    @ObservedObject var updates: Updates

    var body: some View {
        TabView(selection: $selection.tab) {
            GeneralPane(updates: updates)
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(SettingsTab.general)
            AccountsPane(model: model)
                .tabItem { Label("Accounts", systemImage: "person.crop.circle") }
                .tag(SettingsTab.accounts)
        }
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct GeneralPane: View {
    @ObservedObject var updates: Updates
    @ViewState private var opensAtLogin = LoginItem.isEnabled
    @ViewState private var loginError: String?

    var body: some View {
        Form {
            Section {
                Toggle("Open at Login", isOn: Binding(get: { opensAtLogin }, set: { enabled in
                    do {
                        try LoginItem.setEnabled(enabled)
                        loginError = nil
                    } catch {
                        loginError = error.localizedDescription
                    }
                    opensAtLogin = LoginItem.isEnabled
                }))
                if let loginError { Text(loginError).foregroundStyle(.red).font(.callout) }
            }
            Section {
                Toggle("Install Updates Automatically", isOn: $updates.automatic)
                    .disabled(!updates.canInstall)
                LabeledContent("Version \(appVersion.description)") {
                    if let status = updates.status {
                        Text(status).foregroundStyle(.secondary)
                    } else {
                        Button("Check for Updates…") { updates.checkNow() }
                    }
                }
            } header: {
                Text("Updates")
            } footer: {
                Text(updates.canInstall
                     ? "Ration checks GitHub once a day and installs new releases signed by its developer."
                     : "This copy was built from source, so it can't install releases. Pull and build again to update.")
                    .foregroundStyle(.secondary)
            }
            Section {
                Link("Ration on GitHub", destination: URL(string: "https://github.com/xinding33/ration")!)
            } footer: {
                Text("Free and open source. Not affiliated with Anthropic or OpenAI.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { opensAtLogin = LoginItem.isEnabled }
    }
}

private struct AccountsPane: View {
    @ObservedObject var model: UsageModel

    var body: some View {
        Form {
            Section {
                Toggle("Show Claude usage", isOn: $model.tracksClaude)
                if model.tracksClaude { claudeAccount }
            } header: {
                Text("Claude")
            } footer: {
                Text("Ration signs in through Claude Code's official login, then keeps that login to itself in your Keychain and renews it without Claude Code. Signing in needs Claude Code installed; Claude Code's own login isn't touched.")
                    .foregroundStyle(.secondary)
            }
            Section {
                Toggle("Show ChatGPT usage", isOn: $model.tracksChatGPT)
                if model.tracksChatGPT { chatGPTAccount }
            } header: {
                Text("ChatGPT")
            } footer: {
                Text("Ration reads Codex's ChatGPT login from ~/.codex/auth.json and never changes it. To sign in or switch accounts, use Codex.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder private var claudeAccount: some View {
        let state = model.claude
        if model.signingIn {
            LabeledContent("Finish signing in in your browser…") {
                HStack {
                    if let page = model.signInPage {
                        Button("Open Sign-In Page") { NSWorkspace.shared.open(page) }
                    }
                    Button("Cancel") { model.cancelSignIn() }
                }
            }
        } else if let account = state.account ?? (state.problem == nil && state.usage != nil ? "Signed in" : nil) {
            LabeledContent(account) {
                Button("Sign Out") { model.signOutOfClaude() }
            }
            if let plan = state.usage?.plan { LabeledContent("Plan", value: plan) }
            if let problem = state.problem, problem.kind != .signIn { problemText(problem) }
        } else {
            LabeledContent("Not signed in") {
                Button("Sign In…") { model.signInToClaude() }
            }
        }
        if let error = model.signInError { Text(error).foregroundStyle(.red).font(.callout) }
    }

    @ViewBuilder private var chatGPTAccount: some View {
        let state = model.chatGPT
        if let account = state.account {
            LabeledContent("Codex is signed in as", value: account)
            if let plan = state.usage?.plan { LabeledContent("Plan", value: plan) }
        }
        if let problem = state.problem {
            problemText(problem)
        } else if state.account == nil {
            Text(state.checking ? "Checking…" : "Waiting for the first check.").foregroundStyle(.secondary)
        }
    }

    private func problemText(_ problem: Problem) -> some View {
        Text(problem.detail).foregroundStyle(problem.kind == .waiting ? Color.secondary : Color.orange).font(.callout)
    }
}
