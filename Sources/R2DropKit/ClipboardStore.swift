// SPDX-License-Identifier: GPL-3.0-or-later
import CryptoKit
import Foundation
import SQLite3

/// One thing that was on the clipboard, or one upload to R2.
public struct ClipboardEntry: Codable, Identifiable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case text, image, files, upload
    }

    public let id: UUID
    public var kind: Kind
    /// When it was last copied, or copied again from the history.
    public var date: Date
    /// When it was first recorded.
    public var created: Date
    /// The text; copied files' paths, one per line; the link an upload copied.
    public var text: String
    /// What makes two entries the same: the text, an image's hash, an upload's URL.
    public var fingerprint: String
    /// The app that was in front when it was copied.
    public var sourceApp: String?
    public var url: String?
    public var filename: String?
    public var width: Int?
    public var height: Int?
    /// The SHA-256 of a copied image, which names its file.
    public var image: String?
    /// Pinned entries stay at the top and are never pruned.
    public var pinned = false

    public init(id: UUID = UUID(), kind: Kind, text: String, fingerprint: String, sourceApp: String? = nil, date: Date = Date()) {
        self.id = id
        self.kind = kind
        self.date = date
        created = date
        self.text = text
        self.fingerprint = fingerprint
        self.sourceApp = sourceApp
    }

    public var paths: [String] { kind == .files ? text.components(separatedBy: "\n") : [] }

    /// A line for lists and menus.
    public var title: String {
        switch kind {
        case .text:
            return text.split(whereSeparator: \.isNewline).lazy
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .first { !$0.isEmpty } ?? text
        case .image:
            if let width, let height { return "Image \(width) × \(height)" }
            return "Image"
        case .files:
            let paths = paths
            return paths.count == 1 ? (paths[0] as NSString).lastPathComponent : "\(paths.count) Files"
        case .upload:
            return filename ?? url ?? text
        }
    }

    /// What a search looks through. Very long text is only searched in its
    /// first part, which keeps the index small.
    var searchText: String {
        [String(text.prefix(20_000)), title, sourceApp ?? "", url ?? "", filename ?? ""].joined(separator: "\n")
    }
}

/// The clipboard history on disk: a SQLite database with a full-text index,
/// and copied images as files named by their SHA-256, so an image copied many
/// times is stored once. The directory is kept out of Time Machine.
public final class ClipboardStore {
    public let directory: URL
    private var db: OpaquePointer?

    public init(directory: URL) throws {
        self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var excluded = directory
        try? excluded.setResourceValues(values)

        guard sqlite3_open(directory.appendingPathComponent("history.sqlite").path, &db) == SQLITE_OK else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "cannot open"
            sqlite3_close(db)
            throw R2Error("Could not open the clipboard history: \(message)")
        }
        try execute("""
            PRAGMA journal_mode = WAL;
            -- Deleted entries are overwritten on disk, not just unlinked.
            PRAGMA secure_delete = ON;
            CREATE TABLE IF NOT EXISTS entries (
                id TEXT PRIMARY KEY,
                kind TEXT NOT NULL,
                text TEXT NOT NULL,
                fingerprint TEXT NOT NULL UNIQUE,
                source_app TEXT,
                url TEXT,
                filename TEXT,
                width INTEGER,
                height INTEGER,
                image TEXT,
                thumbnail BLOB,
                pinned INTEGER NOT NULL DEFAULT 0,
                created REAL NOT NULL,
                used REAL NOT NULL,
                search TEXT NOT NULL
            );
            CREATE INDEX IF NOT EXISTS entries_used ON entries (pinned DESC, used DESC);
            -- Trigrams find any part of a word, in Chinese as in English.
            CREATE VIRTUAL TABLE IF NOT EXISTS entries_fts USING fts5(
                search, content = 'entries', content_rowid = 'rowid', tokenize = 'trigram');
            CREATE TRIGGER IF NOT EXISTS entries_ai AFTER INSERT ON entries BEGIN
                INSERT INTO entries_fts (rowid, search) VALUES (new.rowid, new.search);
            END;
            CREATE TRIGGER IF NOT EXISTS entries_ad AFTER DELETE ON entries BEGIN
                INSERT INTO entries_fts (entries_fts, rowid, search) VALUES ('delete', old.rowid, old.search);
            END;
            CREATE TRIGGER IF NOT EXISTS entries_au AFTER UPDATE OF search ON entries BEGIN
                INSERT INTO entries_fts (entries_fts, rowid, search) VALUES ('delete', old.rowid, old.search);
                INSERT INTO entries_fts (rowid, search) VALUES (new.rowid, new.search);
            END;
            """)
    }

    deinit {
        sqlite3_close(db)
    }

    // MARK: Writing

    /// Records an entry. Copying something already in the history moves it to
    /// the top instead of adding it again; the stored entry is returned.
    @discardableResult
    public func insert(_ entry: ClipboardEntry, thumbnail: Data? = nil) throws -> ClipboardEntry {
        try run("""
            INSERT INTO entries (id, kind, text, fingerprint, source_app, url, filename, width, height,
                                 image, thumbnail, pinned, created, used, search)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT (fingerprint) DO UPDATE SET
                used = excluded.used,
                source_app = coalesce(excluded.source_app, source_app),
                url = coalesce(excluded.url, url),
                filename = coalesce(excluded.filename, filename),
                thumbnail = coalesce(excluded.thumbnail, thumbnail)
            """, [entry.id.uuidString, entry.kind.rawValue, entry.text, entry.fingerprint, entry.sourceApp, entry.url,
                  entry.filename, entry.width, entry.height, entry.image, thumbnail, entry.pinned ? 1 : 0,
                  entry.created.timeIntervalSince1970, entry.date.timeIntervalSince1970, entry.searchText])
        return try entries(where: "fingerprint = ?", [entry.fingerprint]).first ?? entry
    }

    /// Marks an entry as just used, which moves it to the top.
    public func touch(_ id: UUID, at date: Date = Date()) throws {
        try run("UPDATE entries SET used = ? WHERE id = ?", [date.timeIntervalSince1970, id.uuidString])
    }

    public func setPinned(_ id: UUID, _ pinned: Bool) throws {
        try run("UPDATE entries SET pinned = ? WHERE id = ?", [pinned ? 1 : 0, id.uuidString])
    }

    public func delete(_ id: UUID) throws {
        try run("DELETE FROM entries WHERE id = ?", [id.uuidString])
        removeUnusedImages()
    }

    public func clear() throws {
        try execute("DELETE FROM entries; INSERT INTO entries_fts (entries_fts) VALUES ('rebuild');")
        try? FileManager.default.removeItem(at: imagesDirectory)
        try? execute("VACUUM;")
    }

    /// Removes what is past the limits: beyond the newest `keep` entries, or
    /// not used for longer than `maxAge` (nil keeps any age). Pinned entries stay.
    public func prune(keep: Int, maxAge: TimeInterval?, now: Date = Date()) throws {
        let oldest = maxAge.map { now.timeIntervalSince1970 - $0 } ?? -Double.infinity
        try run("""
            DELETE FROM entries WHERE pinned = 0 AND (used < ? OR id IN (
                SELECT id FROM entries WHERE pinned = 0 ORDER BY used DESC LIMIT -1 OFFSET ?))
            """, [oldest, keep])
        removeUnusedImages()
    }

    // MARK: Images

    private var imagesDirectory: URL { directory.appendingPathComponent("images", isDirectory: true) }

    public func imageURL(_ sha: String) -> URL {
        imagesDirectory.appendingPathComponent(String(sha.prefix(2)), isDirectory: true).appendingPathComponent("\(sha).png")
    }

    /// Stores a PNG under its SHA-256, once however often it is copied, and
    /// returns the hash.
    public func storeImage(_ png: Data) throws -> String {
        let sha = SHA256.hash(data: png).map { String(format: "%02x", $0) }.joined()
        let url = imageURL(sha)
        if !FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try png.write(to: url, options: .atomic)
        }
        return sha
    }

    public func thumbnail(for id: UUID) -> Data? {
        var result: Data?
        try? query("SELECT thumbnail FROM entries WHERE id = ?", [id.uuidString]) { statement in
            result = Self.data(statement, 0)
        }
        return result
    }

    /// Deletes image files that no entry refers to any more.
    private func removeUnusedImages() {
        var used = Set<String>()
        try? query("SELECT DISTINCT image FROM entries WHERE image IS NOT NULL", []) { statement in
            if let sha = Self.string(statement, 0) { used.insert(sha) }
        }
        let files = FileManager.default.enumerator(at: imagesDirectory, includingPropertiesForKeys: nil)
        while let file = files?.nextObject() as? URL {
            if file.pathExtension == "png", !used.contains(file.deletingPathExtension().lastPathComponent) {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }

    // MARK: Reading

    /// Entries newest first, pinned ones before the rest. A query matches
    /// entries containing every word in it; `kinds` limits the kinds listed.
    public func entries(matching search: String = "", kinds: Set<ClipboardEntry.Kind>? = nil, limit: Int = 1000) throws -> [ClipboardEntry] {
        var conditions: [String] = []
        var values: [Any?] = []
        let words = search.split(whereSeparator: \.isWhitespace).map(String.init)
        // Trigrams need three characters; shorter words are looked up directly.
        let long = words.filter { $0.count >= 3 }
        if !long.isEmpty {
            conditions.append("rowid IN (SELECT rowid FROM entries_fts WHERE entries_fts MATCH ?)")
            values.append(long.map { "\"\($0.replacingOccurrences(of: "\"", with: "\"\""))\"" }.joined(separator: " "))
        }
        for word in words where word.count < 3 {
            conditions.append("search LIKE ? ESCAPE '\\'")
            values.append("%" + word.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "%", with: "\\%")
                .replacingOccurrences(of: "_", with: "\\_") + "%")
        }
        if let kinds {
            conditions.append("kind IN (\(kinds.map { _ in "?" }.joined(separator: ", ")))")
            values += kinds.map(\.rawValue)
        }
        values.append(limit)
        return try entries(where: conditions.isEmpty ? "1" : conditions.joined(separator: " AND "), values, limit: true)
    }

    public var count: Int {
        var result = 0
        try? query("SELECT count(*) FROM entries", []) { result = Int(sqlite3_column_int64($0, 0)) }
        return result
    }

    private func entries(where condition: String, _ values: [Any?], limit: Bool = false) throws -> [ClipboardEntry] {
        var result: [ClipboardEntry] = []
        try query("""
            SELECT id, kind, text, fingerprint, source_app, url, filename, width, height, image, pinned, created, used
            FROM entries WHERE \(condition) ORDER BY pinned DESC, used DESC\(limit ? " LIMIT ?" : "")
            """, values) { s in
            guard let id = Self.string(s, 0).flatMap(UUID.init(uuidString:)),
                  let kind = Self.string(s, 1).flatMap(ClipboardEntry.Kind.init(rawValue:)) else { return }
            var entry = ClipboardEntry(id: id, kind: kind, text: Self.string(s, 2) ?? "", fingerprint: Self.string(s, 3) ?? "",
                                       sourceApp: Self.string(s, 4), date: Date(timeIntervalSince1970: sqlite3_column_double(s, 12)))
            entry.url = Self.string(s, 5)
            entry.filename = Self.string(s, 6)
            entry.width = Self.int(s, 7)
            entry.height = Self.int(s, 8)
            entry.image = Self.string(s, 9)
            entry.pinned = sqlite3_column_int(s, 10) != 0
            entry.created = Date(timeIntervalSince1970: sqlite3_column_double(s, 11))
            result.append(entry)
        }
        return result
    }

    // MARK: The history before this database

    /// Brings in the history R2Drop kept before: history.json with an image
    /// and a thumbnail file per entry. The old files are removed once read.
    /// Returns how many entries were imported.
    @discardableResult
    public func importLegacyHistory() throws -> Int {
        let index = directory.appendingPathComponent("history.json")
        guard let data = try? Data(contentsOf: index) else { return 0 }
        let decoder = JSONDecoder()
        let legacy = (try? decoder.decode([LegacyEntry].self, from: data)) ?? []
        var imported = 0
        try execute("BEGIN")
        do {
            for old in legacy.reversed() {
                var entry = ClipboardEntry(id: old.id, kind: old.kind, text: old.text, fingerprint: old.fingerprint,
                                           sourceApp: old.sourceApp, date: old.date)
                entry.url = old.url
                entry.filename = old.filename
                entry.width = old.width
                entry.height = old.height
                if old.kind == .image {
                    guard let png = try? Data(contentsOf: directory.appendingPathComponent("\(old.id.uuidString).png")) else { continue }
                    entry.image = try storeImage(png)
                }
                let thumbnail = try? Data(contentsOf: directory.appendingPathComponent("\(old.id.uuidString)-thumb.png"))
                try insert(entry, thumbnail: thumbnail)
                imported += 1
            }
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
        try? FileManager.default.removeItem(at: index)
        for old in legacy {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent("\(old.id.uuidString).png"))
            try? FileManager.default.removeItem(at: directory.appendingPathComponent("\(old.id.uuidString)-thumb.png"))
        }
        return imported
    }

    private struct LegacyEntry: Decodable {
        let id: UUID
        let kind: ClipboardEntry.Kind
        let date: Date
        let text: String
        let fingerprint: String
        let sourceApp: String?
        let url: String?
        let filename: String?
        let width: Int?
        let height: Int?
    }

    // MARK: SQLite

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private func execute(_ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &error) == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? "unknown error"
            sqlite3_free(error)
            throw R2Error("Clipboard history: \(message)")
        }
    }

    private func run(_ sql: String, _ values: [Any?]) throws {
        try query(sql, values) { _ in }
    }

    private func query(_ sql: String, _ values: [Any?], row: (OpaquePointer) -> Void) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw R2Error("Clipboard history: \(String(cString: sqlite3_errmsg(db)))")
        }
        defer { sqlite3_finalize(statement) }
        for (index, value) in values.enumerated() {
            let position = Int32(index + 1)
            switch value {
            case nil: sqlite3_bind_null(statement, position)
            case let value as String: sqlite3_bind_text(statement, position, value, -1, Self.transient)
            case let value as Int: sqlite3_bind_int64(statement, position, Int64(value))
            case let value as Double: sqlite3_bind_double(statement, position, value)
            case let value as Data:
                _ = value.withUnsafeBytes { sqlite3_bind_blob(statement, position, $0.baseAddress, Int32(value.count), Self.transient) }
            default: sqlite3_bind_null(statement, position)
            }
        }
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW: row(statement)
            case SQLITE_DONE: return
            default: throw R2Error("Clipboard history: \(String(cString: sqlite3_errmsg(db)))")
            }
        }
    }

    private static func string(_ statement: OpaquePointer, _ column: Int32) -> String? {
        sqlite3_column_text(statement, column).map { String(cString: $0) }
    }

    private static func int(_ statement: OpaquePointer, _ column: Int32) -> Int? {
        sqlite3_column_type(statement, column) == SQLITE_NULL ? nil : Int(sqlite3_column_int64(statement, column))
    }

    private static func data(_ statement: OpaquePointer, _ column: Int32) -> Data? {
        guard let bytes = sqlite3_column_blob(statement, column) else { return nil }
        return Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, column)))
    }
}
