import Darwin
import Foundation

public enum XattredError: LocalizedError {
    case invalidApp
    case unsafeDirectory
    case commandFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidApp: "Choose a real .app directory, not a symbolic link."
        case .unsafeDirectory: "The watch location must be an existing directory, without symbolic links."
        case .commandFailed(let message): message
        }
    }
}

public enum AppInspector {
    public static let applications = URL(fileURLWithPath: "/Applications", isDirectory: true)

    public static func validateWatchDirectory(_ url: URL) throws {
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true,
              url.resolvingSymlinksInPath().path == url.standardizedFileURL.path else {
            throw XattredError.unsafeDirectory
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

    /// Only direct app children are considered; no symlink traversal.
    public static func apps(in directory: URL) throws -> [URL] {
        try validateWatchDirectory(directory)
        return try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ).filter {
            (try? validateApp($0)) != nil && $0.resolvingSymlinksInPath().path == $0.standardizedFileURL.path
        }.sorted { $0.path < $1.path }
    }

    /// Cheap generation key: catches replacement at the same path, including Finder copies.
    public static func generation(of url: URL) throws -> String {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return "\(attributes[.systemFileNumber] ?? ""):\(attributes[.creationDate] ?? ""):\(attributes[.modificationDate] ?? "")"
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