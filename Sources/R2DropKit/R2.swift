// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

public struct R2Error: LocalizedError, Equatable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// What gets copied after an upload.
public enum OutputFormat: String, CaseIterable, Codable, Sendable {
    case url, markdown, html
    case markdownFilename = "markdown-filename"

    public var title: String {
        switch self {
        case .url: "URL"
        case .markdown: "Markdown"
        case .html: "HTML"
        case .markdownFilename: "Markdown with Filename"
        }
    }

    /// The short name in "Copied Markdown link".
    public var label: String {
        switch self {
        case .url: "URL"
        case .markdown, .markdownFilename: "Markdown"
        case .html: "HTML"
        }
    }

    public func format(url: String, filename: String) -> String {
        switch self {
        case .url: return url
        case .markdown: return "![](\(url))"
        case .html: return "<img src=\"\(url)\">"
        case .markdownFilename:
            let name = (filename as NSString).deletingPathExtension
            return "![\(name)](\(url))"
        }
    }
}

public struct R2Settings: Equatable, Sendable {
    public var accountID: String
    public var bucket: String
    public var accessKeyID: String
    public var secretAccessKey: String
    public var publicBaseURL: String

    public init(accountID: String, bucket: String, accessKeyID: String, secretAccessKey: String, publicBaseURL: String) {
        self.accountID = accountID
        self.bucket = bucket
        self.accessKeyID = accessKeyID
        self.secretAccessKey = secretAccessKey
        self.publicBaseURL = publicBaseURL
    }

    /// Settings with surrounding whitespace removed, or an error naming what's missing.
    public func validated() throws -> R2Settings {
        let trimmed = R2Settings(accountID: accountID.trimmed, bucket: bucket.trimmed, accessKeyID: accessKeyID.trimmed,
                                 secretAccessKey: secretAccessKey.trimmed, publicBaseURL: publicBaseURL.trimmed)
        let missing = [("Account ID", trimmed.accountID), ("Bucket", trimmed.bucket), ("Access Key ID", trimmed.accessKeyID),
                       ("Secret Access Key", trimmed.secretAccessKey), ("Public Base URL", trimmed.publicBaseURL)]
            .filter { $0.1.isEmpty }.map(\.0)
        if !missing.isEmpty {
            throw R2Error("Missing R2 settings: \(missing.joined(separator: ", ")). Configure them in Settings.")
        }
        return trimmed
    }

    /// R2's S3 credentials have a fixed shape: a 32-character access key ID
    /// and a 64-character secret, both hexadecimal. Anything else is usually
    /// the Cloudflare API token pasted in the wrong field, which R2 answers
    /// with SignatureDoesNotMatch.
    public var credentialProblems: [String] {
        func isHex(_ value: String, _ count: Int) -> Bool {
            value.trimmed.count == count && value.trimmed.allSatisfy(\.isHexDigit)
        }
        var problems: [String] = []
        if !accessKeyID.trimmed.isEmpty, !isHex(accessKeyID, 32) {
            problems.append("The Access Key ID should be 32 hexadecimal characters; this one is \(accessKeyID.trimmed.count).")
        }
        if !secretAccessKey.trimmed.isEmpty, !isHex(secretAccessKey, 64) {
            problems.append("The Secret Access Key should be 64 hexadecimal characters; this one is \(secretAccessKey.trimmed.count). Use the S3 secret shown when the R2 API token was created, not the token value itself.")
        }
        return problems
    }

    public func publicURL(for key: String) -> String {
        var base = publicBaseURL.trimmed
        while base.hasSuffix("/") { base.removeLast() }
        return "\(base)/\(key)"
    }
}

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}

public enum ObjectKey {
    static let contentTypes: [String: String] = [
        "png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg", "gif": "image/gif", "webp": "image/webp",
        "svg": "image/svg+xml", "heic": "image/heic", "tiff": "image/tiff", "tif": "image/tiff", "bmp": "image/bmp",
    ]

    public static let imageExtensions: Set<String> = Set(contentTypes.keys)

    public static func isImage(_ path: String) -> Bool {
        imageExtensions.contains((path as NSString).pathExtension.lowercased())
    }

    public static func contentType(forExtension ext: String) -> String {
        contentTypes[ext.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))] ?? "application/octet-stream"
    }

    /// Lowercase ASCII words joined by dashes, at most 60 characters.
    public static func slugify(_ value: String) -> String {
        var slug = ""
        var pendingDash = false
        for scalar in value.lowercased().unicodeScalars {
            if ("a"..."z").contains(scalar) || ("0"..."9").contains(scalar) {
                if pendingDash && !slug.isEmpty { slug.append("-") }
                slug.unicodeScalars.append(scalar)
                pendingDash = false
            } else {
                pendingDash = true
            }
        }
        return String(slug.prefix(60)).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    /// Builds a key like "2026/09/survey2-team-list-a8f31c.png". The trailing
    /// hash keeps re-uploads and repeated names from colliding.
    public static func build(originalName: String, slug: String? = nil, date: Date = Date(),
                             hash: String = randomHash(), calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month], from: date)
        let ext = (originalName as NSString).pathExtension.lowercased()
        let base = slugify(slug ?? (originalName as NSString).deletingPathExtension)
        let name = base.isEmpty ? hash : "\(base)-\(hash)"
        return String(format: "%04d/%02d/", parts.year ?? 0, parts.month ?? 0) + "\(name).\(ext.isEmpty ? "png" : ext)"
    }

    public static func randomHash() -> String {
        (0..<3).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
    }
}

/// Puts objects into an R2 bucket through its S3-compatible API.
public struct R2Client: Sendable {
    public typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    private let settings: R2Settings
    private let transport: Transport

    public init(settings: R2Settings, transport: @escaping Transport = { try await URLSession.shared.data(for: $0) }) {
        self.settings = settings
        self.transport = transport
    }

    public func putRequest(key: String, body: Data, contentType: String, date: Date = Date()) -> URLRequest {
        let host = "\(settings.accountID).r2.cloudflarestorage.com"
        let path = "/\(settings.bucket)/\(key)"
        let payloadHash = SigV4.sha256Hex(body)
        let headers = [
            "host": host,
            "content-type": contentType,
            "x-amz-content-sha256": payloadHash,
            "x-amz-date": SigV4.amzDate(date),
        ]
        let authorization = SigV4.authorization(
            method: "PUT", path: path, headers: headers, payloadHash: payloadHash, region: "auto",
            credentials: .init(accessKeyID: settings.accessKeyID, secretAccessKey: settings.secretAccessKey))
        var request = URLRequest(url: URL(string: "https://\(host)\(SigV4.encode(path, keepSlash: true))")!, timeoutInterval: 120)
        request.httpMethod = "PUT"
        for (name, value) in headers where name != "host" {
            request.setValue(value, forHTTPHeaderField: name)
        }
        request.setValue(authorization, forHTTPHeaderField: "Authorization")
        request.httpBody = body
        return request
    }

    public func put(key: String, body: Data, contentType: String) async throws {
        let request = putRequest(key: key, body: body, contentType: contentType)
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await transport(request)
        } catch {
            throw R2Error("Could not reach R2: \(error.localizedDescription)")
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let message = Self.s3Message(data)
            if message?.hasPrefix("SignatureDoesNotMatch") == true {
                throw R2Error("R2 rejected the signature: the Secret Access Key doesn't belong to this Access Key ID. Check both in Settings.")
            }
            throw R2Error("R2 returned HTTP \(status)\(message.map { ": \($0)" } ?? "").")
        }
    }

    /// The `<Code>` and `<Message>` of an S3 error body, if there is one.
    static func s3Message(_ data: Data) -> String? {
        let body = String(decoding: data, as: UTF8.self)
        func tag(_ name: String) -> String? {
            guard let start = body.range(of: "<\(name)>"), let end = body.range(of: "</\(name)>", range: start.upperBound..<body.endIndex)
            else { return nil }
            return String(body[start.upperBound..<end.lowerBound])
        }
        switch (tag("Code"), tag("Message")) {
        case let (code?, message?): return "\(code) — \(message)"
        case let (code?, nil): return code
        case let (nil, message?): return message
        default: return nil
        }
    }
}
