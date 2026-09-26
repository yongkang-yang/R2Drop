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
}
