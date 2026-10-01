// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import R2DropKit
import SwiftUI

enum Command: String, CaseIterable {
    case captureAndUpload, uploadClipboard, uploadImage, uploadFinderSelection, showLastUpload, captureToInbox

    var title: String {
        switch self {
        case .captureAndUpload: "Capture & Upload"
        case .uploadClipboard: "Upload Clipboard Image"
        case .uploadImage: "Upload Image…"
        case .uploadFinderSelection: "Upload Finder Selection"
        case .showLastUpload: "Preview Last Upload"
        case .captureToInbox: "Capture to BlogWatcher"
        }
    }

    var symbol: String {
        switch self {
        case .captureAndUpload: "camera.viewfinder"
        case .uploadClipboard: "doc.on.clipboard"
        case .uploadImage: "photo"
        case .uploadFinderSelection: "folder"
        case .showLastUpload: "eye"
        case .captureToInbox: "tray.and.arrow.down"
        }
    }

    var detail: String {
        switch self {
        case .captureAndUpload: "Screenshot a region or window, upload it, and copy the link."
        case .uploadClipboard: "Upload the image on the clipboard and replace it with the link."
        case .uploadImage: "Pick one or more images, a format and an optional name."
        case .uploadFinderSelection: "Upload the images selected in Finder."
        case .showLastUpload: "Preview the most recent upload and copy its link."
        case .captureToInbox: "Screenshot a region or window and save it, with its text, to your BlogWatcher inbox."
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var settingsWindow: NSWindow?
    private var previewWindow: NSWindow?
    private var isBusy = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMainMenu()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            let image = Bundle.main.image(forResource: "MenuBarIcon")
                ?? NSImage(systemSymbolName: "icloud.and.arrow.up", accessibilityDescription: nil)
            // The cloud is over twice as wide as it is tall, so it is drawn
            // shorter than the square icons beside it to take up about as much room.
            if let image, image.size.height > 0 {
                image.size = NSSize(width: 11 * image.size.width / image.size.height, height: 11)
            }
            image?.isTemplate = true
            image?.accessibilityDescription = "R2Drop"
            button.image = image
            button.toolTip = "R2Drop"
        }
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        installDropTarget()

        for command in Command.allCases {
            HotKeyCenter.shared.register(command.rawValue) { [weak self] in self?.run(command) }
        }

        if !AppSettings.isConfigured {
            openSettings(nil)
        }
    }

    /// A transparent view over the status item button that accepts dropped files.
    private func installDropTarget() {
        guard let button = statusItem.button else { return }
        let target = DropTargetView(frame: button.bounds)
        target.autoresizingMask = [.width, .height]
        target.onDrop = { [weak self] urls in self?.upload(urls) }
        button.addSubview(target)
    }

    // MARK: Commands

    func run(_ command: Command) {
        switch command {
        case .captureAndUpload: captureAndUpload()
        case .uploadClipboard: uploadClipboard()
        case .uploadImage: uploadImage()
        case .uploadFinderSelection: uploadFinderSelection()
        case .showLastUpload: showLastUpload()
        case .captureToInbox: captureToInbox()
        }
    }

    private func guardConfigured() -> Bool {
        do {
            _ = try AppSettings.r2.validated()
            return true
        } catch {
            HUD.shared.show(error.localizedDescription, style: .failure)
            return false
        }
    }

    private func captureAndUpload() {
        capture { await Uploader.uploadAndCopy([$0]) }
    }

    private func captureToInbox() {
        do {
            _ = try AppSettings.inbox.validated()
        } catch {
            HUD.shared.show(error.localizedDescription, style: .failure)
            return
        }
        capture { await Uploader.uploadToInbox($0) }
    }

    /// Takes an interactive screenshot and hands the file to `upload`.
    private func capture(then upload: @escaping (URL) async -> Void) {
        // Fail fast on missing settings before opening the crosshair.
        guard !isBusy, guardConfigured() else { return }
        if !CGPreflightScreenCaptureAccess() {
            CGRequestScreenCaptureAccess()
            HUD.shared.show("Capturing needs Screen Recording access. Turn it on in System Settings → Privacy & Security.",
                            style: .failure)
            return
        }
        isBusy = true
        Task {
            defer { isBusy = false }
            guard let shot = await ImageSources.captureScreenshot() else { return }  // Esc: nothing to do.
            defer { shot.remove() }
            await upload(shot.url)
        }
    }

    private func uploadClipboard() {
        guard !isBusy, guardConfigured() else { return }
        guard let image = ImageSources.clipboardImage() else {
            HUD.shared.show("No image on the clipboard. Copy an image or a screenshot first.", style: .failure)
            return
        }
        isBusy = true
        Task {
            defer { isBusy = false }
            switch image {
            case let .file(url):
                await Uploader.uploadAndCopy([url])
            case let .data(temporary):
                // The link replaces the image that was just uploaded; that's
                // the point: copy an image, run this, paste the link.
                await Uploader.uploadAndCopy([temporary.url])
                temporary.remove()
            }
        }
    }

    private func uploadFinderSelection() {
        guard !isBusy, guardConfigured() else { return }
        let files: [URL]
        do {
            files = try ImageSources.finderSelection().filter { ObjectKey.isImage($0.path) }
        } catch {
            HUD.shared.show(error.localizedDescription, style: .failure)
            return
        }
        guard !files.isEmpty else {
            HUD.shared.show("No images selected. Select one or more image files in Finder.", style: .failure)
            return
        }
        upload(files)
    }

    private func upload(_ files: [URL]) {
        let images = files.filter { ObjectKey.isImage($0.path) }
        guard !isBusy, guardConfigured() else { return }
        guard !images.isEmpty else {
            HUD.shared.show("Only images can be uploaded.", style: .failure)
            return
        }
        isBusy = true
        Task {
            defer { isBusy = false }
            await Uploader.uploadAndCopy(images)
        }
    }

    /// An open panel with the output format and an optional name below it,
    /// in place of the extension's form.
    private func uploadImage() {
        guard !isBusy, guardConfigured() else { return }
        let options = UploadOptions()
        let panel = NSOpenPanel()
        panel.title = "Upload Image"
        panel.prompt = "Upload"
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.image]
        let accessory = NSHostingView(rootView: UploadOptionsView(options: options))
        accessory.frame.size = accessory.fittingSize
        panel.accessoryView = accessory
        panel.isAccessoryViewDisclosed = true
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        // A name only makes sense for a single file; with several, each keeps
        // its own so the links stay distinguishable.
        let slug = options.name.trimmingCharacters(in: .whitespacesAndNewlines)
        isBusy = true
        Task {
            defer { isBusy = false }
            await Uploader.uploadAndCopy(panel.urls, slug: slug.isEmpty ? nil : slug, format: options.format)
        }
    }

    private func showLastUpload() {
        guard let last = LastUpload.saved else {
            HUD.shared.show("No uploads yet.", style: .failure)
            return
        }
        previewWindow?.close()
        let window = NSWindow(contentViewController: NSHostingController(rootView: LastUploadView(upload: last)))
        window.title = last.filename
        window.styleMask = [.titled, .closable, .resizable]
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 640, height: 520))
        window.center()
        previewWindow = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    @objc private func copyLastLink() {
        guard let last = LastUpload.saved else { return }
        let format = AppSettings.format
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(format.format(url: last.url, filename: last.filename), forType: .string)
        HUD.shared.show("Copied \(format.label) link")
    }

    @objc private func runMenuCommand(_ sender: NSMenuItem) {
        if let command = Command(rawValue: sender.representedObject as? String ?? "") {
            run(command)
        }
    }

    @objc func openSettings(_ sender: Any?) {
        if settingsWindow == nil {
            settingsWindow = makeSettingsWindow()
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    // MARK: Menus

    /// Built each time it opens, so the last upload and the shortcuts are current.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        if !AppSettings.isConfigured {
            let item = NSMenuItem(title: "Configure R2 Settings…", action: #selector(openSettings(_:)), keyEquivalent: "")
            item.target = self
            item.image = NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: nil)
            menu.addItem(item)
            menu.addItem(.separator())
        }

        menu.addItem(sectionHeader("Last Upload"))
        if let last = LastUpload.saved {
            let item = NSMenuItem(title: last.filename, action: #selector(copyLastLink), keyEquivalent: "")
            item.target = self
            if #available(macOS 14.4, *) {
                item.subtitle = "Copy \(AppSettings.format.label) Link"
            } else {
                item.toolTip = "Copy \(AppSettings.format.label) Link"
            }
            let thumbnail = LastUpload.thumbnail ?? NSImage(systemSymbolName: "photo", accessibilityDescription: nil)
            thumbnail?.size = NSSize(width: 32, height: 32 * (thumbnail.map { $0.size.height / max($0.size.width, 1) } ?? 1))
            item.image = thumbnail
            menu.addItem(item)
            menu.addItem(commandItem(.showLastUpload))
        } else {
            let item = NSMenuItem(title: "No Uploads Yet", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }

        menu.addItem(.separator())
        menu.addItem(sectionHeader("Upload"))
        for command in [Command.captureAndUpload, .uploadClipboard, .uploadImage, .uploadFinderSelection] {
            menu.addItem(commandItem(command))
        }
        if (try? AppSettings.inbox.validated()) != nil {
            menu.addItem(.separator())
            menu.addItem(commandItem(.captureToInbox))
        }
        menu.addItem(.separator())
        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettings(_:)), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        menu.addItem(withTitle: "Quit R2Drop", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    }

    private func sectionHeader(_ title: String) -> NSMenuItem {
        if #available(macOS 14, *) {
            return NSMenuItem.sectionHeader(title: title)
        }
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func commandItem(_ command: Command) -> NSMenuItem {
        let item = NSMenuItem(title: command.title, action: #selector(runMenuCommand(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = command.rawValue
        item.image = NSImage(systemSymbolName: command.symbol, accessibilityDescription: nil)
        if let shortcut = HotKeyCenter.shared.shortcuts[command.rawValue], let key = shortcut.menuKeyEquivalent {
            item.keyEquivalent = key
            item.keyEquivalentModifierMask = shortcut.flags
        }
        return item
    }

    /// Accessory apps have no visible menu bar, but the main menu still routes
    /// key equivalents; without it ⌘C, ⌘V and ⌘A don't work in text fields.
    private func setupMainMenu() {
        let mainMenu = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Settings…", action: #selector(openSettings(_:)), keyEquivalent: ",").target = self
        appMenu.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        appMenu.addItem(withTitle: "Quit R2Drop", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)
        NSApp.mainMenu = mainMenu
    }
}

/// Accepts files dropped on the menu bar icon. It sits on top of the button,
/// so it hands clicks down to it to open the menu.
final class DropTargetView: NSView {
    var onDrop: ([URL]) -> Void = { _ in }

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func mouseDown(with event: NSEvent) { superview?.mouseDown(with: event) }
    override func rightMouseDown(with event: NSEvent) { superview?.rightMouseDown(with: event) }

    private func urls(_ info: NSDraggingInfo) -> [URL] {
        info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        urls(sender).contains { ObjectKey.isImage($0.path) } ? .copy : []
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let dropped = urls(sender)
        guard !dropped.isEmpty else { return false }
        onDrop(dropped)
        return true
    }
}

final class UploadOptions: ObservableObject {
    @Published var format = AppSettings.format
    @Published var name = ""
}

private struct UploadOptionsView: View {
    @ObservedObject var options: UploadOptions

    var body: some View {
        Form {
            Picker("Output Format", selection: $options.format) {
                ForEach(OutputFormat.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            TextField("Name", text: $options.name, prompt: Text("auto (only used for a single file)"))
        }
        .frame(width: 380)
        .padding(12)
    }
}
