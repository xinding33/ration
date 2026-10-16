import AppKit
import Combine
import RationCore

enum Service: String, CaseIterable, Identifiable {
    case claude, chatGPT
    var id: String { rawValue }
    var name: String { self == .claude ? "Claude" : "ChatGPT" }
}

/// Something to tell the user about one service: `short` under its name in the menu,
/// `detail` in its tooltip and in Settings.
struct Problem: Equatable {
    enum Kind { case signIn, codexLogin, waiting, other }
    let kind: Kind
    let short: String
    let detail: String

    static let signIn = Problem(kind: .signIn, short: "Sign in to see usage…",
                                detail: "Ration isn't signed in to Claude. Sign in under Settings › Accounts.")
}

struct ServiceState {
    var usage: ServiceUsage?
    var updatedAt: Date?
    var problem: Problem?
    var account: String?
    var schedule = CheckSchedule()
    var checking = false
    /// Bumped by signing in or out, so a check that was already under way for the old login can't
    /// bring its numbers back.
    var generation = 0
}

/// Usage for both services, checked on a schedule and when the menu opens.
@MainActor
final class UsageModel: ObservableObject {
    @Published private(set) var claude = ServiceState()
    @Published private(set) var chatGPT = ServiceState()
    @Published var tracksClaude: Bool {
        didSet { UserDefaults.standard.set(tracksClaude, forKey: "tracksClaude"); trackingChanged(.claude) }
    }
    @Published var tracksChatGPT: Bool {
        didSet { UserDefaults.standard.set(tracksChatGPT, forKey: "tracksChatGPT"); trackingChanged(.chatGPT) }
    }
    @Published private(set) var signingIn = false
    @Published private(set) var signInPage: URL?
    @Published private(set) var signInError: String?

    let claudeClient = ClaudeClient(store: KeychainCredentialStore(), http: URLSession.shared, userAgent: userAgent)
    let chatGPTClient = ChatGPTClient(http: URLSession.shared, userAgent: userAgent)
    private let signIn = ClaudeSignIn()
    private let text = UsageText()
    private var ticker: DispatchSourceTimer?

    init() {
        tracksClaude = UserDefaults.standard.object(forKey: "tracksClaude") as? Bool ?? true
        tracksChatGPT = UserDefaults.standard.object(forKey: "tracksChatGPT") as? Bool ?? true
    }

    func state(_ service: Service) -> ServiceState { service == .claude ? claude : chatGPT }
    func tracks(_ service: Service) -> Bool { service == .claude ? tracksClaude : tracksChatGPT }
    var trackedServices: [Service] { Service.allCases.filter(tracks) }

    func start() {
        // A sign-in interrupted by a crash or force quit leaves its private profile behind.
        if !signIn.isRunning { ClaudeSignIn.cleanUp() }
        Task { await loadClaudeAccount() }
        // A dispatch timer, since run-loop timers pause while the menu is open.
        let ticker = DispatchSource.makeTimerSource(queue: .main)
        ticker.schedule(deadline: .now(), repeating: 30, leeway: .seconds(5))
        ticker.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.checkDue() } }
        ticker.resume()
        self.ticker = ticker
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                for service in Service.allCases { self.update(service) { $0.schedule.checkSoon(Date()) } }
                self.checkDue()
            }
        }
    }

    /// Opening the menu checks a service whose numbers are more than a minute old.
    func menuOpened() {
        let now = Date()
        for service in trackedServices {
            let state = state(service)
            if state.schedule.shouldCheckOnOpen(lastUpdate: state.updatedAt, now: now) { check(service) }
        }
    }

    func checkDue() {
        let now = Date()
        for service in trackedServices where state(service).schedule.isDue(now) { check(service) }
    }

    func check(_ service: Service) {
        // `checking` stays set while a check runs even if tracking is turned off, so turning it
        // back on can't start a second one.
        guard tracks(service), !state(service).checking else { return }
        update(service) { $0.checking = true }
        let generation = state(service).generation
        Task {
            do {
                switch service {
                case .claude:
                    let usage = try await claudeClient.usage()
                    succeeded(.claude, generation, usage: usage)
                case .chatGPT:
                    let result = try await chatGPTClient.usage()
                    succeeded(.chatGPT, generation, usage: result.usage, account: result.email)
                }
            } catch {
                failed(service, generation, error)
            }
        }
    }

    /// Whether a check started at `generation` still describes the current login. Whatever bumped
    /// the generation already cleared `checking` and starts its own checks, so a stale result just
    /// goes away.
    private func isCurrent(_ service: Service, _ generation: Int) -> Bool {
        state(service).generation == generation
    }

    private func succeeded(_ service: Service, _ generation: Int, usage: ServiceUsage, account: String? = nil) {
        guard isCurrent(service, generation) else { return }
        update(service) { state in
            state.checking = false
            state.usage = usage
            state.updatedAt = Date()
            state.problem = nil
            if let account { state.account = account }
            state.schedule.succeeded(Date())
        }
    }

    private func failed(_ service: Service, _ generation: Int, _ error: Error) {
        guard isCurrent(service, generation) else { return }
        let now = Date()
        update(service) { state in
            state.checking = false
            state.schedule.failed(error, now: now)
            switch error as? ServiceError {
            case .signedOut:
                state.usage = nil
                state.account = nil
                state.problem = .signIn
            case .codexLogin(let problem):
                state.usage = nil
                state.account = nil
                state.problem = Problem(kind: .codexLogin, short: problem.short, detail: problem.message)
            case .rateLimited(let until):
                let time = text.time(until)
                state.problem = Problem(kind: .waiting, short: "Rate-limited. Trying again at \(time)",
                                        detail: "\(service.name) asked Ration to check less often. It will try again at \(time).")
            default:
                let reason = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                let time = text.time(state.schedule.nextCheck)
                state.problem = Problem(kind: .other, short: "Couldn't check. Trying again at \(time)",
                                        detail: "\(reason) Ration will try again at \(time).")
            }
        }
    }

    private func update(_ service: Service, _ change: (inout ServiceState) -> Void) {
        if service == .claude { change(&claude) } else { change(&chatGPT) }
    }

    /// Turning a service off only hides it: a check already under way still finishes and records
    /// any rate limit. Turning it on again checks soon, but still waits that out.
    private func trackingChanged(_ service: Service) {
        guard tracks(service) else { return }
        update(service) { $0.schedule.checkSoon(Date()) }
        checkDue()
    }

    // MARK: Claude account

    private func loadClaudeAccount() async {
        let credential = try? await claudeClient.currentCredential()
        update(.claude) { $0.account = credential?.email }
        if credential == nil {
            update(.claude) { $0.problem = .signIn }
        }
    }

    func signInToClaude() {
        guard !signingIn else { return }
        signingIn = true
        signInPage = nil
        signInError = nil
        Task {
            defer { signingIn = false; signInPage = nil }
            do {
                let imported = try await signIn.run { url in self.signInPage = url }
                // Claude Code's copy of the login goes only once Ration has saved its own.
                let credential = try await claudeClient.adopt(imported)
                signIn.finish()
                update(.claude) { state in
                    state.generation += 1
                    state.checking = false
                    state.usage = nil
                    state.updatedAt = nil
                    state.account = credential.email
                    state.problem = nil
                    state.schedule.reset(Date())
                }
                check(.claude)
                NSApp.activate(ignoringOtherApps: true)
            } catch ClaudeSignIn.Failure.cancelled {
                return
            } catch {
                signInError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }

    func cancelSignIn() { signIn.cancel() }

    /// Quitting stops a sign-in in progress and removes the private profile it was using.
    func prepareToQuit() { signIn.stop() }

    func signOutOfClaude() {
        Task {
            do {
                try await claudeClient.signOut()
                update(.claude) { state in
                    state.generation += 1
                    state.checking = false
                    state.usage = nil
                    state.updatedAt = nil
                    state.account = nil
                    state.problem = .signIn
                    state.schedule.reset(Date())
                }
            } catch {
                signInError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }
}
