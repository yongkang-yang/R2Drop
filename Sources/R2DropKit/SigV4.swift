// SPDX-License-Identifier: GPL-3.0-or-later
import CryptoKit
import Foundation

/// AWS Signature Version 4 for single-chunk S3 requests, which is all R2's
/// S3-compatible API needs for an upload. Replaces the AWS SDK the Raycast
/// extension bundled.
public enum SigV4 {
    public struct Credentials: Sendable {
        public let accessKeyID: String
        public let secretAccessKey: String

        public init(accessKeyID: String, secretAccessKey: String) {
            self.accessKeyID = accessKeyID
            self.secretAccessKey = secretAccessKey
        }
    }

    public static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// `20130524T000000Z`, always in UTC.
    public static func amzDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return formatter.string(from: date)
    }

    /// Percent-encodes everything but the unreserved characters, as SigV4
    /// requires; `/` survives in paths.
    public static func encode(_ value: String, keepSlash: Bool) -> String {
        var allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        if keepSlash { allowed.insert("/") }
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    /// The Authorization header for a request. `headers` must include `host`
    /// and `x-amz-date`; every header given is signed. `path` is unencoded.
    public static func authorization(method: String, path: String, query: String = "",
                                     headers: [String: String], payloadHash: String,
                                     region: String, service: String = "s3",
                                     credentials: Credentials) -> String {
        let normalized = Dictionary(headers.map { ($0.key.lowercased(), $0.value.trimmingCharacters(in: .whitespaces)) },
                                    uniquingKeysWith: { $1 })
        let names = normalized.keys.sorted()
        let canonicalHeaders = names.map { "\($0):\(normalized[$0]!)\n" }.joined()
        let signedHeaders = names.joined(separator: ";")
        let canonicalRequest = [
            method,
            encode(path, keepSlash: true),
            query,
            canonicalHeaders,
            signedHeaders,
            payloadHash,
        ].joined(separator: "\n")

        let timestamp = normalized["x-amz-date"] ?? ""
        let day = String(timestamp.prefix(8))
        let scope = "\(day)/\(region)/\(service)/aws4_request"
        let stringToSign = [
            "AWS4-HMAC-SHA256",
            timestamp,
            scope,
            sha256Hex(Data(canonicalRequest.utf8)),
        ].joined(separator: "\n")

        var key = SymmetricKey(data: Data("AWS4\(credentials.secretAccessKey)".utf8))
        for part in [day, region, service, "aws4_request"] {
            key = SymmetricKey(data: Data(HMAC<SHA256>.authenticationCode(for: Data(part.utf8), using: key)))
        }
        let signature = HMAC<SHA256>.authenticationCode(for: Data(stringToSign.utf8), using: key)
            .map { String(format: "%02x", $0) }.joined()
        return "AWS4-HMAC-SHA256 Credential=\(credentials.accessKeyID)/\(scope), SignedHeaders=\(signedHeaders), Signature=\(signature)"
    }
}
