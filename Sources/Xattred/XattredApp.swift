import AppKit
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers
import XattredCore

@main
struct XattredApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Settings { SettingsView(model: delegate.model) }
    }
}

@MainActor
final class AppModel: ObservableObject {
    @Published var selectedApp: URL?
    @Published var isWorking = false
    @Published var succeeded = false
    @Published var error: String?
    @Published var watcherMessage = "Starting automatic detection…"
    @Published var loginEnabled = SMAppService.mainApp.status == .enabled
    @Published var loginMessage: String?
    @Published var hideMenuIcon = UserDefaults.standard.bool(forKey: "hideMenuIcon") {
        didSet {
            UserDefaults.standard.set(hideMenuIcon, forKey: "hideMenuIcon")
            onVisibilityChange?()
        }
    }
    @Published var githubURL = UserDefaults.standard.string(forKey: "githubURL") ?? "" {
        didSet { UserDefaults.standard.set(githubURL, forKey: "githubURL") }
    }
    var onVisibilityChange: (() -> Void)?
    var showPrompt: (() -> Void)?
    var closePrompt: (() -> Void)?
    private var queued: [URL] = []

    var validatedGitHubURL: URL? {
        guard let url = URL(string: githubURL), url.scheme == "https",
              url.host?.lowercased() == "github.com", url.user == nil, url.password == nil else { return nil }
        return url
    }

    func enqueue(_ app: URL) {
        guard app != selectedApp, !queued.contains(app) else { showPrompt?(); return }
        if selectedApp == nil {
            selectedApp = app
            succeeded = false
            error = nil
            showPrompt?()
        } else {
            queued.append(app)
        }
    }

    func chooseApp() {
        let panel = NSOpenPanel()
        panel.title = "Choose an app you trust"
        panel.message = "Only the app you select will be inspected. Its folder will not be watched."
        panel.allowedContentTypes = [.applicationBundle]
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        enqueue(url)
    }

    func dismiss() {
        guard !isWorking else { return }
        selectedApp = nil
        succeeded = false
        error = nil
        closePrompt?()
        if !queued.isEmpty { enqueue(queued.removeFirst()) }
    }

    func clearSelected() {
        guard let app = selectedApp, !isWorking, !succeeded else { return }
        isWorking = true
        error = nil
        Task {
            do {
                try await Task.detached(priority: .userInitiated) {
                    try AppInspector.clearAttributes(of: app)
                }.value
                succeeded = true
            } catch {
                self.error = error.localizedDescription
            }
            isWorking = false
        }
    }

    func setLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            loginMessage = SMAppService.mainApp.status == .requiresApproval
                ? "Approve Xattred in System Settings → General → Login Items."
                : nil
        } catch {
            loginMessage = "Could not update login item: \(error.localizedDescription)"
        }
        refreshLogin()
    }

    func refreshLogin() {
        loginEnabled = SMAppService.mainApp.status == .enabled
        if SMAppService.mainApp.status == .requiresApproval {
            loginMessage = "Approve Xattred in System Settings → General → Login Items."
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let model = AppModel()
    private var statusItem: NSStatusItem?
    private var settingsWindow: NSWindow?
    private var promptWindow: NSWindow?
    private var watcher: ApplicationWatcher?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        let smokeTest = CommandLine.arguments.contains("--smoke-test")
        model.onVisibilityChange = { [weak self] in self?.updateStatusItem() }
        model.showPrompt = { [weak self] in self?.presentPrompt() }
        model.closePrompt = { [weak self] in self?.promptWindow?.orderOut(nil) }
        updateStatusItem()
        // A smoke test never starts a production watcher outside the project.
        let watchDirectory = smokeTest
            ? URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().appendingPathComponent("Inbox", isDirectory: true)
            : AppInspector.applications
        let watcher = ApplicationWatcher(
            directory: watchDirectory,
            onApp: { [weak self] url in
                Task { @MainActor in self?.model.enqueue(url) }
            },
            onError: { [weak self] message in
                Task { @MainActor in self?.model.watcherMessage = message }
            }
        )
        self.watcher = watcher
        do {
            try watcher.start()
            model.watcherMessage = "Watching \(watchDirectory.path) for newly copied quarantined apps."
        }
        catch { model.watcherMessage = "Detection paused: \(error.localizedDescription)" }
        if smokeTest {
            showSettings()
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                print("Xattred launch smoke test passed; \(self.model.watcherMessage)")
                NSApp.terminate(nil)
            }
        } else if !UserDefaults.standard.bool(forKey: "didLaunch") {
            UserDefaults.standard.set(true, forKey: "didLaunch")
            showSettings()
        }
    }

    func applicationWillTerminate(_ notification: Notification) { watcher?.stop() }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings()
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if model.isWorking {
            let alert = NSAlert()
            alert.messageText = "An app is still being processed"
            alert.informativeText = "Wait for attribute removal to finish before quitting Xattred."
            alert.runModal()
            return .terminateCancel
        }
        return .terminateNow
    }

    private func updateStatusItem() {
        if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
        statusItem = nil
        guard !model.hideMenuIcon else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.attributedTitle = NSAttributedString(
            string: "X", attributes: [.font: NSFont.systemFont(ofSize: 17, weight: .black)]
        )
        item.button?.toolTip = "Xattred"
        let menu = NSMenu()
        addItem("Choose App…", action: #selector(chooseApp), key: "o", to: menu)
        addItem("Open Applications", action: #selector(openApplications), key: "", to: menu)
        menu.addItem(.separator())
        addItem("Settings…", action: #selector(showSettings), key: ",", to: menu)
        menu.addItem(.separator())
        addItem("Quit Xattred", action: #selector(quit), key: "q", to: menu)
        item.menu = menu
        statusItem = item
    }

    private func addItem(_ title: String, action: Selector, key: String, to menu: NSMenu) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        menu.addItem(item)
    }

    @objc private func chooseApp() { model.chooseApp() }
    @objc private func openApplications() {
        NSWorkspace.shared.open(AppInspector.applications)
    }
    @objc private func quit() { NSApp.terminate(nil) }

    @objc func showSettings() {
        model.refreshLogin()
        if settingsWindow == nil {
            settingsWindow = makeWindow(title: "Xattred", view: SettingsView(model: model))
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func presentPrompt() {
        if promptWindow == nil {
            promptWindow = makeWindow(title: "Review app", view: ReviewView(model: model))
            promptWindow?.delegate = self
        }
        promptWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if sender === promptWindow { model.dismiss(); return false }
        return true
    }

    private func makeWindow<V: View>(title: String, view: V) -> NSWindow {
        let window = NSWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = title
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: view)
        window.center()
        return window
    }
}