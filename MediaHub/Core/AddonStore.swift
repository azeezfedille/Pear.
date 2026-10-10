import SwiftUI
import Observation

@MainActor @Observable
final class AddonStore {
    /// Every installed add-on, in the user's order (the order is saved).
    private(set) var addons: [Addon] = []
    /// Ids of installed add-ons the user switched off. They stay installed and keep their place in the
    /// order, but are skipped everywhere add-ons are used (Home, search, sources, downloads).
    private(set) var disabledIDs: Set<String> = []
    /// Installed add-ons that are switched on, in the user's order. Media servers are not included.
    var enabledInstalledAddons: [Addon] { addons.filter { !disabledIDs.contains($0.id) } }
    /// Everything sources, search and Home draw from: the signed-in Jellyfin / Plex servers first (a title in your own
    /// library is offered before any other source), then the installed add-ons that are switched on.
    var enabledAddons: [Addon] { MediaServerStore.shared.addons + enabledInstalledAddons }
    /// Ids of add-ons whose catalogues the user picks one by one instead of getting them all on Home. AIOMetadata is
    /// recognised on its own (`Addon.isAIOMetadata`); this holds the ones switched on by hand, for a copy hosted
    /// under another name.
    private(set) var pickerIDs: Set<String> = []
    /// Bumps after a reload so Home refetches catalogs even though the add-on ids are unchanged.
    private(set) var revision = 0
    private let key = "addon.manifestURLs"
    private static let disabledKey = "addon.disabled"
    private static let pickerKey = "addon.catalogPicker"
    /// Every saved add-on URL, in order: installed, not-yet-loaded and unreachable ones alike. This (not `addons`) is
    /// what gets written to storage, so a half-finished launch restore can never overwrite the saved list.
    private(set) var known: [String] = []
    /// True while the launch restore is still fetching manifests.
    private(set) var isRestoring = true
    @ObservationIgnored private var restoreTask: Task<Void, Never>?
    /// Saved add-ons whose manifest couldn't be fetched (offline, server asleep). Retried by `retryUnreachable()`.
    var unreachable: [String] {
        if isRestoring { return [] }
        let loaded = Set(addons.map { $0.manifestURL.absoluteString })
        return known.filter { !loaded.contains($0) }
    }
    // Public metadata-only add-on, so Home isn't empty on first launch.
    private static let defaults = ["https://v3-cinemeta.strem.io/manifest.json"]

    init() {
        disabledIDs = Self.loadDisabled()
        pickerIDs = Self.loadPickers()
        let saved = UserDefaults.standard.stringArray(forKey: key) ?? Self.defaults
        known = saved
        restoreTask = Task { await restore(saved) }
    }

    private static func loadDisabled() -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: disabledKey) ?? [])
    }

    private static func loadPickers() -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: pickerKey) ?? [])
    }

    func isEnabled(_ addon: Addon) -> Bool { !disabledIDs.contains(addon.id) }

    /// True when this add-on's catalogues are added to Home one by one (Settings -> Content & catalogues ->
    /// AIOMetadata) instead of all showing by default.
    func usesCatalogPicker(_ addon: Addon) -> Bool { addon.isAIOMetadata || pickerIDs.contains(addon.id) }

    /// The add-on Home's theme rows are enriched with: a switched-on AIOMetadata (or one marked as such by hand) that
    /// serves `meta`. nil when there isn't one, and the rows just use TMDB.
    var enrichmentAddon: Addon? {
        enabledAddons.first { usesCatalogPicker($0) && ($0.manifest.resources?.contains { $0.name == "meta" } ?? false) }
    }

    /// Treats an add-on like AIOMetadata even though it doesn't say so by name (a self-hosted copy).
    func setCatalogPicker(_ addon: Addon, _ on: Bool) {
        if on { pickerIDs.insert(addon.id) } else { pickerIDs.remove(addon.id) }
        UserDefaults.standard.set(pickerIDs.sorted(), forKey: Self.pickerKey)
    }

    /// Switches an add-on on or off without uninstalling it.
    func setEnabled(_ addon: Addon, _ on: Bool) {
        if on { disabledIDs.remove(addon.id) } else { disabledIDs.insert(addon.id) }
        persistDisabled()
    }

    /// Reorders the installed add-ons (drag in Settings -> Add-ons).
    func move(from source: IndexSet, to destination: Int) {
        addons.move(fromOffsets: source, toOffset: destination)
        // Installed ones take the new order; unreachable ones stay saved, after them.
        let order = addons.map { $0.manifestURL.absoluteString }
        known = order + known.filter { !order.contains($0) }
        persist()
    }

    func add(_ input: String) async throws {
        await restoreTask?.value   // never save while the launch restore is mid-flight
        let url = try Addon.normalize(input)
        guard !addons.contains(where: { $0.manifestURL == url }) else { return }
        let manifest = try await AddonClient.shared.manifest(at: url, fresh: true)
        if !known.contains(url.absoluteString) { known.append(url.absoluteString) }
        addons.append(Addon(manifestURL: url, manifest: manifest))
        sortToKnown()
        persist()
    }

    /// Re-fetches one add-on's manifest (bypassing the HTTP cache) and refreshes its catalogs.
    func reload(_ addon: Addon) async throws {
        await AddonClient.shared.clearCache()
        let m = try await AddonClient.shared.manifest(at: addon.manifestURL, fresh: true)
        guard let i = addons.firstIndex(where: { $0.id == addon.id }) else { throw URLError(.resourceUnavailable) }
        addons[i] = Addon(manifestURL: addon.manifestURL, manifest: m)
        revision += 1
    }

    /// Reloads every add-on. Returns how many failed (those keep their old manifest).
    func reloadAll() async -> Int {
        await restoreTask?.value
        await AddonClient.shared.clearCache()
        var failed = 0
        for a in addons {
            if let m = try? await AddonClient.shared.manifest(at: a.manifestURL, fresh: true),
               let i = addons.firstIndex(where: { $0.id == a.id }) {
                addons[i] = Addon(manifestURL: a.manifestURL, manifest: m)
            } else { failed += 1 }
        }
        // Add-ons that never loaded aren't in `addons`, so the loop above can't reach them: retry them too.
        await retryUnreachable()
        failed += unreachable.count
        revision += 1
        return failed
    }

    /// Tries again for saved add-ons that couldn't be fetched earlier. Call when the app returns to the foreground
    /// or the connection comes back. Without this, an add-on that missed launch stays hidden until a restart.
    func retryUnreachable() async {
        await restoreTask?.value
        let pending = unreachable
        guard !pending.isEmpty else { return }
        var got = false
        for s in pending {
            guard let url = try? Addon.normalize(s),
                  let m = try? await AddonClient.shared.manifest(at: url, fresh: true),
                  !addons.contains(where: { $0.manifestURL == url }) else { continue }
            addons.append(Addon(manifestURL: url, manifest: m)); got = true
        }
        if got { sortToKnown(); revision += 1 }
    }

    /// Re-reads the saved add-on list (after a settings import).
    func reloadFromDefaults() async {
        disabledIDs = Self.loadDisabled()
        pickerIDs = Self.loadPickers()
        await restoreTask?.value
        let saved = UserDefaults.standard.stringArray(forKey: key) ?? Self.defaults
        known = saved
        addons = []
        restoreTask = Task { await restore(saved) }
        await restoreTask?.value
        revision += 1
    }

    func remove(at offsets: IndexSet) {
        let gone = offsets.map { addons[$0].id }
        addons.remove(atOffsets: offsets)
        known.removeAll { gone.contains($0) }
        disabledIDs.subtract(gone)
        pickerIDs.subtract(gone)
        persist()
        persistDisabled()
        UserDefaults.standard.set(pickerIDs.sorted(), forKey: Self.pickerKey)
    }

    // TODO: move to Keychain — debrid add-on URLs embed API keys.
    private func persist() {
        UserDefaults.standard.set(known, forKey: key)
    }

    private func persistDisabled() {
        UserDefaults.standard.set(disabledIDs.sorted(), forKey: Self.disabledKey)
    }

    private func sortToKnown() {
        let pos = Dictionary(known.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        addons.sort { (pos[$0.manifestURL.absoluteString] ?? .max) < (pos[$1.manifestURL.absoluteString] ?? .max) }
    }

    /// Fetches every saved manifest. Add-ons appear as each one answers; a failure only leaves that one out
    /// (it stays in `known`, so it is still saved and `retryUnreachable()` can bring it back).
    private func restore(_ urls: [String]) async {
        isRestoring = true
        defer { isRestoring = false }
        await withTaskGroup(of: Addon?.self) { group in
            for s in urls {
                group.addTask {
                    guard let url = try? Addon.normalize(s),
                          let m = try? await AddonClient.shared.manifest(at: url) else { return nil }
                    return Addon(manifestURL: url, manifest: m)
                }
            }
            for await a in group {
                guard let a, known.contains(a.id), !addons.contains(where: { $0.id == a.id }) else { continue }   // skips ones removed meanwhile
                addons.append(a)
                sortToKnown()
            }
        }
    }
}
