// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import R2DropKit
import ServiceManagement
import SwiftUI

/// A preferences window with toolbar tabs, like the system's own apps.
@MainActor
func makeSettingsWindow() -> NSWindow {
    let tabs = NSTabViewController()
    tabs.tabStyle = .toolbar
    tabs.addTabViewItem(settingsTab("R2", symbol: "cloud", R2SettingsView()))
    tabs.addTabViewItem(settingsTab("BlogWatcher", symbol: "tray.and.arrow.down", InboxSettingsView()))
    tabs.addTabViewItem(settingsTab("Shortcuts", symbol: "keyboard", ShortcutsSettingsView()))
    tabs.addTabViewItem(settingsTab("General", symbol: "gearshape", GeneralSettingsView()))

    let window = NSWindow(contentViewController: tabs)
    window.styleMask = [.titled, .closable]
    window.toolbarStyle = .preference
    window.isReleasedWhenClosed = false
    window.center()
    return window
}

private func settingsTab<Content: View>(_ label: String, symbol: String, _ view: Content) -> NSTabViewItem {
    let controller = NSHostingController(rootView: view)
    controller.sizingOptions = .preferredContentSize
    controller.title = label
    let item = NSTabViewItem(viewController: controller)
    item.label = label
    item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
    return item
}

private struct R2SettingsView: View {
    @AppStorage(AppSettings.accountIDKey) private var accountID = ""
    @AppStorage(AppSettings.bucketKey) private var bucket = ""
    @AppStorage(AppSettings.accessKeyIDKey) private var accessKeyID = ""
    @AppStorage(AppSettings.publicBaseURLKey) private var publicBaseURL = ""
    @AppStorage(AppSettings.formatKey) private var format = OutputFormat.markdown.rawValue
    @State private var secret = Keychain.read(AppSettings.secretAccount)

    var body: some View {
        Form {
            Section {
                TextField("Account ID", text: $accountID)
                TextField("Bucket", text: $bucket)
                TextField("Access Key ID", text: $accessKeyID)
                SecureField("Secret Access Key", text: $secret)
                    .onChange(of: secret) { _, value in Keychain.write(value, for: AppSettings.secretAccount) }
                TextField("Public Base URL", text: $publicBaseURL, prompt: Text("https://img.example.com"))
                ForEach(problems, id: \.self) { problem in
                    Label(problem, systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } header: {
                Text("Bucket")
            } footer: {
                Text("An R2 S3 API token with write access to the bucket, and the public URL it is served from — ideally a custom domain bound to the bucket. The secret is kept in your login keychain and only ever sent to Cloudflare, signed; there is no server in between.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Section {
                Picker("Copy after upload", selection: $format) {
                    ForEach(OutputFormat.allCases, id: \.self) { Text($0.title).tag($0.rawValue) }
                }
            } footer: {
                Text("Objects are stored as yyyy/mm/<name>-<hash>.<ext>, e.g. 2026/09/team-list-a8f31c.png.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 460)
    }

    private var problems: [String] {
        R2Settings(accountID: accountID, bucket: bucket, accessKeyID: accessKeyID,
                   secretAccessKey: secret, publicBaseURL: publicBaseURL).credentialProblems
    }
}

private struct InboxSettingsView: View {
    @AppStorage(AppSettings.inboxEndpointKey) private var endpoint = ""
    @State private var key = Keychain.read(AppSettings.inboxKeyAccount)

    var body: some View {
        Form {
            Section {
                TextField("Capture URL", text: $endpoint, prompt: Text("https://blogwatcher.example.com/api/capture"))
                SecureField("Key", text: $key)
                    .onChange(of: key) { _, value in Keychain.write(value, for: AppSettings.inboxKeyAccount) }
            } header: {
                Text("Inbox")
            } footer: {
                Text("Capture to BlogWatcher uploads a screenshot to your bucket, then saves its link and the text in it to your BlogWatcher inbox. Use the deployment's CAPTURE_KEY, or its sync key. The key is kept in your login keychain. Give the command a shortcut under Shortcuts.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 240)
    }
}

private struct ShortcutsSettingsView: View {
    var body: some View {
        Form {
            Section {
                ForEach(Command.allCases, id: \.self) { command in
                    LabeledContent {
                        ShortcutRecorder(command.rawValue)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(command.title)
                            Text(command.detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            } footer: {
                Text("Shortcuts work in every app. You can also drop images on the menu bar icon.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 440)
    }
}

private struct GeneralSettingsView: View {
    @State private var launchesAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?

    var body: some View {
        Form {
            Section {
                Toggle("Open R2Drop at login", isOn: Binding(get: { launchesAtLogin }, set: setLaunchAtLogin))
                if let loginError {
                    Text(loginError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            Section {
                LabeledContent("Screen Recording") {
                    Button("Open Privacy Settings") {
                        CGRequestScreenCaptureAccess()
                        open("Privacy_ScreenCapture")
                    }
                }
                LabeledContent("Automation (Finder)") {
                    Button("Open Privacy Settings") { open("Privacy_Automation") }
                }
            } header: {
                Text("Permissions")
            } footer: {
                Text("Screen Recording is needed for Capture & Upload, and control of Finder for Upload Finder Selection. macOS asks the first time each is used.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 300)
    }

    private func open(_ anchor: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            loginError = nil
        } catch {
            loginError = error.localizedDescription
        }
        launchesAtLogin = SMAppService.mainApp.status == .enabled
    }
}

/// The most recent upload at full size, with its details and links.
struct LastUploadView: View {
    let upload: LastUpload
    private var format: OutputFormat { AppSettings.format }

    var body: some View {
        VStack(spacing: 0) {
            AsyncImage(url: URL(string: upload.url)) { phase in
                switch phase {
                case let .success(image):
                    image.resizable().scaledToFit()
                case .failure:
                    Label("Could not load the image", systemImage: "photo.badge.exclamationmark")
                        .foregroundStyle(.secondary)
                default:
                    ProgressView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(16)
            .background(Color.primary.opacity(0.03))

            Divider()
            HStack(alignment: .top, spacing: 16) {
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 4) {
                    GridRow { Text("Key").foregroundStyle(.secondary); Text(upload.key).textSelection(.enabled) }
                    GridRow {
                        Text("Uploaded").foregroundStyle(.secondary)
                        Text(upload.uploadedAt.formatted(date: .abbreviated, time: .shortened))
                    }
                    GridRow {
                        Text("URL").foregroundStyle(.secondary)
                        Link(upload.url, destination: URL(string: upload.url)!).lineLimit(1).truncationMode(.middle)
                    }
                }
                .font(.system(size: 12))
                Spacer()
                VStack(alignment: .trailing, spacing: 6) {
                    Button("Copy \(format.label) Link") {
                        copy(format.format(url: upload.url, filename: upload.filename), label: "\(format.label) link")
                    }
                    .keyboardShortcut(.defaultAction)
                    HStack {
                        Button("Copy URL") { copy(upload.url, label: "URL") }
                            .keyboardShortcut("c", modifiers: .command)
                        Button("Open in Browser") {
                            if let url = URL(string: upload.url) { NSWorkspace.shared.open(url) }
                        }
                    }
                }
            }
            .padding(16)
        }
        .frame(minWidth: 480, minHeight: 360)
    }

    private func copy(_ text: String, label: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        HUD.shared.show("Copied \(label)")
    }
}
