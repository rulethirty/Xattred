import Darwin
import Foundation

/// A single filesystem descriptor, scoped strictly to the project-local Inbox.
public final class InboxWatcher: @unchecked Sendable {
    private let queue = DispatchQueue(label: "app.xattred.inbox", qos: .utility)
    private var source: DispatchSourceFileSystemObject?
    private var pending: DispatchWorkItem?
    private var fingerprints: [URL: String] = [:]
    private var seen: Set<URL> = []
    private var retries = 0
    private let onApp: @Sendable (URL) -> Void
    private let onError: @Sendable (String) -> Void

    public init(onApp: @escaping @Sendable (URL) -> Void, onError: @escaping @Sendable (String) -> Void) {
        self.onApp = onApp
        self.onError = onError
    }

    public func start() throws {
        try AppInspector.validateInbox(AppInspector.inbox)
        if !FileManager.default.fileExists(atPath: AppInspector.inbox.path) {
            try FileManager.default.createDirectory(at: AppInspector.inbox, withIntermediateDirectories: false)
        }
        try AppInspector.validateInbox(AppInspector.inbox)
        seen = Set(try AppInspector.inboxApps()) // No first-launch prompt flood.
        let descriptor = open(AppInspector.inbox.path, O_EVTONLY | O_NOFOLLOW)
        guard descriptor >= 0 else { throw XattredError.unsafeInbox }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor, eventMask: [.write, .rename, .delete, .revoke], queue: queue
        )
        source.setEventHandler { [weak self] in
            guard let self, let source = self.source else { return }
            if !source.data.intersection([.rename, .delete, .revoke]).isEmpty {
                self.pending?.cancel()
                source.cancel()
                self.onError("Inbox moved or deleted. Reopen Xattred to resume project-local detection.")
                return
            }
            self.retries = 120
            self.scheduleScan()
        }
        source.setCancelHandler { close(descriptor) }
        self.source = source
        source.resume()
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
        queue.asyncAfter(deadline: .now() + 3, execute: work)
    }

    private func scan() {
        do {
            let apps = try AppInspector.inboxApps()
            let current = Set(apps)
            seen.formIntersection(current)
            fingerprints = fingerprints.filter { current.contains($0.key) }
            for app in apps where !seen.contains(app) {
                let fingerprint = try AppInspector.fingerprint(app)
                if fingerprints[app] == fingerprint && AppInspector.isQuarantined(app) {
                    seen.insert(app)
                    onApp(app)
                }
                fingerprints[app] = fingerprint
            }
            retries -= 1
            if retries > 0 && apps.contains(where: { !seen.contains($0) }) { scheduleScan() }
        } catch {
            onError(error.localizedDescription)
        }
    }
}