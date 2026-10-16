import AppKit
import RationCore

let appName = "Ration"
let bundleID = "io.github.xinding33.ration"
let appVersion = Version(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "") ?? Version("0.0.0")!
let userAgent = "Ration/\(appVersion)"
let supportURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    .appendingPathComponent(appName, isDirectory: true)

if CommandLine.arguments.contains("--diagnose") {
    Diagnose.run()
}
if let index = CommandLine.arguments.firstIndex(of: "--snapshot"), index + 1 < CommandLine.arguments.count {
    MainActor.assumeIsolated { Snapshot.run(into: URL(fileURLWithPath: CommandLine.arguments[index + 1])) }
}

let application = NSApplication.shared
application.setActivationPolicy(.accessory)
let delegate = MainActor.assumeIsolated { AppDelegate() }
application.delegate = delegate
application.run()
