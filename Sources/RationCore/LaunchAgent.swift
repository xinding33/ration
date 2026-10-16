import Foundation

/// Open at Login is a LaunchAgent in ~/Library/LaunchAgents that opens this copy of the app.
public struct LaunchAgent {
    public let label: String
    public let url: URL

    public init(label: String, directory: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/LaunchAgents", isDirectory: true)) {
        self.label = label
        url = directory.appendingPathComponent("\(label).plist")
    }

    public var exists: Bool { FileManager.default.fileExists(atPath: url.path) }

    public func write(executable: String) throws {
        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": [executable],
            "RunAtLoad": true,
            "ProcessType": "Interactive",
        ]
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: url)
    }

    public func remove() throws {
        try FileManager.default.removeItem(at: url)
    }
}
