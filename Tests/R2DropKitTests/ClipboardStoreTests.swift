// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
@testable import R2DropKit

final class ClipboardStoreTests: XCTestCase {
    private var directory: URL!
    private var store: ClipboardStore!
    private let start = Date(timeIntervalSince1970: 1_790_000_000)

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("r2drop-clipboard-\(UUID().uuidString)")
        store = try ClipboardStore(directory: directory)
    }

    override func tearDownWithError() throws {
        store = nil
        try? FileManager.default.removeItem(at: directory)
    }

    private func text(_ value: String, at seconds: TimeInterval = 0, app: String? = nil) -> ClipboardEntry {
        ClipboardEntry(kind: .text, text: value, fingerprint: "text:" + value, sourceApp: app, date: start.addingTimeInterval(seconds))
    }

    func testKeepsItsDirectoryOutOfBackups() throws {
        let values = try directory.resourceValues(forKeys: [.isExcludedFromBackupKey])
        XCTAssertEqual(values.isExcludedFromBackup, true)
    }

    func testNewestFirstAndCopyingAgainMovesUp() throws {
        let first = try store.insert(text("first", at: 0))
        try store.insert(text("second", at: 10))
        XCTAssertEqual(try store.entries().map(\.text), ["second", "first"])

        let again = try store.insert(text("first", at: 20, app: "Safari"))
        XCTAssertEqual(again.id, first.id, "copying the same thing keeps the entry")
        XCTAssertEqual(again.sourceApp, "Safari")
        XCTAssertEqual(again.created, first.created)
        XCTAssertEqual(try store.entries().map(\.text), ["first", "second"])
        XCTAssertEqual(store.count, 2)

        try store.touch(try store.entries()[1].id, at: start.addingTimeInterval(30))
        XCTAssertEqual(try store.entries().map(\.text), ["second", "first"])
    }

    func testSearchFindsPartsOfWordsInEnglishAndChinese() throws {
        try store.insert(text("The quick brown fox jumps", at: 0, app: "Notes"))
        try store.insert(text("今天下午在鹿特丹开会", at: 1))
        try store.insert(text("go to 机场 at 9", at: 2))
        var upload = ClipboardEntry(kind: .upload, text: "https://img.example.com/2026/10/shot.png",
                                    fingerprint: "upload:shot", date: start.addingTimeInterval(3))
        upload.filename = "team-photo.png"
        try store.insert(upload)

        XCTAssertEqual(try store.entries(matching: "uick").map(\.text), ["The quick brown fox jumps"])
        XCTAssertEqual(try store.entries(matching: "鹿特丹").map(\.text), ["今天下午在鹿特丹开会"])
        XCTAssertEqual(try store.entries(matching: "jumps QUICK").count, 1, "every word, any case")
        XCTAssertEqual(try store.entries(matching: "quick 鹿特丹").count, 0)
        // Two-character words are too short for trigrams and are matched directly.
        XCTAssertEqual(try store.entries(matching: "机场").map(\.text), ["go to 机场 at 9"])
        XCTAssertEqual(try store.entries(matching: "go").map(\.text), ["go to 机场 at 9"])
        XCTAssertEqual(try store.entries(matching: "100%").count, 0, "LIKE wildcards are taken literally")
        // The app it came from and an upload's file name are searched too.
        XCTAssertEqual(try store.entries(matching: "notes").count, 1)
        XCTAssertEqual(try store.entries(matching: "team-photo").map(\.kind), [.upload])
        XCTAssertEqual(try store.entries(matching: #"say "hi""#).count, 0, "quotes in a query are safe")

        XCTAssertEqual(try store.entries(kinds: [.upload]).count, 1)
        XCTAssertEqual(try store.entries(matching: "png", kinds: [.text]).count, 0)
    }

    func testSearchFollowsDeletesAndEdits() throws {
        let entry = try store.insert(text("findable phrase"))
        XCTAssertEqual(try store.entries(matching: "findable").count, 1)
        try store.delete(entry.id)
        XCTAssertEqual(try store.entries(matching: "findable").count, 0)
        XCTAssertEqual(store.count, 0)
    }

    func testPinnedEntriesComeFirstAndOutlivePruning() throws {
        let old = try store.insert(text("keep me", at: 0))
        for index in 1...5 {
            try store.insert(text("item \(index)", at: TimeInterval(index)))
        }
        try store.setPinned(old.id, true)
        XCTAssertEqual(try store.entries().first?.text, "keep me")

        try store.prune(keep: 2, maxAge: nil, now: start.addingTimeInterval(10))
        XCTAssertEqual(try store.entries().map(\.text), ["keep me", "item 5", "item 4"])

        // Age removes entries too: used 5 and 4 seconds in, at 10 with a 5.5 limit only the older goes.
        try store.prune(keep: 10, maxAge: 5.5, now: start.addingTimeInterval(10))
        XCTAssertEqual(try store.entries().map(\.text), ["keep me", "item 5"])
        try store.prune(keep: 10, maxAge: 4.5, now: start.addingTimeInterval(10))
        XCTAssertEqual(try store.entries().map(\.text), ["keep me"])
        XCTAssertTrue(try store.entries().first!.pinned)
    }

    func testImagesAreStoredOnceByContentAndRemovedWithTheirLastEntry() throws {
        let png = Data([0x89, 0x50, 0x4e, 0x47, 1, 2, 3])
        let sha = try store.storeImage(png)
        XCTAssertEqual(sha.count, 64)
        XCTAssertEqual(try store.storeImage(png), sha)
        XCTAssertEqual(try Data(contentsOf: store.imageURL(sha)), png)
        XCTAssertTrue(store.imageURL(sha).path.contains("/images/\(sha.prefix(2))/"))

        var image = ClipboardEntry(kind: .image, text: "", fingerprint: "image:" + sha)
        image.image = sha
        image.width = 640
        let thumbnail = Data([1, 2, 3, 4])
        let stored = try store.insert(image, thumbnail: thumbnail)
        XCTAssertEqual(store.thumbnail(for: stored.id), thumbnail)
        XCTAssertEqual(try store.entries().first?.image, sha)
        XCTAssertEqual(try store.entries().first?.width, 640)

        try store.delete(stored.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.imageURL(sha).path))
        XCTAssertNil(store.thumbnail(for: stored.id))
    }

    func testClearRemovesEverything() throws {
        let sha = try store.storeImage(Data([9, 9, 9]))
        var image = ClipboardEntry(kind: .image, text: "", fingerprint: "image:" + sha)
        image.image = sha
        try store.insert(image)
        try store.insert(text("words"))
        try store.clear()
        XCTAssertEqual(store.count, 0)
        XCTAssertEqual(try store.entries(matching: "words").count, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.imageURL(sha).path))
        try store.insert(text("still works after clearing"))
        XCTAssertEqual(try store.entries(matching: "clearing").count, 1)
    }

    func testImportsTheHistoryKeptBeforeTheDatabase() throws {
        let textID = UUID(), imageID = UUID(), missingID = UUID()
        let legacy: [[String: Any]] = [
            ["id": textID.uuidString, "kind": "text", "date": 800_000_100.0, "text": "旧的一条", "fingerprint": "text:旧的一条", "sourceApp": "Safari"],
            ["id": imageID.uuidString, "kind": "image", "date": 800_000_050.0, "text": "", "fingerprint": "image:abc", "width": 10, "height": 20],
            ["id": missingID.uuidString, "kind": "image", "date": 800_000_000.0, "text": "", "fingerprint": "image:gone"],
        ]
        try JSONSerialization.data(withJSONObject: legacy).write(to: directory.appendingPathComponent("history.json"))
        let png = Data([0x89, 0x50, 0x4e, 0x47, 7, 7])
        try png.write(to: directory.appendingPathComponent("\(imageID.uuidString).png"))
        try Data([5, 5]).write(to: directory.appendingPathComponent("\(imageID.uuidString)-thumb.png"))

        XCTAssertEqual(try store.importLegacyHistory(), 2, "the image whose file is gone is skipped")
        let entries = try store.entries()
        XCTAssertEqual(entries.map(\.id), [textID, imageID])
        XCTAssertEqual(entries[0].sourceApp, "Safari")
        XCTAssertEqual(entries[0].date, Date(timeIntervalSinceReferenceDate: 800_000_100))
        XCTAssertEqual(try Data(contentsOf: store.imageURL(entries[1].image!)), png)
        XCTAssertEqual(store.thumbnail(for: imageID), Data([5, 5]))
        XCTAssertEqual(try store.entries(matching: "旧的").count, 1)

        let leftovers = try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.hasSuffix(".json") || $0.hasSuffix(".png") }
        XCTAssertEqual(leftovers, [], "the old files are gone once imported")
        XCTAssertEqual(try store.importLegacyHistory(), 0)
    }

    func testReopensWhatWasSaved() throws {
        try store.insert(text("persisted"))
        store = nil
        let reopened = try ClipboardStore(directory: directory)
        XCTAssertEqual(try reopened.entries(matching: "persist").map(\.text), ["persisted"])
    }
}

final class ClipboardPolicyTests: XCTestCase {
    func testRecognisesKeysAndTokens() {
        for secret in [
            "sk-proj-AbCdEfGhIjKlMnOpQrStUvWxYz0123456789",
            "sk-ant-api03-AbCdEfGhIjKlMnOpQrStUv_wxyz-0123",
            "ghp_0123456789abcdefghijABCDEFGHIJ012345",
            "AKIAIOSFODNN7EXAMPLE",
            "OPENAI_API_KEY=sk-AbCdEfGhIjKlMnOpQrStUvWxYz012345",
            "xoxb-1234567890-abcdefghij",
            "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dozjgNryP4J3jVmNHl0w5N_XgL0n3I9PlFUP0THsR8U",
            "-----BEGIN OPENSSH PRIVATE KEY-----\nb3BlbnNzaC1rZXktdjEAAAAA\n-----END OPENSSH PRIVATE KEY-----",
            "password: \"hunter2hunter2hunter2\"",
            "7110cf09a52f3fefaab1c7a2ffaaa74658fe0cf7e11491b5", // a random hex key
            "58ddfe0db5f1db9e173bc93359ce81f5b637311d8bb0dd0469cd2d2ad9796cf9",
        ] {
            XCTAssertTrue(ClipboardPolicy.looksSecret(secret), secret)
        }
    }

    func testLeavesOrdinaryCopiesAlone() {
        for ordinary in [
            "Meeting moved to 3pm, see you there",
            "https://github.com/yongkang-yang/R2Drop/commit/9baf5140a1b2c3d4e5f60718293a4b5c6d7e8f90",
            "9baf5140a1b2c3d4e5f60718293a4b5c6d7e8f90", // a git commit
            "123e4567-e89b-12d3-a456-426614174000",     // a UUID
            "/Users/johanyang/Developer/Native MACOS APP/R2Drop/Sources/R2DropKit/ClipboardStore.swift",
            "let token = session.makeToken(for: user)",
            "skill-based learning",
            "今天下午在鹿特丹开会，记得带电脑",
            "short",
        ] {
            XCTAssertFalse(ClipboardPolicy.looksSecret(ordinary), ordinary)
        }
    }

    func testKnowsThePasswordManagers() {
        XCTAssertTrue(ClipboardPolicy.ignoredApps.contains("com.1password.1password"))
        XCTAssertTrue(ClipboardPolicy.ignoredTypes.contains("org.nspasteboard.ConcealedType"))
        XCTAssertTrue(ClipboardPolicy.terminalApps.contains("com.mitchellh.ghostty"))
    }
}

final class InboxTextTests: XCTestCase {
    func testSavesTextForTheInboxToLabel() throws {
        let client = InboxClient(settings: InboxSettings(endpoint: "https://bw.example.com/api/capture", key: "k3y"))
        let request = client.saveRequest(text: "值得一读 https://example.com/post")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer k3y")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(request.httpBody)) as? [String: String])
        XCTAssertEqual(body, ["text": "值得一读 https://example.com/post", "source": "r2drop"])
    }
}
