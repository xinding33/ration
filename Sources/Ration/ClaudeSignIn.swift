import AppKit
import RationCore

/// Signs in to Claude with Claude Code's own `claude auth login`, in a private profile, then takes
/// that login for Ration and deletes the profile. From then on only Ration uses or renews it, so it
/// can't race Claude Code or anything else.
@MainActor
final class ClaudeSignIn {
    enum Failure: LocalizedError {
        case noClaudeCode, cancelled, timedOut, loginFailed(String)

        var errorDescription: String? {
            switch self {
            case .noClaudeCode: return "Ration signs in through Claude Code, which isn't installed. Install it from claude.com/claude-code, then try again."
            case .cancelled: return "Sign-in was cancelled."
            case .timedOut: return "Sign-in timed out. Try again."
            case .loginFailed(let output): return output.isEmpty ? "Claude Code couldn't sign in." : "Claude Code couldn't sign in: \(output)"
            }
        }
    }

    nonisolated static let profile = supportURL.appendingPathComponent("claude-login", isDirectory: true)
    nonisolated static let timeout: TimeInterval = 10 * 60

    private var process: Process?
    private var cancelled = false
    private var timedOut = false
    /// Whether this copy of Ration started the sign-in whose profile is on disk. Only that copy
    /// cleans it up when quitting; a second copy quitting at launch leaves it alone.
    private var ownsProfile = false
    /// The sign-in page, for opening it again if the browser didn't.
    private(set) var pageURL: URL?

    var isRunning: Bool { process?.isRunning == true }

    /// Runs the sign-in and returns the login it produced. `onPage` gets the sign-in page's address.
    func run(onPage: @escaping (URL) -> Void) async throws -> ClaudeCredential {
        guard let claude = Self.findClaudeCode() else { throw Failure.noClaudeCode }
        let profile = Self.profile
        Self.cleanUp()
        ownsProfile = true
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
        // On success the profile stays until Ration has saved the login; the caller calls `finish` then.
        var succeeded = false
        defer { if !succeeded { finish() } }

        let process = Process()
        process.executableURL = claude
        process.arguments = ["auth", "login", "--claudeai"]
        process.environment = Self.environment(profile: profile)
        process.currentDirectoryURL = profile
        process.standardInput = FileHandle.nullDevice
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        let collected = Collected()
        output.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            let text = collected.append(chunk)
            if let url = Self.pageURL(in: text) {
                Task { @MainActor in
                    guard self.pageURL == nil else { return }
                    self.pageURL = url
                    onPage(url)
                }
            }
        }
        cancelled = false
        timedOut = false
        pageURL = nil
        self.process = process
        let status: Int32 = try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
            do { try process.run() } catch { process.terminationHandler = nil; continuation.resume(throwing: error) }
            Task { @MainActor [weak self, weak process] in
                try? await Task.sleep(nanoseconds: UInt64(Self.timeout * 1_000_000_000))
                guard let process, process.isRunning else { return }
                self?.timedOut = true
                process.terminate()
            }
        }
        output.fileHandleForReading.readabilityHandler = nil
        self.process = nil
        if cancelled { throw Failure.cancelled }
        if timedOut { throw Failure.timedOut }
        guard status == 0 else { throw Failure.loginFailed(Self.lastLine(collected.text)) }
        let login = try Self.readLogin(profile: profile)
        succeeded = true
        return login
    }

    func cancel() {
        cancelled = true
        process?.terminate()
    }

    /// Reads the login `claude auth login` saved for `profile`. Only that profile's own Keychain
    /// item or file is read, never another Claude Code login. Call `cleanUp` once Ration has saved it.
    nonisolated static func readLogin(profile: URL) throws -> ClaudeCredential {
        if let data = try Keychain.read(service: claudeCodeKeychainService(configDirectory: profile.path)) {
            return try ClaudeCredential(claudeCodeJSON: data)
        }
        // Claude Code writes this file instead when the Keychain refuses the write.
        if let data = try? Data(contentsOf: profile.appendingPathComponent(".credentials.json")) {
            return try ClaudeCredential(claudeCodeJSON: data)
        }
        throw ClaudeLoginError.noLogin
    }

    /// Removes the private profile and anything Claude Code left of it: after Ration has saved the
    /// login, after a failed sign-in, when quitting and at launch.
    nonisolated static func cleanUp() {
        try? Keychain.delete(service: claudeCodeKeychainService(configDirectory: profile.path))
        try? FileManager.default.removeItem(at: profile)
    }

    /// Removes this sign-in's profile once Ration has saved the login, or after it failed.
    func finish() {
        Self.cleanUp()
        ownsProfile = false
    }

    /// Stops a sign-in in progress and removes what it left, for quitting. Also covers quitting
    /// after Claude Code finished but before Ration saved the login.
    func stop() {
        guard ownsProfile else { return }
        if let process, process.isRunning {
            cancelled = true
            process.terminate()
            process.waitUntilExit()
        }
        finish()
    }

    /// Claude Code with only this profile: no tokens, keys or settings from anywhere else.
    nonisolated static func environment(profile: URL) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment.filter { key, _ in
            !key.hasPrefix("ANTHROPIC_") && !key.hasPrefix("CLAUDE") && key != "BROWSER"
        }
        environment["CLAUDE_CONFIG_DIR"] = profile.path
        // Claude Code names its Keychain item after this directory; setting it pins the name.
        environment["CLAUDE_SECURESTORAGE_CONFIG_DIR"] = profile.path
        return environment
    }

    nonisolated static func findClaudeCode() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            ProcessInfo.processInfo.environment["CLAUDE_EXECUTABLE"],
            "\(home)/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude",
            "\(home)/.claude/local/claude", "\(home)/.npm-global/bin/claude",
        ].compactMap { $0 }
        if let found = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            return URL(fileURLWithPath: found)
        }
        // Last, ask a login shell, which has the PATH set up in the user's profile.
        let shell = Process()
        shell.executableURL = URL(fileURLWithPath: "/bin/zsh")
        shell.arguments = ["-lc", "command -v claude"]
        let output = Pipe()
        shell.standardOutput = output
        shell.standardError = FileHandle.nullDevice
        shell.standardInput = FileHandle.nullDevice
        guard (try? shell.run()) != nil else { return nil }
        let deadline = Date().addingTimeInterval(5)
        while shell.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        if shell.isRunning { shell.terminate(); return nil }
        let path = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return path.hasPrefix("/") && FileManager.default.isExecutableFile(atPath: path) ? URL(fileURLWithPath: path) : nil
    }

    /// Claude Code prints "If the browser didn't open, visit: <url>".
    nonisolated static func pageURL(in text: String) -> URL? {
        guard let range = text.range(of: "visit: ") else { return nil }
        let rest = text[range.upperBound...]
        let address = rest.prefix { !$0.isWhitespace }
        guard address.hasPrefix("https://") else { return nil }
        return URL(string: String(address))
    }

    nonisolated private static func lastLine(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .last { !$0.isEmpty && !$0.contains("http") } ?? ""
    }
}

/// Output gathered from a child process's pipe, which calls back on its own thread.
private final class Collected: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ chunk: Data) -> String {
        lock.lock(); defer { lock.unlock() }
        data.append(chunk)
        return String(decoding: data, as: UTF8.self)
    }

    var text: String {
        lock.lock(); defer { lock.unlock() }
        return String(decoding: data, as: UTF8.self)
    }
}
