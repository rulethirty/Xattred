import AppKit
import ServiceManagement
import SwiftUI
import XattredCore

private struct Brand: View {
    var body: some View {
        HStack(spacing: 12) {
            Text("X")
                .font(.system(size: 30, weight: .black, design: .rounded))
                .foregroundStyle(.white)
                .frame(width: 52, height: 52)
                .background(.black, in: RoundedRectangle(cornerRadius: 13))
            VStack(alignment: .leading, spacing: 3) {
                Text("Xattred").font(.system(size: 23, weight: .bold))
                Text("A little less friction.").font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
        }
    }
}

struct ReviewView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 22) {
            Brand()
            if let app = model.selectedApp {
                VStack(spacing: 9) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: app.path))
                        .resizable().interpolation(.high).frame(width: 76, height: 76)
                    Text(app.deletingPathExtension().lastPathComponent)
                        .font(.title2.bold()).lineLimit(2).multilineTextAlignment(.center)
                    Text(app.path).font(.caption).foregroundStyle(.secondary)
                        .lineLimit(3).textSelection(.enabled)
                    Text(AppInspector.isQuarantined(app) ? "Quarantine attribute detected" : "Manually selected app")
                        .font(.caption.weight(.medium)).foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 16) {
                    Toggle(isOn: Binding(
                        get: { model.isWorking || model.succeeded },
                        set: { if $0 { model.clearSelected() } }
                    )) {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(model.succeeded ? "Attributes cleared" : "Clear extended attributes")
                                .font(.headline)
                            Text(model.isWorking ? "Working on this app…" : model.succeeded ? "You’re in control. Open the app when ready." : "Only enable for an app you trust.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .toggleStyle(LargeToggleStyle())
                    .disabled(model.isWorking || model.succeeded)

                    if model.isWorking {
                        ProgressView().controlSize(.small)
                    } else if !model.succeeded {
                        Text("Removes ALL extended attributes recursively, including quarantine. This can remove Gatekeeper’s quarantine prompt; it does not verify that the app is safe. This action cannot be undone by Xattred.")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(20)
                .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 20))

                if let error = model.error {
                    ScrollView {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .font(.caption).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(maxHeight: 90)
                }

                HStack {
                    Text("No admin access. No silent changes.").font(.caption2).foregroundStyle(.secondary)
                    Spacer()
                    Button(model.succeeded ? "Done" : "Not now") { model.dismiss() }
                        .keyboardShortcut(.defaultAction).disabled(model.isWorking)
                }
            }
        }
        .padding(28).frame(width: 480)
    }
}

private struct LargeToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 18) {
            configuration.label
            Spacer(minLength: 0)
            Button { configuration.isOn.toggle() } label: {
                ZStack(alignment: configuration.isOn ? .trailing : .leading) {
                    Capsule().fill(configuration.isOn ? Color.primary : Color.primary.opacity(0.2))
                    Circle()
                        .fill(Color(nsColor: .windowBackgroundColor))
                        .overlay {
                            Image(systemName: configuration.isOn ? "checkmark" : "minus")
                                .font(.system(size: 14, weight: .bold)).foregroundStyle(Color.primary)
                        }
                        .padding(5)
                }
                .frame(width: 82, height: 46)
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Clear extended attributes")
            .accessibilityValue(configuration.isOn ? "On" : "Off")
            .accessibilityHint("Permanently removes all extended attributes from this app")
        }
    }
}

struct SettingsView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Brand()
            VStack(alignment: .leading, spacing: 10) {
                Text("YOUR APPS. YOUR CALL.").font(.caption.weight(.semibold)).tracking(1.4)
                Text("Review a downloaded app before clearing its extended attributes.")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button("Choose App…", systemImage: "plus.app") { model.chooseApp() }
                    .controlSize(.large)
            }
            Divider()
            VStack(alignment: .leading, spacing: 16) {
                Toggle("Open at login", isOn: Binding(get: { model.loginEnabled }, set: model.setLogin))
                if let message = model.loginMessage {
                    Text(message).font(.caption).foregroundStyle(.secondary)
                    Button("Open Login Items") { SMAppService.openSystemSettingsLoginItems() }
                }
                Toggle("Hide menu-bar icon", isOn: $model.hideMenuIcon)
                Text("Xattred keeps running without a Dock icon. Reopen Xattred from Finder to access these settings when the menu-bar icon is hidden.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .toggleStyle(.switch).tint(.primary)
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                Label("Project-local detection only", systemImage: "folder.badge.gearshape").font(.headline)
                Text(AppInspector.inbox.path).font(.caption.monospaced()).textSelection(.enabled)
                Text(model.watcherMessage).font(.caption).foregroundStyle(.secondary)
                Text("New quarantined apps here are reviewed after two stable scans. Nothing outside this Inbox is watched. Apps already here at launch are ignored; use Choose App to review them.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    TextField("GitHub repository URL", text: $model.githubURL)
                        .textFieldStyle(.roundedBorder)
                    Button("GitHub ↗") {
                        if let url = model.validatedGitHubURL { NSWorkspace.shared.open(url) }
                    }.disabled(model.validatedGitHubURL == nil)
                }
                Text("Set your repository’s https://github.com/… link here.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Text("AI-developed · Native Swift · No analytics").font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
        }
        .padding(28).frame(width: 480)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refreshLogin()
        }
    }
}