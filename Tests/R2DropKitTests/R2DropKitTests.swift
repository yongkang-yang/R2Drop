// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
@testable import R2DropKit

/// The worked examples from AWS's "Signature Calculations for the
/// Authorization Header: Transferring Payload in a Single Chunk".
final class SigV4Tests: XCTestCase {
    private let credentials = SigV4.Credentials(accessKeyID: "AKIAIOSFODNN7EXAMPLE",
                                                secretAccessKey: "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY")

    func testGetObjectExample() {
        let authorization = SigV4.authorization(
            method: "GET", path: "/test.txt",
            headers: ["Host": "examplebucket.s3.amazonaws.com", "Range": "bytes=0-9",
                      "x-amz-content-sha256": SigV4.sha256Hex(Data()), "x-amz-date": "20130524T000000Z"],
            payloadHash: SigV4.sha256Hex(Data()), region: "us-east-1", credentials: credentials)
        XCTAssertEqual(authorization,
                       "AWS4-HMAC-SHA256 Credential=AKIAIOSFODNN7EXAMPLE/20130524/us-east-1/s3/aws4_request, SignedHeaders=host;range;x-amz-content-sha256;x-amz-date, Signature=f0e8bdb87c964420e857bd35b5d6ed310bd44f0170aba48dd91039c6036bdb41")
    }

    func testPutObjectExample() {
        let body = Data("Welcome to Amazon S3.".utf8)
        let hash = SigV4.sha256Hex(body)
        XCTAssertEqual(hash, "44ce7dd67c959e0d3524ffac1771dfbba87d2b6b4b4e99e42034a8b803f8b072")
        let authorization = SigV4.authorization(
            method: "PUT", path: "/test$file.text",
            headers: ["Host": "examplebucket.s3.amazonaws.com", "Date": "Fri, 24 May 2013 00:00:00 GMT",
                      "x-amz-date": "20130524T000000Z", "x-amz-storage-class": "REDUCED_REDUNDANCY",
                      "x-amz-content-sha256": hash],
            payloadHash: hash, region: "us-east-1", credentials: credentials)
        XCTAssertTrue(authorization.hasSuffix("Signature=98ad721746da40c64f1a55b78f14c238d841ea1380cd77a1b5971af0ece108bd"),
                      authorization)
    }
}

final class R2Tests: XCTestCase {
    private let settings = R2Settings(accountID: "acct", bucket: "images", accessKeyID: "id", secretAccessKey: "secret",
                                      publicBaseURL: "https://img.example.com/")

    func testFormats() {
        let url = "https://img.example.com/2026/09/a-1.png"
        XCTAssertEqual(OutputFormat.url.format(url: url, filename: "shot.png"), url)
        XCTAssertEqual(OutputFormat.markdown.format(url: url, filename: "shot.png"), "![](\(url))")
        XCTAssertEqual(OutputFormat.html.format(url: url, filename: "shot.png"), "<img src=\"\(url)\">")
        XCTAssertEqual(OutputFormat.markdownFilename.format(url: url, filename: "team list.png"), "![team list](\(url))")
    }

    func testKeys() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let date = calendar.date(from: DateComponents(year: 2026, month: 9, day: 3))!
        XCTAssertEqual(ObjectKey.build(originalName: "Survey2 Team List.PNG", date: date, hash: "a8f31c", calendar: calendar),
                       "2026/09/survey2-team-list-a8f31c.png")
        XCTAssertEqual(ObjectKey.build(originalName: "截图.jpg", date: date, hash: "a8f31c", calendar: calendar),
                       "2026/09/a8f31c.jpg")
        XCTAssertEqual(ObjectKey.build(originalName: "x.png", slug: "My Slug!", date: date, hash: "ff0000", calendar: calendar),
                       "2026/09/my-slug-ff0000.png")
        XCTAssertEqual(ObjectKey.randomHash().count, 6)
        XCTAssertEqual(ObjectKey.contentType(forExtension: "JPEG"), "image/jpeg")
        XCTAssertTrue(ObjectKey.isImage("/tmp/a.HEIC"))
        XCTAssertFalse(ObjectKey.isImage("/tmp/a.pdf"))
    }

    func testSettingsValidation() throws {
        XCTAssertEqual(settings.publicURL(for: "k.png"), "https://img.example.com/k.png")
        let partial = R2Settings(accountID: " ", bucket: "b", accessKeyID: "", secretAccessKey: "s", publicBaseURL: "u")
        XCTAssertThrowsError(try partial.validated()) {
            XCTAssertEqual(($0 as? R2Error)?.message,
                           "Missing R2 settings: Account ID, Access Key ID. Configure them in Settings.")
        }
    }

    func testPutRequestIsPathStyleAndSigned() {
        let request = R2Client(settings: settings).putRequest(key: "2026/09/a b.png", body: Data([1, 2]), contentType: "image/png")
        XCTAssertEqual(request.url?.absoluteString, "https://acct.r2.cloudflarestorage.com/images/2026/09/a%20b.png")
        XCTAssertEqual(request.httpMethod, "PUT")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "image/png")
        let authorization = request.value(forHTTPHeaderField: "Authorization") ?? ""
        XCTAssertTrue(authorization.contains("/auto/s3/aws4_request"))
        XCTAssertTrue(authorization.contains("SignedHeaders=content-type;host;x-amz-content-sha256;x-amz-date"))
    }

    func testErrorsCarryS3Message() async {
        let client = R2Client(settings: settings) { request in
            (Data("<Error><Code>AccessDenied</Code><Message>Access Denied</Message></Error>".utf8),
             HTTPURLResponse(url: request.url!, statusCode: 403, httpVersion: nil, headerFields: nil)!)
        }
        do {
            try await client.put(key: "k.png", body: Data(), contentType: "image/png")
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error.localizedDescription, "R2 returned HTTP 403: AccessDenied — Access Denied.")
        }
    }

    func testCredentialShapeIsChecked() {
        let good = R2Settings(accountID: "a", bucket: "b", accessKeyID: String(repeating: "a", count: 32),
                              secretAccessKey: String(repeating: "f", count: 64), publicBaseURL: "u")
        XCTAssertEqual(good.credentialProblems, [])
        var token = good
        token.secretAccessKey = "cfut_" + String(repeating: "x", count: 35)
        XCTAssertEqual(token.credentialProblems.count, 1)
        XCTAssertTrue(token.credentialProblems[0].contains("this one is 40"))
    }

    /// Cross-checked with botocore's S3SigV4Auth for the same request and timestamp.
    func testMatchesBotocoreForAnR2Upload() {
        let settings = R2Settings(accountID: "0123abcd", bucket: "images", accessKeyID: "AKIDEXAMPLE",
                                  secretAccessKey: "SECRET/abc+123", publicBaseURL: "https://x")
        let request = R2Client(settings: settings).putRequest(key: "2026/09/clipboard-a1b2c3.png", body: Data("hello".utf8),
                                                              contentType: "image/png", date: Date(timeIntervalSince1970: 1_790_000_000))
        XCTAssertTrue(request.value(forHTTPHeaderField: "Authorization")!
            .hasSuffix("Signature=8f4b600ca8ededfd5c63d5695dc5c56498183379789b5008129bb17961c0ee2e"))
    }
}

final class InboxTests: XCTestCase {
    private let settings = InboxSettings(endpoint: "https://bw.example.com/api/capture", key: "k3y")

    private func reply(_ status: Int, _ body: String) -> InboxClient.Transport {
        { request in (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!) }
    }

    func testSettingsValidation() throws {
        XCTAssertEqual(try InboxSettings(endpoint: " https://bw.example.com/api/capture\n", key: " k3y ").validated(), settings)
        for bad in [InboxSettings(endpoint: "", key: "k"), InboxSettings(endpoint: "https://bw.example.com", key: " ")] {
            XCTAssertThrowsError(try bad.validated()) {
                XCTAssertEqual(($0 as? R2Error)?.message, "Missing BlogWatcher settings. Set the capture URL and key in Settings.")
            }
        }
        for bad in ["bw.example.com/api/capture", "ftp://bw.example.com/x", "https://"] {
            XCTAssertThrowsError(try InboxSettings(endpoint: bad, key: "k").validated(), bad) {
                XCTAssertEqual(($0 as? R2Error)?.message, "The BlogWatcher capture URL isn't a web address.")
            }
        }
    }

    func testSaveRequestCarriesLinksAndText() throws {
        let client = InboxClient(settings: settings)
        let request = client.saveRequest(images: ["https://img.example.com/2026/10/a-1.png"], text: "第一行\nline two")
        XCTAssertEqual(request.url?.absoluteString, "https://bw.example.com/api/capture")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer k3y")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(request.httpBody)) as? [String: Any])
        XCTAssertEqual(body["images"] as? [String], ["https://img.example.com/2026/10/a-1.png"])
        XCTAssertEqual(body["ocr"] as? String, "第一行\nline two")
        XCTAssertEqual(body["source"] as? String, "r2drop")
        let wordless = try XCTUnwrap(client.saveRequest(images: ["u"], text: "").httpBody)
        XCTAssertNil((try JSONSerialization.jsonObject(with: wordless) as? [String: Any])?["ocr"])
    }

    func testSaveAnswersWithTheTitle() async throws {
        let client = InboxClient(settings: settings, transport: reply(200, #"{"id": 1790863860091, "type": "image", "title": "第一行"}"#))
        let title = try await client.save(images: ["u"], text: "第一行")
        XCTAssertEqual(title, "第一行")
    }

    func testSaveErrorsSayWhatWentWrong() async {
        func message(_ transport: @escaping InboxClient.Transport) async -> String? {
            do {
                try await InboxClient(settings: settings, transport: transport).save(images: ["u"], text: "")
                return nil
            } catch {
                return error.localizedDescription
            }
        }
        var text = await message(reply(401, #"{"error": "unauthorized"}"#))
        XCTAssertEqual(text, "BlogWatcher rejected the key. Check it in Settings.")
        text = await message(reply(400, #"{"error": "nothing to capture"}"#))
        XCTAssertEqual(text, "BlogWatcher returned HTTP 400: nothing to capture.")
        text = await message(reply(502, "<html>Bad Gateway</html>"))
        XCTAssertEqual(text, "BlogWatcher returned HTTP 502.")
        text = await message { _ in throw URLError(.notConnectedToInternet) }
        XCTAssertEqual(text?.hasPrefix("Could not reach BlogWatcher: "), true)
    }

    func testLongerHashesForInboxImages() {
        XCTAssertEqual(ObjectKey.randomHash(bytes: 8).count, 16)
    }

    func testReadsTheTextInAnImage() async throws {
        // Black text on white, the way a screenshot of a post looks.
        let size = NSSize(width: 900, height: 260)
        let image = NSImage(size: size, flipped: false) { rect in
            NSColor.white.setFill()
            rect.fill()
            let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 44), .foregroundColor: NSColor.black]
            ("Intelligence inbox 2026" as NSString).draw(at: NSPoint(x: 40, y: 150), withAttributes: attributes)
            ("今天的天气很好" as NSString).draw(at: NSPoint(x: 40, y: 60), withAttributes: attributes)
            return true
        }
        let png = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation))?.representation(using: .png, properties: [:]))
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("r2drop-ocr-\(UUID().uuidString).png")
        try png.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        let text = await TextRecognizer.text(in: file)
        XCTAssertEqual(text, "Intelligence inbox 2026\n今天的天气很好")
        let nothing = await TextRecognizer.text(in: URL(fileURLWithPath: "/nonexistent/image.png"))
        XCTAssertEqual(nothing, "")
    }
}
