import Foundation
import Observation

/// The active profile's own watchlist, stored on this device. Used by Library and the detail page
/// whenever Simkl isn't connected (Simkl, when connected, is the library instead).
@MainActor @Observable
final class LocalLibrary {
    enum Status: String, Codable, Sendable { case planToWatch, watched }

    struct Entry: Codable, Identifiable, Hashable {
        let item: MetaPreview
        var status: Status
        /// The same title under its other id (a TMDB item saved from Explore also answers to its IMDb id).
        var alias: String? = nil
        var added: Date
        var id: String { item.id }
    }

    private(set) var entries: [Entry] = []
    @ObservationIgnored private var profileID = ProfileKeys.activeID
    private var storeKey: String { ProfileKeys.scoped("library.local", profileID) }

    init() { entries = Self.read(storeKey) }

    /// Re-reads the active profile's library from storage (after a settings import).
    func reload() { profileID = ProfileKeys.activeID; entries = Self.read(storeKey) }

    /// Switches to another profile's library. No-op when it is already loaded.
    func load(profile id: String) {
        guard id != profileID else { return }
        profileID = id
        entries = Self.read(storeKey)
    }

    // MARK: Lookup

    func entry(for id: String) -> Entry? { entries.first { $0.item.id == id || $0.alias == id } }

    // MARK: Changes

    /// Adds the title, or changes its status. Either way it moves to the front of its row.
    func set(_ item: MetaPreview, status: Status) {
        if let i = entries.firstIndex(where: { $0.item.id == item.id || $0.alias == item.id }) {
            var e = entries.remove(at: i)
            e.status = status
            e.added = .now
            entries.insert(e, at: 0)
        } else {
            entries.insert(Entry(item: item, status: status, added: .now), at: 0)
        }
        persist()
    }

    /// Applies many changes with a single save and a single change notification (library sync), instead of one
    /// encode-and-write per title. New titles go to the front in the order given; an existing title only moves
    /// when its status changes.
    func apply(_ changes: [(MetaPreview, Status)]) {
        guard !changes.isEmpty else { return }
        var list = entries
        var fresh: [Entry] = []
        let base = Date()
        for (n, change) in changes.enumerated() {
            let (item, status) = change
            let stamp = base.addingTimeInterval(-Double(n))        // keeps the order the changes arrived in
            if let i = list.firstIndex(where: { $0.item.id == item.id || $0.alias == item.id }) {
                if list[i].status != status { list[i].status = status; list[i].added = stamp }
            } else {
                fresh.append(Entry(item: item, status: status, added: stamp))
            }
        }
        entries = fresh + list
        persist()
    }

    func setAlias(_ alias: String, for id: String) {
        guard let i = entries.firstIndex(where: { $0.item.id == id }), entries[i].alias == nil else { return }
        entries[i].alias = alias
        persist()
    }

    func remove(_ id: String) {
        entries.removeAll { $0.item.id == id || $0.alias == id }
        persist()
    }

    /// Drops a saved title from the library without touching its watch history.
    func unsave(_ id: String) { remove(id) }

    /// Called by the player when a movie finishes: only titles already saved are moved, nothing new is added.
    func markWatchedIfSaved(_ id: String) {
        guard let e = entry(for: id), e.status != .watched else { return }
        set(e.item, status: .watched)
    }

    // MARK: Rows for the Library tab

    /// "Watching" comes from the profile's watch history; the other two are what the user saved.
    func rows(watching: [MetaPreview]) -> [CatalogRow] {
        let watched = entries.filter { $0.status == .watched }
        let inProgress = watching.filter { w in !watched.contains { $0.item.id == w.id || $0.alias == w.id } }
        var out: [CatalogRow] = []
        func add(_ key: String, _ title: String, _ symbol: String, _ items: [MetaPreview]) {
            guard !items.isEmpty else { return }
            // CatalogRow compares by id only, so the id carries the contents: a changed row must look like a new one.
            var h = Hasher()
            items.forEach { h.combine($0.id) }
            out.append(CatalogRow(id: "local-\(key)-\(h.finalize())", title: title, items: items, symbol: symbol))
        }
        add("watching", "Watching", "eye.fill", inProgress)
        add("plan", "Plan to Watch", "bookmark.fill", entries.filter { $0.status == .planToWatch }.map(\.item))
        add("watched", "Watched", "checkmark.circle.fill", watched.map(\.item))
        return out
    }

    // MARK: Storage

    private func persist() {
        if let d = try? JSONEncoder().encode(entries) { UserDefaults.standard.set(d, forKey: storeKey) }
    }

    private static func read(_ key: String) -> [Entry] {
        guard let d = UserDefaults.standard.data(forKey: key),
              let e = try? JSONDecoder().decode([Entry].self, from: d) else { return [] }
        return e
    }
}
