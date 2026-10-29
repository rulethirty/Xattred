import Darwin
import Foundation

/// A single directory descriptor. Call start/stop from the owning thread, not callbacks.
public final class ApplicationWatcher: @unchecked Sendable {
    private let queue = DispatchQueue(label: "app.xattred.applications", qos: .utility)
    private let directory: URL
    private let settleInterval: TimeInterval
    private var source: DispatchSourceFileSystemObject?
    private var pending: DispatchWorkItem?
    private var fingerprints: [URL: String] = [:]
    private var seen: [URL: String] = [:]
    private var retries = 0
    private let onApp: @Sendable (URL) -> Void
    private let onError: @Sendable (String) -> Void

    public init(directory: URL, settleInterval: TimeInterval = 3,
                onApp: @escaping @Sendable (URL) -> Void, onError: @escaping @Sendable (String) -> Void) {
        self.directory = directory
        self.settleInterval = settleInterval
        self.onApp = onApp
        self.onError = onError
    }

    public func start() throws {
        guard source == nil else { return }
        try AppInspector.validateWatchDirectory(directory)
        // Baseline existing apps; do not prompt for everything already installed.
        seen = Dictionary(uniqueKeysWithValues: try AppInspector.apps(in: directory).compactMap { app in
            guard let generation = try? AppInspector.generation(of: app) else { return nil }
            return (app, generation)
        })
        let descriptor = open(directory.path, O_EVTONLY | O_NOFOLLOW)
        guard descriptor >= 0 else { throw XattredError.unsafeDirectory }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor, eventMask: [.write, .rename, .delete, .revoke], queue: queue
        )
        source.setEventHandler { [weak self] in
            guard let self, let source = self.source else { return }
            if !source.data.intersection([.rename, .delete, .revoke]).isEmpty {
                self.pending?.cancel()
                source.cancel()
                self.onError("Watch folder moved or deleted. Reopen Xattred to resume detection.")
                return
            }
            self.retries = 120
            self.scheduleScan()
        }
        source.setCancelHandler { close(descriptor) }
        self.source = source
        source.resume()
        queue.async { [weak self] in
            self?.retries = 120
            self?.scheduleScan() // Covers a copy between the baseline and descriptor setup.
        }
    }

    public func stop() {
        queue.sync {
            pending?.cancel()
            pending = nil
            source?.cancel()
            source = nil
        }
    }

    private func scheduleScan() {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.scan() }
        pending = work
        queue.asyncAfter(deadline: .now() + settleInterval, execute: work)
    }

    private func scan() {
        do {
            let apps = try AppInspector.apps(in: directory)
            let current = Set(apps)
            seen = seen.filter { current.contains($0.key) }
            fingerprints = fingerprints.filter { current.contains($0.key) }
            var hasPendingApps = false
            for app in apps {
                do {
                    let generation = try AppInspector.generation(of: app)
                    guard seen[app] != generation else { continue }
                    hasPendingApps = true
                    let fingerprint = generation + (try AppInspector.fingerprint(app))
                    if fingerprints[app] == fingerprint && AppInspector.isQuarantined(app) {
                        seen[app] = generation
                        fingerprints.removeValue(forKey: app)
                        onApp(app)
                    } else {
                        fingerprints[app] = fingerprint
                    }
                } catch {
                    // A file disappearing or becoming unreadable mid-copy is transient.
                    hasPendingApps = true
                    fingerprints.removeValue(forKey: app)
                }
            }
            retries -= 1
            if retries > 0 && hasPendingApps { scheduleScan() }
        } catch {
            onError(error.localizedDescription)
        }
    }
}