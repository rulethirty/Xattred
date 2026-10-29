import Darwin
import Foundation
import XattredCore

final class AppInspectorTests {
    private var fixture: URL!

    func setUpWithError() throws {
        let root = AppInspector.projectRoot.appendingPathComponent(".tmp/tests", isDirectory: true)
        fixture = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
    }

    func tearDownWithError() throws {
        try FileManager.default.removeItem(at: fixture)
    }

    private func makeApp(_ name: String = "Example.app") throws -> URL {
        let app = fixture.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        return app
    }

    private func setAttribute(_ name: String, on url: URL) throws {
        let data = Data("test-attribute".utf8)
        let result = data.withUnsafeBytes { bytes in
            url.withUnsafeFileSystemRepresentation { path in
                setxattr(path!, name, bytes.baseAddress, bytes.count, 0, 0)
            }
        }
        guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }

    private func hasAttribute(_ name: String, on url: URL) -> Bool {
        url.withUnsafeFileSystemRepresentation { getxattr($0!, name, nil, 0, 0, XATTR_NOFOLLOW) >= 0 }
    }

    func testQuarantineDetection() throws {
        let app = try makeApp()
        XCTAssertFalse(AppInspector.isQuarantined(app))
        try setAttribute("com.apple.quarantine", on: app)
        XCTAssertTrue(AppInspector.isQuarantined(app))
    }

    func testClearsAllAttributesRecursivelyAndHandlesShellCharacters() throws {
        let app = try makeApp("An App; '$(not-a-command)'.app")
        let child = app.appendingPathComponent("Contents/payload")
        try Data("payload".utf8).write(to: child)
        try setAttribute("com.apple.quarantine", on: app)
        try setAttribute("app.xattred.test", on: child)
        try AppInspector.clearAttributes(of: app)
        XCTAssertFalse(AppInspector.isQuarantined(app))
        XCTAssertFalse(hasAttribute("app.xattred.test", on: child))
        XCTAssertEqual(try String(contentsOf: child, encoding: .utf8), "payload")
    }

    func testRejectsNonAppAndSymlinkApp() throws {
        let app = try makeApp()
        XCTAssertThrowsError(try AppInspector.validateApp(fixture))
        let link = fixture.appendingPathComponent("Link.app")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: app)
        XCTAssertThrowsError(try AppInspector.clearAttributes(of: link))
    }

    func testRecursiveClearDoesNotFollowBundleSymlinks() throws {
        let app = try makeApp()
        let target = fixture.appendingPathComponent("untouched")
        try Data("outside the bundle, still inside the project".utf8).write(to: target)
        try setAttribute("app.xattred.test", on: target)
        try FileManager.default.createSymbolicLink(at: app.appendingPathComponent("Contents/link"), withDestinationURL: target)
        try AppInspector.clearAttributes(of: app)
        XCTAssertTrue(hasAttribute("app.xattred.test", on: target))
    }

    func testOnlyFixedInboxIsAccepted() throws {
        try AppInspector.validateInbox(AppInspector.inbox)
        XCTAssertThrowsError(try AppInspector.validateInbox(AppInspector.projectRoot))
        XCTAssertThrowsError(try AppInspector.validateInbox(fixture))
    }

    func testFingerprintDetectsCopyChanges() throws {
        let app = try makeApp()
        let original = try AppInspector.fingerprint(app)
        XCTAssertEqual(original, try AppInspector.fingerprint(app))
        try Data("new content".utf8).write(to: app.appendingPathComponent("Contents/new"))
        XCTAssertNotEqual(original, try AppInspector.fingerprint(app))
    }

    func testInboxSkipsSymbolicLinks() throws {
        let app = try makeApp()
        let link = AppInspector.inbox.appendingPathComponent("Test-\(UUID().uuidString).app")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: app)
        defer { try? FileManager.default.removeItem(at: link) }
        XCTAssertFalse(try AppInspector.inboxApps().contains(link))
    }

    func testLiveWatcherDetectsNewQuarantinedApp() throws {
        let app = try makeApp()
        try setAttribute("com.apple.quarantine", on: app)
        let destination = AppInspector.inbox.appendingPathComponent("Test-\(UUID().uuidString).app")
        let detected = DispatchSemaphore(value: 0)
        let watcher = InboxWatcher(onApp: { url in
            if url.path == destination.path { detected.signal() }
        }, onError: { message in
            print("Watcher error: \(message)")
        })
        try watcher.start()
        defer {
            watcher.stop()
            try? FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.moveItem(at: app, to: destination)
        XCTAssertTrue(detected.wait(timeout: .now() + 15) == .success)
        XCTAssertTrue(detected.wait(timeout: .now() + 4) == .timedOut)
        XCTAssertTrue(AppInspector.isQuarantined(destination)) // Detection never clears anything.
    }
}

// Minimal throwing assertions keep the suite runnable with Command Line Tools alone.
private func XCTAssertTrue(_ value: Bool, file: StaticString = #filePath, line: UInt = #line) {
    precondition(value, "Expected true at \(file):\(line)")
}
private func XCTAssertFalse(_ value: Bool, file: StaticString = #filePath, line: UInt = #line) {
    precondition(!value, "Expected false at \(file):\(line)")
}
private func XCTAssertEqual<T: Equatable>(_ lhs: T, _ rhs: T) { precondition(lhs == rhs, "Values differ") }
private func XCTAssertNotEqual<T: Equatable>(_ lhs: T, _ rhs: T) { precondition(lhs != rhs, "Values unexpectedly equal") }
private func XCTAssertThrowsError<T>(_ expression: @autoclosure () throws -> T) {
    do { _ = try expression() } catch { return }
    preconditionFailure("Expected an error")
}

@main
struct TestRunner {
    static func main() throws {
        let suite = AppInspectorTests()
        let cases: [(String, () throws -> Void)] = [
            ("quarantine detection", suite.testQuarantineDetection),
            ("recursive clear and safe path arguments", suite.testClearsAllAttributesRecursivelyAndHandlesShellCharacters),
            ("reject non-app and symlink", suite.testRejectsNonAppAndSymlinkApp),
            ("preserve symlink targets", suite.testRecursiveClearDoesNotFollowBundleSymlinks),
            ("restrict Inbox path", suite.testOnlyFixedInboxIsAccepted),
            ("detect copy changes", suite.testFingerprintDetectsCopyChanges),
            ("skip Inbox symlinks", suite.testInboxSkipsSymbolicLinks),
            ("live watcher detects once without clearing", suite.testLiveWatcherDetectsNewQuarantinedApp)
        ]
        for (name, test) in cases {
            try suite.setUpWithError()
            do {
                try test()
                try suite.tearDownWithError()
                print("PASS: \(name)")
            } catch {
                try? suite.tearDownWithError()
                throw error
            }
        }
        print("All \(cases.count) tests passed.")
    }
}