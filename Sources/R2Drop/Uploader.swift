// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import R2DropKit

enum AppSettings {
    static let accountIDKey = "accountID"
    static let bucketKey = "bucket"
    static let accessKeyIDKey = "accessKeyID"
    static let publicBaseURLKey = "publicBaseURL"
    static let formatKey = "defaultFormat"
    static let secretAccount = "secretAccessKey"
    static let inboxEndpointKey = "inboxEndpoint"
    static let inboxKeyAccount = "inboxKey"

    static var r2: R2Settings { r2(secret: Keychain.read(secretAccount)) }

    private static func r2(secret: String) -> R2Settings {
        let defaults = UserDefaults.standard
        return R2Settings(accountID: defaults.string(forKey: accountIDKey) ?? "",
                          bucket: defaults.string(forKey: bucketKey) ?? "",
                          accessKeyID: defaults.string(forKey: accessKeyIDKey) ?? "",
                          secretAccessKey: secret,
                          publicBaseURL: defaults.string(forKey: publicBaseURLKey) ?? "")
    }

    static var format: OutputFormat {
        OutputFormat(rawValue: UserDefaults.standard.string(forKey: formatKey) ?? "") ?? .markdown
    }

    // These two run at launch and every time the menu opens, so they only ask
    // whether a secret is stored. Reading it can raise a keychain prompt, and
    // one raised while the menu is open can't be typed into: the menu holds
    // the keyboard while it waits for the prompt.

    static var isConfigured: Bool {
        Keychain.contains(secretAccount) && (try? r2(secret: "stored").validated()) != nil
    }

    static var hasInbox: Bool {
        Keychain.contains(inboxKeyAccount) && (try? inbox(key: "stored").validated()) != nil
    }

    static var inbox: InboxSettings { inbox(key: Keychain.read(inboxKeyAccount)) }

    private static func inbox(key: String) -> InboxSettings {
        InboxSettings(endpoint: UserDefaults.standard.string(forKey: inboxEndpointKey) ?? "", key: key)
    }
}

/// The most recent upload, from any command, for the menu's quick copy and
/// the preview window. A small thumbnail is kept beside it so the menu never
/// has to download the image.
struct LastUpload: Codable, Equatable {
    let key: String
    let url: String
    let filename: String
    let uploadedAt: Date

    private static let storageKey = "lastUpload"

    static var saved: LastUpload? {
        guard let data = UserDefaults.standard.data(forKey: storageKey) else { return nil }
        return try? JSONDecoder().decode(LastUpload.self, from: data)
    }

    func save(thumbnailFrom file: URL) {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.storageKey)
        }
        if let image = NSImage(contentsOf: file), let thumbnail = image.thumbnail(maxSide: 64),
           let tiff = thumbnail.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            try? FileManager.default.createDirectory(at: Self.thumbnailURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? png.write(to: Self.thumbnailURL)
        } else {
            try? FileManager.default.removeItem(at: Self.thumbnailURL)
        }
    }

    static var thumbnail: NSImage? { NSImage(contentsOf: thumbnailURL) }

    static let thumbnailURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("R2Drop/last-upload-thumbnail.png")
}

extension NSImage {
    func thumbnail(maxSide: CGFloat) -> NSImage? {
        guard size.width > 0, size.height > 0 else { return nil }
        let scale = min(1, maxSide / max(size.width, size.height))
        let target = NSSize(width: max(1, size.width * scale), height: max(1, size.height * scale))
        return NSImage(size: target, flipped: false) { rect in
            self.draw(in: rect)
            return true
        }
    }
}

struct UploadResult {
    let key: String
    let url: String
    let filename: String
}

@MainActor
enum Uploader {
    /// Uploads one local file and returns its public URL. `slug` names the
    /// object when given; otherwise the file name does. Every success is
    /// recorded as the last upload.
    static func upload(_ file: URL, slug: String? = nil, hash: String = ObjectKey.randomHash(),
                       settings: R2Settings) async throws -> UploadResult {
        let filename = file.lastPathComponent
        let body: Data
        do {
            body = try Data(contentsOf: file)
        } catch {
            throw R2Error("Could not read \(filename).")
        }
        let key = ObjectKey.build(originalName: filename, slug: slug, hash: hash)
        let contentType = ObjectKey.contentType(forExtension: (key as NSString).pathExtension)
        try await R2Client(settings: settings).put(key: key, body: body, contentType: contentType)
        let result = UploadResult(key: key, url: settings.publicURL(for: key), filename: filename)
        LastUpload(key: key, url: result.url, filename: filename, uploadedAt: Date()).save(thumbnailFrom: file)
        return result
    }

    /// Uploads files one by one, copies every link that worked (one per
    /// line), and reports the rest.
    static func uploadAndCopy(_ files: [URL], slug: String? = nil, format: OutputFormat = AppSettings.format) async {
        let settings: R2Settings
        do {
            settings = try AppSettings.r2.validated()
        } catch {
            HUD.shared.show(error.localizedDescription, style: .failure)
            return
        }
        HUD.shared.show(files.count == 1 ? "Uploading…" : "Uploading \(files.count) images…", style: .progress)
        var links: [String] = []
        var failures: [String] = []
        for file in files {
            do {
                let result = try await upload(file, slug: files.count == 1 ? slug : nil, settings: settings)
                let link = format.format(url: result.url, filename: result.filename)
                links.append(link)
                ClipboardHistory.shared.recordUpload(result, link: link, image: file)
            } catch {
                failures.append("\(file.lastPathComponent): \(error.localizedDescription)")
            }
        }
        if !links.isEmpty {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(links.joined(separator: "\n"), forType: .string)
            // Listed as uploads above; not again as copied text.
            ClipboardHistory.shared.ignoreCurrentClipboard()
        }
        if let first = failures.first {
            let title = links.isEmpty ? "Upload failed" : "Uploaded \(links.count), \(failures.count) failed"
            HUD.shared.show("\(title) — \(first)", style: .failure)
        } else if links.count == 1 {
            HUD.shared.show("Copied \(format.label) link")
        } else {
            HUD.shared.show("Copied \(links.count) links")
        }
        NotificationCenter.default.post(name: .lastUploadChanged, object: nil)
    }
}

extension Uploader {
    /// Uploads one image and saves it to the BlogWatcher inbox with the text
    /// in it, so it can be found by searching. The clipboard is left alone.
    static func uploadToInbox(_ file: URL) async {
        let settings: R2Settings
        let inbox: InboxSettings
        do {
            settings = try AppSettings.r2.validated()
            inbox = try AppSettings.inbox.validated()
        } catch {
            HUD.shared.show(error.localizedDescription, style: .failure)
            return
        }
        HUD.shared.show("Saving to BlogWatcher…", style: .progress)
        do {
            // Nothing else guards an inbox image but its link, so the link
            // gets a longer random part than a shared one.
            async let text = TextRecognizer.text(in: file)
            let result = try await upload(file, hash: ObjectKey.randomHash(bytes: 8), settings: settings)
            ClipboardHistory.shared.recordUpload(result, link: result.url, image: file)
            NotificationCenter.default.post(name: .lastUploadChanged, object: nil)
            try await InboxClient(settings: inbox).save(images: [result.url], text: await text)
            HUD.shared.show("Saved to BlogWatcher")
        } catch {
            HUD.shared.show("Not saved — \(error.localizedDescription)", style: .failure)
        }
    }
}

extension Notification.Name {
    static let lastUploadChanged = Notification.Name("lastUploadChanged")
}
