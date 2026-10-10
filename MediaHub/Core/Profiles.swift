import Foundation
import Observation

/// One person using the app. Each profile has its own watch history and (when Simkl isn't connected)
/// its own local library. Add-ons, API keys, theme and playback settings stay shared.
struct Profile: Codable, Identifiable, Hashable, Sendable {
    var id: String
    var name: String
    var colorHex: String
    /// SF Symbol shown in the avatar. Empty = the first letter of the name.
    var symbol: String = ""
    /// Show the connected Simkl account's name and picture instead of the name and icon above. Optional so older saves decode.
    var simklIdentity: Bool? = nil

    /// The first profile. It keeps the pre-profiles storage keys, so history saved by older builds carries over.
    static let defaultID = "default"

    var initial: String {
        name.trimmingCharacters(in: .whitespaces).first.map { String($0).uppercased() } ?? "?"
    }
}

/// Storage keys, kept outside the @MainActor stores so any of them can read the active profile at init.
enum ProfileKeys {
    static let list = "profiles.list"
    static let active = "profiles.active"
    /// Per-profile data that must be wiped when a profile is deleted.
    static let scopedBases = ["watch.history", "watch.archive", "watch.log", "library.local", "library.prefs", "content.prefs"]

    static var activeID: String { UserDefaults.standard.string(forKey: active) ?? Profile.defaultID }

    /// "watch.history" for the first profile (legacy key), "watch.history.<id>" for the rest.
    static func scoped(_ base: String, _ profile: String) -> String {
        profile == Profile.defaultID ? base : "\(base).\(profile)"
    }
}

@MainActor @Observable
final class ProfileStore {
    private(set) var profiles: [Profile]
    private(set) var activeID: String
    static let limit = 8

    init() {
        var list = UserDefaults.standard.data(forKey: ProfileKeys.list)
            .flatMap { try? JSONDecoder().decode([Profile].self, from: $0) } ?? []
        if list.isEmpty { list = [Profile(id: Profile.defaultID, name: "Me", colorHex: Theme.defaultHex)] }
        let saved = ProfileKeys.activeID
        profiles = list
        activeID = list.contains { $0.id == saved } ? saved : list[0].id
    }

    /// Re-reads profiles from storage (after a settings import).
    func reload() {
        var list = UserDefaults.standard.data(forKey: ProfileKeys.list)
            .flatMap { try? JSONDecoder().decode([Profile].self, from: $0) } ?? []
        if list.isEmpty { list = [Profile(id: Profile.defaultID, name: "Me", colorHex: Theme.defaultHex)] }
        let saved = ProfileKeys.activeID
        profiles = list
        activeID = list.contains { $0.id == saved } ? saved : list[0].id
    }

    var active: Profile { profiles.first { $0.id == activeID } ?? profiles[0] }
    var canAdd: Bool { profiles.count < Self.limit }

    func select(_ id: String) {
        guard id != activeID, profiles.contains(where: { $0.id == id }) else { return }
        activeID = id
        UserDefaults.standard.set(id, forKey: ProfileKeys.active)
    }

    @discardableResult
    func add(name: String, colorHex: String, symbol: String) -> Profile? {
        guard canAdd else { return nil }
        let p = Profile(id: UUID().uuidString, name: Self.clean(name), colorHex: colorHex, symbol: symbol)
        profiles.append(p)
        save()
        return p
    }

    func update(_ p: Profile) {
        guard let i = profiles.firstIndex(where: { $0.id == p.id }) else { return }
        var u = p
        u.name = Self.clean(p.name)
        profiles[i] = u
        save()
    }

    /// Removes the profile and its history / local library. The last remaining profile can't be deleted.
    func delete(_ id: String) {
        guard profiles.count > 1, let i = profiles.firstIndex(where: { $0.id == id }) else { return }
        profiles.remove(at: i)
        for base in ProfileKeys.scopedBases {
            UserDefaults.standard.removeObject(forKey: ProfileKeys.scoped(base, id))
        }
        if activeID == id { select(profiles[0].id) }
        save()
    }

    private static func clean(_ name: String) -> String {
        let t = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(20))
        return t.isEmpty ? "Profile" : t
    }

    private func save() {
        UserDefaults.standard.set(try? JSONEncoder().encode(profiles), forKey: ProfileKeys.list)
    }
}
