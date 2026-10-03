// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import R2DropKit

/// What has been copied on this Mac, newest first, and every upload to R2.
/// Kept in Application Support, out of Time Machine, by a ClipboardStore: a
/// SQLite database with a full-text index, and the images as files named by
/// their hash. Password managers' copies and anything that looks like a key or
/// token are never recorded.
@MainActor
final class ClipboardHistory: ObservableObject {
    static let shared = ClipboardHistory()

    static let enabledKey = "clipboardHistory.enabled"
    static let limitKey = "clipboardHistory.limit"
    static let limits = [50, 100, 200, 500]
    static let maxAgeKey = "clipboardHistory.maxAgeDays"
    /// In days; 0 keeps entries however old they are.
    static let maxAges = [7, 30, 90, 365, 0]
    static let skipsTerminalsKey = "clipboardHistory.skipsTerminals"

    static let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("R2Drop/Clipboard")

    /// Longer copies are cut short; images bigger than this are skipped.
    private static let maxTextLength = 100_000
    private static let maxImageBytes = 40_000_000

    /// Changes whenever the history does, so open lists look again.
    @Published private(set) var revision = 0

    private let store: ClipboardStore?
    private let pasteboard = NSPasteboard.general
    private var changeCount = NSPasteboard.general.changeCount
    private var timer: Timer?
    private var pruneTimer: Timer?
    private var thumbnails: [UUID: NSImage] = [:]

    var isRecording: Bool { UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true }

    var limit: Int {
        let stored = UserDefaults.standard.integer(forKey: Self.limitKey)
        return stored > 0 ? stored : 200
    }

    /// nil when entries are kept however old.
    var maxAge: TimeInterval? {
        let days = UserDefaults.standard.object(forKey: Self.maxAgeKey) as? Int ?? 30
        return days > 0 ? TimeInterval(days) * 86_400 : nil
    }

    var skipsTerminals: Bool { UserDefaults.standard.bool(forKey: Self.skipsTerminalsKey) }

    private init() {
        store = try? ClipboardStore(directory: Self.directory)
        // The history from before the database moves into it once.
        try? store?.importLegacyHistory()
        prune()
    }

    /// macOS has no notification for clipboard changes, so the change count
    /// is polled, as every clipboard manager does. Old entries are pruned
    /// hourly, since nothing else may happen to prune them.
    func start() {
        timer?.invalidate()
        changeCount = pasteboard.changeCount
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        pruneTimer?.invalidate()
        pruneTimer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.prune() }
        }
    }

    /// Called right after R2Drop writes the clipboard itself, so the write
    /// isn't recorded as a copy.
    func ignoreCurrentClipboard() {
        changeCount = pasteboard.changeCount
    }

    // MARK: Reading

    func entries(matching query: String, kinds: Set<ClipboardEntry.Kind>?) -> [ClipboardEntry] {
        (try? store?.entries(matching: query, kinds: kinds)) ?? []
    }

    func thumbnail(for entry: ClipboardEntry) -> NSImage? {
        if let cached = thumbnails[entry.id] { return cached }
        guard let data = store?.thumbnail(for: entry.id), let image = NSImage(data: data) else { return nil }
        thumbnails[entry.id] = image
        return image
    }

    func imageFile(of entry: ClipboardEntry) -> URL? {
        guard let sha = entry.image, let url = store?.imageURL(sha), FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    // MARK: Recording

    private func poll() {
        guard pasteboard.changeCount != changeCount else { return }
        changeCount = pasteboard.changeCount
        guard isRecording else { return }
        readClipboard()
    }

    private func readClipboard() {
        let types = Set((pasteboard.types ?? []).map(\.rawValue))
        guard types.isDisjoint(with: ClipboardPolicy.ignoredTypes) else { return }
        let front = NSWorkspace.shared.frontmostApplication
        if let bundle = front?.bundleIdentifier {
            if ClipboardPolicy.ignoredApps.contains(bundle) { return }
            if skipsTerminals, ClipboardPolicy.terminalApps.contains(bundle) { return }
        }
        let source = front?.localizedName

        let files = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        if !files.isEmpty {
            let paths = files.map(\.path).joined(separator: "\n")
            insert(ClipboardEntry(kind: .files, text: paths, fingerprint: "files:" + paths, sourceApp: source))
            return
        }

        let string = pasteboard.string(forType: .string) ?? ""
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        // A browser copies an image with its address beside it, and an editor
        // can copy text with a picture of it: the image wins only in the first case.
        let isAddress = trimmed.isEmpty || (!trimmed.contains(where: \.isWhitespace) && URL(string: trimmed)?.scheme != nil)
        if isAddress, recordImage(source: source) { return }
        guard !trimmed.isEmpty, !ClipboardPolicy.looksSecret(string) else { return }
        let text = String(string.prefix(Self.maxTextLength))
        insert(ClipboardEntry(kind: .text, text: text, fingerprint: "text:" + text, sourceApp: source))
    }

    private func recordImage(source: String?) -> Bool {
        let png: Data?
        if let data = pasteboard.data(forType: .png) {
            png = data
        } else if let tiff = pasteboard.data(forType: .tiff), tiff.count <= Self.maxImageBytes {
            png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
        } else {
            png = nil
        }
        guard let png, png.count <= Self.maxImageBytes, let image = NSImage(data: png),
              let rep = NSBitmapImageRep(data: png), let store, let sha = try? store.storeImage(png) else { return false }
        var entry = ClipboardEntry(kind: .image, text: "", fingerprint: "image:" + sha, sourceApp: source)
        entry.image = sha
        entry.width = rep.pixelsWide
        entry.height = rep.pixelsHigh
        insert(entry, thumbnail: image.thumbnail(maxSide: 128)?.pngData)
        return true
    }

    /// Uploads are listed whether or not they touched the clipboard
    /// (Capture to BlogWatcher leaves it alone), and whether or not copies
    /// are being recorded.
    func recordUpload(_ result: UploadResult, link: String, image file: URL) {
        var entry = ClipboardEntry(kind: .upload, text: link, fingerprint: "upload:" + result.url)
        entry.url = result.url
        entry.filename = result.filename
        if let rep = NSImageRep(contentsOf: file) {
            entry.width = rep.pixelsWide
            entry.height = rep.pixelsHigh
        }
        insert(entry, thumbnail: NSImage(contentsOf: file)?.thumbnail(maxSide: 128)?.pngData)
    }

    private func insert(_ entry: ClipboardEntry, thumbnail: Data? = nil) {
        guard let store, (try? store.insert(entry, thumbnail: thumbnail)) != nil else { return }
        prune()
    }

    // MARK: Changing

    /// Puts an entry back on the clipboard and moves it to the top, as
    /// copying it again would.
    func copy(_ entry: ClipboardEntry) {
        pasteboard.clearContents()
        switch entry.kind {
        case .text, .upload:
            pasteboard.setString(entry.text, forType: .string)
        case .image:
            if let file = imageFile(of: entry), let png = try? Data(contentsOf: file) {
                let item = NSPasteboardItem()
                item.setData(png, forType: .png)
                if let tiff = NSImage(data: png)?.tiffRepresentation {
                    item.setData(tiff, forType: .tiff)
                }
                pasteboard.writeObjects([item])
            }
        case .files:
            pasteboard.writeObjects(entry.paths.map { NSURL(fileURLWithPath: $0) })
        }
        ignoreCurrentClipboard()
        try? store?.touch(entry.id)
        changed()
    }

    func setPinned(_ entry: ClipboardEntry, _ pinned: Bool) {
        try? store?.setPinned(entry.id, pinned)
        changed()
    }

    func delete(_ entry: ClipboardEntry) {
        try? store?.delete(entry.id)
        thumbnails[entry.id] = nil
        changed()
    }

    func clear() {
        try? store?.clear()
        thumbnails = [:]
        changed()
    }

    /// Drops what is past the limits set in Settings; pinned entries stay.
    func prune() {
        try? store?.prune(keep: limit, maxAge: maxAge)
        changed()
    }

    private func changed() {
        revision += 1
    }

    // MARK: BlogWatcher

    /// Sends an entry to the BlogWatcher inbox: text and links as they are,
    /// an image uploaded to R2 first with the text recognised in it, an upload
    /// by its link.
    func saveToInbox(_ entry: ClipboardEntry) async {
        let inbox: InboxSettings
        do {
            inbox = try AppSettings.inbox.validated()
        } catch {
            HUD.shared.show(error.localizedDescription, style: .failure)
            return
        }
        switch entry.kind {
        case .image:
            guard let file = imageFile(of: entry) else {
                HUD.shared.show("The image is no longer on this Mac.", style: .failure)
                return
            }
            await Uploader.uploadToInbox(file)
        case .text, .upload:
            HUD.shared.show("Saving to BlogWatcher…", style: .progress)
            do {
                let client = InboxClient(settings: inbox)
                if entry.kind == .upload, let url = entry.url {
                    try await client.save(images: [url], text: "")
                } else {
                    try await client.save(text: entry.text)
                }
                HUD.shared.show("Saved to BlogWatcher")
            } catch {
                HUD.shared.show("Not saved — \(error.localizedDescription)", style: .failure)
            }
        case .files:
            HUD.shared.show("Files can't be saved to BlogWatcher; copy their contents instead.", style: .failure)
        }
    }
}

extension NSImage {
    var pngData: Data? {
        guard let tiff = tiffRepresentation else { return nil }
        return NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
    }
}
