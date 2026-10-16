import AppKit
import Combine
import RationCore

/// Installs new releases from GitHub, like Wink: at most one check a day, and only into a copy
/// signed with the same Developer ID.
@MainActor
final class Updates: ObservableObject {
    /// Only release builds can install releases, since an update must be signed the same way.
    let canInstall = Updater.isDeveloperIDSigned(Bundle.main.bundleURL)
    @Published var automatic: Bool {
        didSet { UserDefaults.standard.set(automatic, forKey: "autoUpdate"); checkAutomatically() }
    }
    /// What the updater is doing, or nil when it is idle.
    @Published private(set) var status: String?

    private var lastCheck: Date {
        get { UserDefaults.standard.object(forKey: "lastUpdateCheck") as? Date ?? .distantPast }
        set { UserDefaults.standard.set(newValue, forKey: "lastUpdateCheck") }
    }
    private var timer: DispatchSourceTimer?

    init() {
        automatic = UserDefaults.standard.object(forKey: "autoUpdate") as? Bool ?? true
    }

    func start() {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 30, repeating: 60 * 60)
        timer.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.checkAutomatically() } }
        timer.resume()
        self.timer = timer
    }

    func checkAutomatically() {
        guard automatic, canInstall, status == nil, Date().timeIntervalSince(lastCheck) > 24 * 60 * 60 else { return }
        status = "Checking for updates…"
        Task {
            defer { status = nil }
            // A failed check is retried within the hour; a failed install at the next daily check.
            do { if let release = try await newerRelease() { try await install(release) } }
            catch { NSLog("Automatic update failed: %@", error.localizedDescription) }
        }
    }

    func checkNow() {
        guard status == nil else { return }
        status = "Checking for updates…"
        Task {
            defer { status = nil }
            do {
                let release = try await newerRelease()
                NSApp.activate(ignoringOtherApps: true)
                let alert = NSAlert()
                guard let release else {
                    alert.messageText = "Ration is up to date"
                    alert.informativeText = "Version \(appVersion) is the latest."
                    alert.runModal()
                    return
                }
                alert.messageText = "Ration \(release.version) is available"
                alert.informativeText = canInstall
                    ? "You have version \(appVersion)."
                    : "You have version \(appVersion). This copy was built from source, so it can't update itself."
                if canInstall { alert.addButton(withTitle: "Install and Restart") }
                alert.addButton(withTitle: "Release Notes")
                alert.addButton(withTitle: "Later")
                switch (alert.runModal(), canInstall) {
                case (.alertFirstButtonReturn, true): try await install(release)
                case (.alertFirstButtonReturn, false), (.alertSecondButtonReturn, true): NSWorkspace.shared.open(release.page)
                default: break
                }
            } catch {
                NSApp.activate(ignoringOtherApps: true)
                let alert = NSAlert()
                alert.messageText = "Couldn't update Ration"
                alert.informativeText = error.localizedDescription
                alert.alertStyle = .warning
                alert.runModal()
            }
        }
    }

    private func newerRelease() async throws -> Release? {
        let release = try await Updater.latestRelease()
        lastCheck = Date()
        return release.version > appVersion ? release : nil
    }

    private func install(_ release: Release) async throws {
        status = "Installing Ration \(release.version)…"
        try await Updater.install(release, replacing: Bundle.main.bundleURL)
        var arguments = CommandLine.arguments.map { strdup($0) } + [nil]
        execv(Bundle.main.executablePath!, &arguments)
        // Only reached if execv failed. Keep running the old code until the next launch.
        throw UpdateFailure(reason: String(cString: strerror(errno)))
    }
}

private struct UpdateFailure: LocalizedError {
    let reason: String
    var errorDescription: String? { "Ration was updated but couldn't restart (\(reason)). Quit and open it again to finish." }
}
