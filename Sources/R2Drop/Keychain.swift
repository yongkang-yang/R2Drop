// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Security

/// Secrets live in the login keychain, not in preferences. With the bundle
/// signed by a stable identity (see Scripts/bundle.sh) the item stays readable
/// across rebuilds without a prompt.
enum Keychain {
    private static var service: String { Bundle.main.bundleIdentifier ?? "nl.yongkang.r2drop" }

    /// Values read this run. An item saved by a build signed differently makes
    /// the keychain ask for the login password before handing it over, so each
    /// one is read at most once instead of on every upload.
    private static var cache: [String: String] = [:]
    private static let lock = NSLock()

    private static func query(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    static func read(_ account: String) -> String {
        if let cached = lock.withLock({ cache[account] }) { return cached }
        var query = query(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        let value: String
        switch SecItemCopyMatching(query as CFDictionary, &result) {
        case errSecSuccess:
            guard let data = result as? Data else { return "" }
            value = String(decoding: data, as: UTF8.self)
        case errSecItemNotFound:
            value = ""
        default:
            // Denied at the prompt: not remembered, so the next use asks again.
            return ""
        }
        lock.withLock { cache[account] = value }
        return value
    }

    /// Whether the item is there, without reading its value. Attributes need
    /// no permission, so unlike `read` this never shows a keychain prompt.
    static func contains(_ account: String) -> Bool {
        if let cached = lock.withLock({ cache[account] }) { return !cached.isEmpty }
        var query = query(account)
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        return SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess
    }

    /// An empty value deletes the item.
    static func write(_ value: String, for account: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            let status = SecItemDelete(query(account) as CFDictionary)
            if status == errSecSuccess || status == errSecItemNotFound {
                lock.withLock { cache[account] = "" }
            }
            return
        }
        let data = Data(trimmed.utf8)
        var status = SecItemUpdate(query(account) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query(account)
            item[kSecValueData as String] = data
            status = SecItemAdd(item as CFDictionary, nil)
        }
        if status == errSecSuccess {
            lock.withLock { cache[account] = trimmed }
        }
    }
}
