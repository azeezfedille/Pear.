import Foundation

/// User-facing P2P switches. Both live in UserDefaults so `@AppStorage` and non-UI code read the same value.
/// Deliberately NOT part of SettingsBackup: restoring a backup must never silently turn P2P on.
enum P2PSettings {
    static let enabledKey = "p2p.enabled"
    static let wifiOnlyKey = "p2p.wifiOnly"

    /// Opt-in: false until the user confirms it in Settings.
    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: enabledKey) }
    /// Defaults to true: mobile data and personal hotspots are off-limits unless the user says otherwise.
    static var wifiOnly: Bool { UserDefaults.standard.object(forKey: wifiOnlyKey) as? Bool ?? true }
}
