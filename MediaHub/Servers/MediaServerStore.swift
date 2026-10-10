import Foundation
import Observation

/// The Jellyfin and Plex servers this device is signed in to. Device-wide like add-ons (not per profile).
/// Account details are kept in UserDefaults, access tokens in the Keychain, and neither is part of a settings backup:
/// after restoring a backup, sign in to the servers again.
///
/// Each enabled server is exposed as a synthetic add-on (`Addon.server`) through `addons`, which `AddonStore.enabledAddons`
/// puts first in the list, so a title you own is offered ahead of every other source.
@MainActor @Observable
final class MediaServerStore {
    static let shared = MediaServerStore()

    private(set) var accounts: [MediaServerAccount] = []
    /// Enabled servers as add-ons, in the order they were added.
    private(set) var addons: [Addon] = []
    /// Bumps whenever the list or a server's settings change, so Home reloads its rows.
    private(set) var revision = 0

    @ObservationIgnored private var backends: [String: any MediaServerBackend] = [:]
    private static let key = "mediaservers.list"

    private init() {
        accounts = Self.read()
        rebuild()
    }

    // MARK: Tokens

    static func tokenKey(_ id: String) -> String { "mediaserver.token." + id }
    private static func token(for id: String) -> String? { Keychain.get(tokenKey(id)) }

    // MARK: Adding and removing

    func addJellyfin(name: String, base: URL, session: JellyfinAPI.Session) {
        let account = MediaServerAccount(id: Self.newID(), kind: .jellyfin, name: name, baseURL: base.absoluteString,
                                         userID: session.userID)
        // Signing in again to the same server and user replaces the old entry.
        accounts.removeAll { $0.kind == .jellyfin && $0.baseURL == account.baseURL && $0.userID == account.userID }
        insert(account, token: session.token)
    }

    func addPlex(name: String, serverID: String, base: String, alternates: [String], token: String) {
        let account = MediaServerAccount(id: Self.newID(), kind: .plex, name: name, baseURL: base,
                                         alternates: alternates, serverID: serverID)
        accounts.removeAll { $0.kind == .plex && $0.serverID == serverID }
        insert(account, token: token)
    }

    private func insert(_ account: MediaServerAccount, token: String) {
        Keychain.set(token, Self.tokenKey(account.id))
        accounts.append(account)
        save()
        rebuildDroppingStale()
    }

    func remove(_ id: String) {
        accounts.removeAll { $0.id == id }
        Keychain.remove(Self.tokenKey(id))
        save()
        rebuildDroppingStale()
    }

    // MARK: Settings

    func setEnabled(_ id: String, _ on: Bool) { update(id) { $0.enabled = on } }
    func setShowOnHome(_ id: String, _ on: Bool) { update(id) { $0.showOnHome = on } }

    private func update(_ id: String, _ change: (inout MediaServerAccount) -> Void) {
        guard let i = accounts.firstIndex(where: { $0.id == id }) else { return }
        change(&accounts[i])
        save()
        rebuild()
    }

    /// Foreground hook: lets each server prepare (Plex lists its library once, so opening a title is quick).
    func warm() {
        for backend in backends.values { Task { await backend.warm() } }
    }

    // MARK: Building the add-on list

    /// Accounts that were removed or replaced lose their cached backend (and with it any cached library list).
    private func rebuildDroppingStale() {
        let ids = Set(accounts.map(\.id))
        backends = backends.filter { ids.contains($0.key) }
        rebuild()
    }

    private func rebuild() {
        var table: [String: any MediaServerBackend] = [:]
        var list: [Addon] = []
        for account in accounts where account.enabled {
            guard let token = Self.token(for: account.id), let addon = Addon.server(account) else { continue }
            let backend: (any MediaServerBackend)?
            if let existing = backends[account.id] { backend = existing } else { backend = Self.makeBackend(account, token: token) }
            guard let backend else { continue }
            backends[account.id] = backend
            table[addon.id] = backend
            list.append(addon)
        }
        addons = list
        MediaServerRegistry.shared.set(table)
        revision += 1
    }

    private static func makeBackend(_ account: MediaServerAccount, token: String) -> (any MediaServerBackend)? {
        switch account.kind {
        case .jellyfin: return JellyfinBackend(account: account, token: token)
        case .plex: return PlexBackend(account: account, token: token)
        }
    }

    // MARK: Storage

    private static func newID() -> String { UUID().uuidString.lowercased() }

    private func save() {
        if let d = try? JSONEncoder().encode(accounts) { UserDefaults.standard.set(d, forKey: Self.key) }
    }

    private static func read() -> [MediaServerAccount] {
        guard let d = UserDefaults.standard.data(forKey: key),
              let list = try? JSONDecoder().decode([MediaServerAccount].self, from: d) else { return [] }
        return list
    }
}
