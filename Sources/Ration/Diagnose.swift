import AppKit
import RationCore

/// `Ration --diagnose` checks both services once and prints what it found, without any tokens.
enum Diagnose {
    static func run() -> Never {
        print("Ration \(appVersion) at \(Bundle.main.bundlePath)")
        print("Install updates: " + (Updater.isDeveloperIDSigned(Bundle.main.bundleURL) ? "release build" : "source build, can't update itself"))
        print("Open at Login: \(LoginItem.isEnabled ? "on" : "off")")
        print("Claude Code: \(ClaudeSignIn.findClaudeCode()?.path ?? "not found")")
        let text = UsageText()
        let semaphore = DispatchSemaphore(value: 0)
        Task.detached {
            let claude = ClaudeClient(store: KeychainCredentialStore(), http: URLSession.shared, userAgent: userAgent)
            if let credential = try? await claude.currentCredential() {
                print("Claude login: \(credential.email ?? "signed in"), access token expires \(credential.expiresAt)")
            } else {
                print("Claude login: none")
            }
            // Never renews: the running app owns the refresh token, and renewing it here too could sign it out.
            do { report("Claude", try await claude.usageWithoutRenewing(), text) } catch { print("Claude: \(describe(error))") }
            let chatGPT = ChatGPTClient(http: URLSession.shared, userAgent: userAgent)
            do {
                let result = try await chatGPT.usage()
                print("Codex login: \(result.email ?? "signed in")")
                report("ChatGPT", result.usage, text)
            } catch { print("ChatGPT: \(describe(error))") }
            semaphore.signal()
        }
        semaphore.wait()
        exit(0)
    }

    private static func report(_ service: String, _ usage: ServiceUsage, _ text: UsageText) {
        print("\(service)\(usage.plan.map { " (\($0))" } ?? ""):")
        for window in usage.windows {
            print("  \(window.label): \(text.percent(window.usedPercent)) · \(text.resets(window.resetsAt, now: Date()))")
        }
        if usage.windows.isEmpty { print("  no limits reported") }
    }

    private static func describe(_ error: Error) -> String {
        if case .rateLimited(let until) = error as? ServiceError { return "rate-limited until \(until)" }
        return (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}

/// `Ration --snapshot DIR` draws the menu bar icon, the menu's usage rows and both Settings panes
/// to PNGs with sample numbers, in light and dark, so changes can be checked without clicking.
@MainActor
enum Snapshot {
    static func run(into folder: URL) -> Never {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let soon = Date().addingTimeInterval(4 * 3600)
        let later = Date().addingTimeInterval(2 * 86400)
        let claude = ServiceUsage(plan: "Max", windows: [
            UsageWindow(label: "Session (5 hours)", usedPercent: 6, resetsAt: soon),
            UsageWindow(label: "Weekly", usedPercent: 92, resetsAt: later),
        ])
        let chatGPT = ServiceUsage(plan: "Pro", windows: [UsageWindow(label: "Weekly", usedPercent: 1, resetsAt: later)])
        let text = UsageText()
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let name = appearance == .aqua ? "light" : "dark"
            NSAppearance(named: appearance)!.performAsCurrentDrawingAppearance {
                let icons: [(String, NSImage)] = [
                    ("icon-both", RingIcon.image(outer: .init(percent: 13), inner: .init(percent: 1))),
                    ("icon-near-limit", RingIcon.image(outer: .init(percent: 92), inner: .init(percent: 40))),
                    ("icon-no-numbers", RingIcon.image(outer: .init(percent: nil), inner: .init(percent: 1))),
                    ("icon-claude-only", RingIcon.image(outer: .init(percent: 55), inner: nil)),
                ]
                for (file, icon) in icons {
                    let view = NSImageView(frame: NSRect(x: 0, y: 0, width: 44, height: 28))
                    view.image = icon
                    view.imageScaling = .scaleNone
                    save(view, appearance: appearance, to: folder.appendingPathComponent("\(file)-\(name).png"))
                }
            }
            var rows: [NSView] = [ServiceHeaderView(name: "Claude", plan: claude.plan)]
            rows += claude.windows.map { UsageRowView($0, resets: text.resets($0.resetsAt, now: Date())) }
            rows.append(ServiceHeaderView(name: "ChatGPT", plan: chatGPT.plan))
            rows += chatGPT.windows.map { UsageRowView($0, resets: text.resets($0.resetsAt, now: Date())) }
            let height = rows.reduce(16) { $0 + $1.frame.height }
            let menu = Backdrop(frame: NSRect(x: 0, y: 0, width: UsageRowView.width, height: height))
            menu.color = appearance == .aqua ? NSColor(white: 0.96, alpha: 1) : NSColor(white: 0.17, alpha: 1)
            var y = height - 8
            for row in rows {
                y -= row.frame.height
                row.frame.origin = NSPoint(x: 0, y: y)
                menu.addSubview(row)
            }
            save(menu, appearance: appearance, to: folder.appendingPathComponent("menu-rows-\(name).png"))
        }
        print("Wrote snapshots to \(folder.path)")
        exit(0)
    }

    static func save(_ view: NSView, appearance: NSAppearance.Name, to url: URL) {
        view.appearance = NSAppearance(named: appearance)
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}

/// A plain colored background, standing in for the menu's.
private final class Backdrop: NSView {
    var color = NSColor.windowBackgroundColor
    override func draw(_ dirtyRect: NSRect) {
        color.setFill()
        bounds.fill()
    }
}
