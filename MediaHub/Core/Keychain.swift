import Foundation
import Security

/// Keychain with a UserDefaults fallback. Sideloaded / containerised apps (LiveContainer) can have keychain
/// writes rejected, which would otherwise lose every token on relaunch. If the keychain refuses, the value is
/// kept in the app's own sandbox instead.
enum Keychain {
    private static func base(_ k: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrAccount as String: k]
    }
    private static func fallbackKey(_ k: String) -> String { "kc.fallback." + k }

    /// Returns true when the value went into the real keychain.
    @discardableResult
    static func set(_ v: String, _ k: String) -> Bool {
        SecItemDelete(base(k) as CFDictionary)
        var q = base(k)
        q[kSecValueData as String] = Data(v.utf8)
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        if SecItemAdd(q as CFDictionary, nil) == errSecSuccess {
            UserDefaults.standard.removeObject(forKey: fallbackKey(k))
            return true
        }
        UserDefaults.standard.set(v, forKey: fallbackKey(k))
        return false
    }

    static func get(_ k: String) -> String? {
        var q = base(k)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        if SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data,
           let s = String(data: d, encoding: .utf8) { return s }
        return UserDefaults.standard.string(forKey: fallbackKey(k))
    }

    static func remove(_ k: String) {
        SecItemDelete(base(k) as CFDictionary)
        UserDefaults.standard.removeObject(forKey: fallbackKey(k))
    }
}
