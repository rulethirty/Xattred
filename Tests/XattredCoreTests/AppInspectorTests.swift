import Darwin
import Foundation
import XattredCore

final class AppInspectorTests {
    private var fixture: URL!
    private var watched: URL!

    func setUpWithError() throws {
        let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let root = project.appendingPathComponent(".tmp/tests", isDirectory: true)
        fixture = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
        watched = fixture.appendingPathComponent("Applications", isDirectory: true)
        try FileManager.default.createDirectory(at: watched, withIntermediateDirectories: false)
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

    func testWatchDirectoryValidation() throws {
        try AppInspector.validateWatchDirectory(watched)
        let link = fixture.appendingPathComponent("LinkedDirectory")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: watched)
        XCTAssertThrowsError(try AppInspector.validateWatchDirectory(link))
        XCTAssertThrowsError(try AppInspector.validateWatchDirectory(fixture.appendingPathComponent("missing")))
        XCTAssertEqual(AppInspector.applications.path, "/Applications") // No filesystem access.
    }

    func testFingerprintDetectsCopyChanges() throws {
        let app = try makeApp()
        let original = try AppInspector.fingerprint(app)
        XCTAssertEqual(original, try AppInspector.fingerprint(app))
        try Data("new content".utf8).write(to: app.appendingPathComponent("Contents/new"))
        XCTAssertNotEqual(original, try AppInspector.fingerprint(app))
    }

    func testWatchDirectorySkipsSymbolicLinks() throws {
        let app = try makeApp()
        let link = watched.appendingPathComponent("Test-\(UUID().uuidString).app")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: app)
        defer { try? FileManager.default.removeItem(at: link) }
        XCTAssertFalse(try AppInspector.apps(in: watched).contains(link))
    }

    func testLiveWatcherDetectsNewQuarantinedApp() throws {
        let app = try makeApp()
        try setAttribute("com.apple.quarantine", on: app)
        let destination = watched.appendingPathComponent("Test-\(UUID().uuidString).app")
        let detected = DispatchSemaphore(value: 0)
        let watcher = ApplicationWatcher(directory: watched, settleInterval: 0.1, onApp: { url in
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
        XCTAssertTrue(detected.wait(timeout: .now() + 0.5) == .timedOut)
        XCTAssertTrue(AppInspector.isQuarantined(destination)) // Detection never clears anything.
    }

    func testReplacementOfExistingAppIsDetected() throws {
        let original = try makeApp("Original.app")
        try setAttribute("com.apple.quarantine", on: original)
        let destination = watched.appendingPathComponent("Installed.app")
        try FileManager.default.moveItem(at: original, to: destination)
        let detected = DispatchSemaphore(value: 0)
        let watcher = ApplicationWatcher(directory: watched, settleInterval: 0.1,
                                         onApp: { _ in detected.signal() }, onError: { print($0) })
        try watcher.start()
        defer { watcher.stop() }
        XCTAssertTrue(detected.wait(timeout: .now() + 0.5) == .timedOut)
        let replacement = try makeApp("Replacement.app")
        try setAttribute("com.apple.quarantine", on: replacement)
        try FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: replacement, to: destination)
        XCTAssertTrue(detected.wait(timeout: .now() + 5) == .success)
        XCTAssertTrue(detected.wait(timeout: .now() + 0.5) == .timedOut)
    }

    func testNonQuarantinedAppWaitsForLateQuarantine() throws {
        let app = try makeApp()
        let destination = watched.appendingPathComponent("Late.app")
        let detected = DispatchSemaphore(value: 0)
        let watcher = ApplicationWatcher(directory: watched, settleInterval: 0.1,
                                         onApp: { _ in detected.signal() }, onError: { print($0) })
        try watcher.start()
        defer { watcher.stop() }
        try FileManager.default.moveItem(at: app, to: destination)
        XCTAssertTrue(detected.wait(timeout: .now() + 0.5) == .timedOut)
        // Attribute changes inside a new bundle need not emit another parent directory event.
        try setAttribute("com.apple.quarantine", on: destination)
        XCTAssertTrue(detected.wait(timeout: .now() + 5) == .success)
    }

    func testCopyMustSettleBeforePrompt() throws {
        let app = try makeApp()
        let destination = watched.appendingPathComponent("Copying.app")
        try setAttribute("com.apple.quarantine", on: app)
        let detected = DispatchSemaphore(value: 0)
        let watcher = ApplicationWatcher(directory: watched, settleInterval: 0.2,
                                         onApp: { _ in detected.signal() }, onError: { print($0) })
        try watcher.start()
        defer { watcher.stop() }
        try FileManager.default.moveItem(at: app, to: destination)
        for index in 0..<12 {
            try Data(repeating: UInt8(index), count: index + 1)
                .write(to: destination.appendingPathComponent("Contents/payload"))
            XCTAssertTrue(detected.wait(timeout: .now() + 0.05) == .timedOut)
        }
        XCTAssertTrue(detected.wait(timeout: .now() + 5) == .success)
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
            ("validate watch path and production default", suite.testWatchDirectoryValidation),
            ("detect copy changes", suite.testFingerprintDetectsCopyChanges),
            ("skip watch directory symlinks", suite.testWatchDirectorySkipsSymbolicLinks),
            ("live watcher detects once without clearing", suite.testLiveWatcherDetectsNewQuarantinedApp),
            ("ignore existing app; detect replacement", suite.testReplacementOfExistingAppIsDetected),
            ("skip non-quarantined app; detect late quarantine", suite.testNonQuarantinedAppWaitsForLateQuarantine),
            ("wait for copy to settle", suite.testCopyMustSettleBeforePrompt)
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