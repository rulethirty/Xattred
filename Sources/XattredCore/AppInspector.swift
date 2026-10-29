import Darwin
import Foundation

public enum XattredError: LocalizedError {
    case invalidApp
    case unsafeInbox
    case commandFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidApp: "Choose a real .app directory, not a symbolic link."
        case .unsafeInbox: "Automatic detection is restricted to the project’s Inbox. Symbolic links are not allowed."
        case .commandFailed(let message): message
        }
    }
}

public enum AppInspector {
    // Deliberately fixed: never infer installation folders or watch the home directory.
    public static let projectRoot = URL(fileURLWithPath: "/Users/user/Documents/xattred", isDirectory: true)
    public static let inbox = projectRoot.appendingPathComponent("Inbox", isDirectory: true)

    public static func validateInbox(_ url: URL) throws {
        guard url.standardizedFileURL == inbox,
              url.resolvingSymlinksInPath().standardizedFileURL == inbox else {
            throw XattredError.unsafeInbox
        }
    }

    public static func validateApp(_ url: URL) throws {
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard url.pathExtension.lowercased() == "app", values.isDirectory == true,
              values.isSymbolicLink != true else { throw XattredError.invalidApp }
    }

    public static func isQuarantined(_ url: URL) -> Bool {
        url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return false }
            return getxattr(path, "com.apple.quarantine", nil, 0, 0, XATTR_NOFOLLOW) >= 0
        }
    }

    /// Only direct app children of the fixed, non-symlinked Inbox are considered.
    public static func inboxApps() throws -> [URL] {
        try validateInbox(inbox)
        return try FileManager.default.contentsOfDirectory(
            at: inbox, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ).filter {
            (try? validateApp($0)) != nil && $0.resolvingSymlinksInPath().path == $0.standardizedFileURL.path
        }.sorted { $0.path < $1.path }
    }

    /// Copy-settling heuristic. Does not follow symlinks inside app bundles.
    public static func fingerprint(_ url: URL) throws -> String {
        try validateApp(url)
        let keys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey, .isSymbolicLinkKey]
        var failure: Error?
        guard let enumerator = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: Array(keys), options: [],
            errorHandler: { _, error in failure = error; return false }
        ) else { throw XattredError.invalidApp }
        var entries: [String] = []
        for case let item as URL in enumerator {
            let values = try item.resourceValues(forKeys: keys)
            if values.isSymbolicLink == true { enumerator.skipDescendants(); continue }
            entries.append("\(item.path):\(values.fileSize ?? 0):\(values.contentModificationDate?.timeIntervalSince1970 ?? 0)")
        }
        if let failure { throw failure }
        return entries.sorted().joined(separator: "\n")
    }

    public static func clearAttributes(of url: URL) throws {
        try validateApp(url)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
        // -s keeps recursive clearing from following bundle symlinks to other files.
        process.arguments = ["-crs", url.path]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let detail = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw XattredError.commandFailed(detail.isEmpty ? "Could not clear attributes. Check your file permissions." : detail)
        }
        guard !isQuarantined(url) else {
            throw XattredError.commandFailed("The quarantine attribute is still present. The app may still be copying.")
        }
    }
}