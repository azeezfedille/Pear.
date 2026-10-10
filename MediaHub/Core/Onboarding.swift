import Foundation

/// First-launch setup state. A fresh install is "pending" until the setup flow is finished or skipped.
/// Anyone updating from an older build already has settings saved, so they never see it.
enum Onboarding {
    private static let key = "onboarding.state"

    /// Decided once, on the very first launch of a build that has this flow, then remembered. Settings the flow
    /// itself writes (accent colour, add-ons) therefore can't make a half-finished setup look like an old install.
    static var needed: Bool {
        let d = UserDefaults.standard
        if let s = d.string(forKey: key) { return s == "pending" }
        let existing = ["profiles.list", "addon.manifestURLs", "ui.accent", "tmdb.key", "tvdb.key", "mdblist.key",
                        "watch.history", "library.local", "simkl.account"]
        let upgrading = existing.contains { d.object(forKey: $0) != nil } || Keychain.get("simkl.token") != nil
        d.set(upgrading ? "done" : "pending", forKey: key)
        return !upgrading
    }

    /// True while the setup flow still has to be finished (read-only).
    static var isPending: Bool { UserDefaults.standard.string(forKey: key) == "pending" }

    static func finish() { UserDefaults.standard.set("done", forKey: key) }
}
