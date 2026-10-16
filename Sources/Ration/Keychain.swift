import Foundation
import RationCore

/// Keychain items, read and written through /usr/bin/security, as Claude Code does. Builds from
/// source are signed ad hoc, and the Keychain would ask again after every rebuild if Ration used
/// its own code signature for access.
enum Keychain {
    static var account: String { ProcessInfo.processInfo.environment["USER"] ?? NSUserName() }

    /// The item's data, or nil if there is none.
    static func read(service: String, account: String = Keychain.account) throws -> Data? {
        let result = try security(["find-generic-password", "-a", account, "-s", service, "-w"])
        if result.status == 44 { return nil }  // errSecItemNotFound
        guard result.status == 0 else { throw KeychainError(action: "read", status: result.status) }
        return securityPasswordOutput(result.output)
    }

    /// Adds or replaces the item. The secret goes in on standard input, never in arguments.
    static func write(_ data: Data, service: String, label: String, account: String = Keychain.account) throws {
        let hex = data.map { String(format: "%02x", $0) }.joined()
        let command = "add-generic-password -U -a \(quoted(account)) -s \(quoted(service)) -l \(quoted(label)) -X \(hex)\n"
        let result = try security(["-i"], input: Data(command.utf8))
        // `security -i` exits 0 even when a command fails, so read the item back.
        guard result.status == 0, try read(service: service, account: account) == data else {
            throw KeychainError(action: "save", status: result.status == 0 ? 1 : result.status)
        }
    }

    static func delete(service: String, account: String = Keychain.account) throws {
        let result = try security(["delete-generic-password", "-a", account, "-s", service])
        guard result.status == 0 || result.status == 44 else { throw KeychainError(action: "delete", status: result.status) }
    }

    private static func quoted(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    private static func security(_ arguments: [String], input: Data? = nil) throws -> (status: Int32, output: Data, errors: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = arguments
        let output = Pipe(), errors = Pipe(), stdin = Pipe()
        process.standardOutput = output
        process.standardError = errors
        process.standardInput = input == nil ? FileHandle.nullDevice : stdin
        try process.run()
        if let input {
            stdin.fileHandleForWriting.write(input)
            try? stdin.fileHandleForWriting.close()
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let message = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        return (process.terminationStatus, data, message)
    }
}

struct KeychainError: LocalizedError {
    let action: String
    let status: Int32
    var errorDescription: String? { "Couldn't \(action) the login in the Keychain (security exited with \(status))." }
}

/// Ration's Claude login, in the login Keychain.
struct KeychainCredentialStore: CredentialStore {
    static let service = "\(bundleID).claude"

    func load() throws -> ClaudeCredential? {
        guard let data = try Keychain.read(service: Self.service) else { return nil }
        return try? Self.decoder.decode(ClaudeCredential.self, from: data)
    }

    func save(_ credential: ClaudeCredential) throws {
        try Keychain.write(try Self.encoder.encode(credential), service: Self.service, label: "Ration: Claude login")
    }

    func delete() throws { try Keychain.delete(service: Self.service) }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        return encoder
    }()
    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }()
}
