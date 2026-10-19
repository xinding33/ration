import XCTest
@testable import RationCore

final class UpdateTests: XCTestCase {
    var folder: URL!
    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: folder) }

    /// An ad-hoc signed Ration.app whose designated requirement is just its identifier.
    func makeApp(in name: String, identifier: String = "test.ration", version: String) throws -> URL {
        let app = folder.appendingPathComponent(name).appendingPathComponent("Ration.app")
        let macOS = app.appendingPathComponent("Contents/MacOS")
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        try FileManager.default.copyItem(atPath: "/usr/bin/true", toPath: macOS.appendingPathComponent("Ration").path)
        let info: NSDictionary = ["CFBundleIdentifier": identifier, "CFBundleExecutable": "Ration",
                                  "CFBundlePackageType": "APPL", "CFBundleShortVersionString": version]
        try info.write(to: app.appendingPathComponent("Contents/Info.plist"))
        try run("/usr/bin/codesign", "--force", "--sign", "-", "-r=designated => identifier \"\(identifier)\"", app.path)
        return app
    }

    /// Zips `app` the way scripts/release.sh does.
    func zip(_ app: URL) throws -> URL {
        let zip = app.deletingLastPathComponent().appendingPathComponent("Ration.zip")
        try run("/usr/bin/ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", app.path, zip.path)
        return zip
    }

    func run(_ path: String, _ arguments: String...) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "\(path) \(arguments)")
    }

    func installedVersion(_ app: URL) -> String? {
        NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist"))?["CFBundleShortVersionString"] as? String
    }

    func testComparesVersionsNumerically() throws {
        func version(_ string: String) throws -> Version { try XCTUnwrap(Version(string)) }
        XCTAssertLessThan(try version("1.9.0"), try version("1.10.0"))
        XCTAssertLessThan(try version("1.1.0"), try version("v1.1.1"))
        XCTAssertEqual(try version("v1.1"), try version("1.1.0"))
        XCTAssertEqual(try version("v1.1.0").description, "1.1.0")
        XCTAssertNil(Version("1.1.0-beta"))
        XCTAssertNil(Version(""))
    }
    func testFindsTheDownloadInTheLatestRelease() throws {
        let json = """
            {"tag_name": "v1.2.0", "html_url": "https://github.com/xinding33/ration/releases/tag/v1.2.0",
             "assets": [
               {"name": "notes.txt", "browser_download_url": "https://example.com/notes.txt"},
               {"name": "Ration-1.2.0.zip",
                "browser_download_url": "https://github.com/xinding33/ration/releases/download/v1.2.0/Ration-1.2.0.zip"}]}
            """
        let release = try Release(gitHubJSON: Data(json.utf8))
        XCTAssertEqual(release.version, Version("1.2.0"))
        XCTAssertEqual(release.page.absoluteString, "https://github.com/xinding33/ration/releases/tag/v1.2.0")
        XCTAssertEqual(release.download.lastPathComponent, "Ration-1.2.0.zip")
        let noZip = #"{"tag_name": "v1.2.0", "html_url": "https://example.com", "assets": []}"#
        XCTAssertThrowsError(try Release(gitHubJSON: Data(noZip.utf8))) { XCTAssertEqual($0 as? UpdateError, .noDownload) }
    }
    func testInstallsAnUpdateSignedLikeTheApp() throws {
        let app = try makeApp(in: "installed", version: "1.1.0")
        let update = try zip(makeApp(in: "update", version: "1.2.0"))
        try Updater.install(zip: update, version: XCTUnwrap(Version("1.2.0")), replacing: app)
        XCTAssertEqual(installedVersion(app), "1.2.0")
    }
    func testTellsAProcessExecedIntoAnUpdateFromAFreshLaunch() throws {
        let app = try makeApp(in: "installed", version: "1.1.0")
        let built = try makeApp(in: "update", version: "1.2.0")
        // Unzipping keeps the build's modification date, so only the change date says when it was installed.
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -86400)],
                                              ofItemAtPath: built.appendingPathComponent("Contents/MacOS/Ration").path)
        let update = try zip(built)
        try Updater.install(zip: update, version: XCTUnwrap(Version("1.2.0")), replacing: app)
        let changed = try XCTUnwrap(Updater.changeDate(of: app.appendingPathComponent("Contents/MacOS/Ration")))
        XCTAssertEqual(changed.timeIntervalSinceNow, 0, accuracy: 5)
        // Running for an hour when the update was installed over it.
        XCTAssertTrue(Updater.wasExecedIntoUpdate(processStarted: changed.addingTimeInterval(-3600), executableChanged: changed))
        // Opened after the update was installed, or as macOS touched the executable while opening it.
        XCTAssertFalse(Updater.wasExecedIntoUpdate(processStarted: changed.addingTimeInterval(1), executableChanged: changed))
        XCTAssertFalse(Updater.wasExecedIntoUpdate(processStarted: changed.addingTimeInterval(-2), executableChanged: changed))
        // Installed while the clock was an hour fast, then opened after it was set right.
        XCTAssertFalse(Updater.wasExecedIntoUpdate(processStarted: changed.addingTimeInterval(-3000), executableChanged: changed,
                                                   now: changed.addingTimeInterval(-2990)))
    }
    func testRejectsAnUpdateSignedDifferently() throws {
        let app = try makeApp(in: "installed", version: "1.1.0")
        let update = try zip(makeApp(in: "update", identifier: "test.impostor", version: "1.2.0"))
        XCTAssertThrowsError(try Updater.install(zip: update, version: XCTUnwrap(Version("1.2.0")), replacing: app)) {
            XCTAssertEqual($0 as? UpdateError, .badSignature)
        }
        XCTAssertEqual(installedVersion(app), "1.1.0")
    }
    func testRejectsAnUpdateThatIsTheWrongVersion() throws {
        let app = try makeApp(in: "installed", version: "1.1.0")
        let update = try zip(makeApp(in: "update", version: "1.0.0"))
        XCTAssertThrowsError(try Updater.install(zip: update, version: XCTUnwrap(Version("1.2.0")), replacing: app)) {
            XCTAssertEqual($0 as? UpdateError, .wrongVersion)
        }
        XCTAssertEqual(installedVersion(app), "1.1.0")
    }
    func testRejectsAModifiedUpdate() throws {
        let app = try makeApp(in: "installed", version: "1.1.0")
        let update = try makeApp(in: "update", version: "1.2.0")
        try Data("tampered".utf8).write(to: update.appendingPathComponent("Contents/MacOS/Ration"))
        XCTAssertThrowsError(try Updater.install(zip: zip(update), version: XCTUnwrap(Version("1.2.0")), replacing: app)) {
            XCTAssertEqual($0 as? UpdateError, .badSignature)
        }
        XCTAssertEqual(installedVersion(app), "1.1.0")
    }
    func testSourceBuildsAreNotDeveloperIDSigned() throws {
        XCTAssertFalse(Updater.isDeveloperIDSigned(try makeApp(in: "installed", version: "1.1.0")))
    }
}
