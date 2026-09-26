// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import R2DropKit

/// Where the images come from: a screenshot, the clipboard, Finder.
enum ImageSources {
    /// A scratch file the caller removes when done.
    struct Temporary {
        let url: URL
        func remove() { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    }

    private static func scratchDirectory() -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("r2drop-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// The native interactive screenshot (region, or Space for a window). nil when cancelled.
    static func captureScreenshot() async -> Temporary? {
        let directory = scratchDirectory()
        let file = directory.appendingPathComponent("screenshot.png")
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            process.arguments = ["-i", file.path]
            process.terminationHandler = { _ in continuation.resume() }
            do {
                try process.run()
            } catch {
                continuation.resume()
            }
        }
        guard FileManager.default.fileExists(atPath: file.path) else {
            try? FileManager.default.removeItem(at: directory)
            return nil
        }
        return Temporary(url: file)
    }

    enum ClipboardImage {
        /// A copied image file, e.g. ⌘C on a Finder item.
        case file(URL)
        /// Raw image data (a copied screenshot, an image copied from a browser), saved as PNG.
        case data(Temporary)
    }

    static func clipboardImage() -> ClipboardImage? {
        let pasteboard = NSPasteboard.general
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        if let file = urls.first(where: { ObjectKey.isImage($0.path) && FileManager.default.fileExists(atPath: $0.path) }) {
            return .file(file)
        }
        let png: Data?
        if let data = pasteboard.data(forType: .png) {
            png = data
        } else if let tiff = pasteboard.data(forType: .tiff) {
            png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
        } else {
            png = nil
        }
        guard let png else { return nil }
        let file = scratchDirectory().appendingPathComponent("clipboard.png")
        guard (try? png.write(to: file)) != nil else { return nil }
        return .data(Temporary(url: file))
    }

    /// The items selected in the frontmost Finder window, through Apple Events.
    static func finderSelection() throws -> [URL] {
        let source = """
        tell application "Finder"
            set picked to selection as alias list
            set output to ""
            repeat with anItem in picked
                set output to output & POSIX path of anItem & linefeed
            end repeat
            return output
        end tell
        """
        var error: NSDictionary?
        guard let result = NSAppleScript(source: source)?.executeAndReturnError(&error) else {
            let number = error?[NSAppleScript.errorNumber] as? Int
            if number == -1743 {
                throw R2Error("R2Drop isn't allowed to control Finder. Turn it on in System Settings → Privacy & Security → Automation.")
            }
            throw R2Error("No Finder selection. Select images in Finder first.")
        }
        return (result.stringValue ?? "")
            .split(separator: "\n").map { URL(fileURLWithPath: String($0)) }
    }
}
