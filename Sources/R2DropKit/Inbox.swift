// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Vision

public struct InboxSettings: Equatable, Sendable {
    public var endpoint: String
    public var key: String

    public init(endpoint: String, key: String) {
        self.endpoint = endpoint
        self.key = key
    }

    /// Settings with surrounding whitespace removed, or an error naming what's wrong.
    public func validated() throws -> InboxSettings {
        let trimmed = InboxSettings(endpoint: endpoint.trimmed, key: key.trimmed)
        if trimmed.endpoint.isEmpty || trimmed.key.isEmpty {
            throw R2Error("Missing BlogWatcher settings. Set the capture URL and key in Settings.")
        }
        guard let url = URL(string: trimmed.endpoint), ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else {
            throw R2Error("The BlogWatcher capture URL isn't a web address.")
        }
        return trimmed
    }
}

/// Saves uploaded images to a BlogWatcher inbox through its capture endpoint.
/// The images are already in R2, so only their links and text are sent.
public struct InboxClient: Sendable {
    public typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    private let settings: InboxSettings
    private let transport: Transport

    public init(settings: InboxSettings, transport: @escaping Transport = { try await URLSession.shared.data(for: $0) }) {
        self.settings = settings
        self.transport = transport
    }

    /// Images already in R2, with the text recognised in them.
    public func saveRequest(images: [String], text: String) -> URLRequest {
        var body: [String: Any] = ["images": images, "source": "r2drop"]
        if !text.isEmpty { body["ocr"] = text }
        return request(body)
    }

    /// A piece of text or a link; the inbox finds the link in it and labels it.
    public func saveRequest(text: String) -> URLRequest {
        request(["text": text, "source": "r2drop"])
    }

    private func request(_ body: [String: Any]) -> URLRequest {
        var request = URLRequest(url: URL(string: settings.endpoint)!, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("Bearer \(settings.key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        return request
    }

    /// Returns the title the capture was saved under.
    @discardableResult
    public func save(images: [String], text: String) async throws -> String {
        try await send(saveRequest(images: images, text: text))
    }

    @discardableResult
    public func save(text: String) async throws -> String {
        try await send(saveRequest(text: text))
    }

    private func send(_ request: URLRequest) async throws -> String {
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await transport(request)
        } catch {
            throw R2Error("Could not reach BlogWatcher: \(error.localizedDescription)")
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let reply = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard (200..<300).contains(status) else {
            if status == 401 {
                throw R2Error("BlogWatcher rejected the key. Check it in Settings.")
            }
            throw R2Error("BlogWatcher returned HTTP \(status)\((reply?["error"] as? String).map { ": \($0)" } ?? "").")
        }
        return reply?["title"] as? String ?? ""
    }
}

public enum TextRecognizer {
    /// The text in an image, line by line; empty when there is none or the
    /// image can't be read.
    public static func text(in file: URL) async -> String {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate
                request.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US"]
                request.usesLanguageCorrection = true
                try? VNImageRequestHandler(url: file).perform([request])
                let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
                continuation.resume(returning: lines.joined(separator: "\n"))
            }
        }
    }
}
