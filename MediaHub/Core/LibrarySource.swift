import Foundation
import Observation

/// Where a profile's library lives.
/// - `.local`: the library kept on this device (plan to watch / watched, plus Watching from the profile's own
///   history and watch-time tracking). Nothing is sent to Simkl: no scrobbling, no list changes, no background sync.
/// - `.simkl`: Simkl's lists are the library, and playback is scrobbled to Simkl.
enum LibrarySource: String, Codable, CaseIterable, Identifiable, Sendable {
    case local, simkl
    var id: String { rawValue }
}

/// One title to add to a Simkl list.
struct SimklListAdd: Sendable {
    let imdb: String?
    let tmdb: Int?
    let isMovie: Bool
    /// "plantowatch" | "watching" | "completed"
    let list: String
}

/// Per-profile library settings: which library the profile uses, whether it keeps itself in sync with Simkl, and what
/// the last sync saw. Everything is event-driven (no timers): a sync runs when you tap Sync now, or, with automatic
/// sync on, when the app comes to the foreground at most every 15 minutes.
@MainActor @Observable
final class LibraryPrefs {
    private struct Stored: Codable {
        var choice: LibrarySource?
        var autoSync = false
        var lastSync: Date?
        /// Every id of every title that was on both sides after the last sync. It lets the next sync tell
        /// "removed on the other side" (leave it alone) from "new here" (send it across).
        var synced: Set<String> = []
    }

    private var stored: Stored
    private(set) var isSyncing = false
    /// Outcome of the last sync, for the settings screen.
    private(set) var report: String?
    @ObservationIgnored private var profileID = ProfileKeys.activeID

    private static func key(_ profile: String) -> String { ProfileKeys.scoped("library.prefs", profile) }

    init() { stored = Self.read(Self.key(ProfileKeys.activeID)) }

    /// Switches to another profile's settings. No-op when already loaded.
    func load(profile id: String) {
        guard id != profileID else { return }
        profileID = id
        stored = Self.read(Self.key(id))
        report = nil
    }

    /// Re-reads from storage (after a settings import).
    func reload() {
        profileID = ProfileKeys.activeID
        stored = Self.read(Self.key(profileID))
        report = nil
    }

    // MARK: Reading

    /// The library in use right now. Simkl only counts while it is connected; before the first explicit choice,
    /// a connected Simkl is the library (what the app always did) and everyone else uses the local one.
    func source(_ simkl: SimklStore) -> LibrarySource {
        guard simkl.isConnected else { return .local }
        return stored.choice ?? .simkl
    }

    func usesSimkl(_ simkl: SimklStore) -> Bool { source(simkl) == .simkl }
    var autoSync: Bool { stored.autoSync }
    var lastSync: Date? { stored.lastSync }

    // MARK: Changing

    func choose(_ source: LibrarySource) {
        guard stored.choice != source else { return }
        stored.choice = source
        save()
    }

    func setAutoSync(_ on: Bool) {
        guard stored.autoSync != on else { return }
        stored.autoSync = on
        save()
    }

    // MARK: Sync

    /// Merges this profile's local library with Simkl, both ways, without deleting anything on either side:
    /// - Simkl's Plan to Watch and Completed titles that are missing here are added here.
    /// - Local titles (and titles in Continue Watching) that Simkl lacks are added to Simkl.
    /// - "Watched" wins when the two sides disagree.
    /// - A title that was on both sides at the last sync and is gone from one side now is treated as removed on purpose
    ///   and is not brought back.
    /// Unless `force`, it does nothing within 15 minutes of the last sync.
    func sync(simkl: SimklStore, library: LocalLibrary, history: WatchHistory, force: Bool) async {
        guard simkl.isConnected, !isSyncing else { return }
        if !force, let last = stored.lastSync, Date().timeIntervalSince(last) < 900 { return }
        isSyncing = true
        defer { isSyncing = false }
        report = nil

        // Let a sync that is already running (launch, pull to refresh) finish first, so the merge never sees a half-loaded list.
        while simkl.isSyncing { try? await Task.sleep(for: .milliseconds(250)) }
        await simkl.sync(force: true)
        if let problem = simkl.syncError { report = problem; return }

        let rows = simkl.library
        let local = library.entries
        let entries = history.entries
        let known = stored.synced
        let since = stored.lastSync
        // Matching is a few hundred titles at most, but it still stays off the main thread.
        let plan = await Task.detached(priority: .utility) {
            LibrarySync.plan(simklRows: rows, local: local, history: entries, synced: known, since: since)
        }.value

        library.apply(plan.pulls.map { ($0.item, $0.status) })

        var sent = 0
        var failed = false
        if !plan.pushes.isEmpty {
            if await simkl.add(plan.pushes) {
                sent = plan.pushes.count
                await simkl.sync(force: true)           // the library tab should show what was just added
            } else {
                failed = true
            }
        }

        stored.synced = failed ? plan.synced.subtracting(plan.pushedIDs) : plan.synced
        if !failed { stored.lastSync = Date() }
        save()

        if failed { report = "Couldn't send to Simkl. Received \(plan.pulls.count); try again in a moment." }
        else if sent == 0 && plan.pulls.isEmpty { report = "Already in sync." }
        else { report = "Received \(plan.pulls.count) · Sent \(sent)" }
    }

    // MARK: Storage

    private func save() {
        if let d = try? JSONEncoder().encode(stored) { UserDefaults.standard.set(d, forKey: Self.key(profileID)) }
    }

    private static func read(_ key: String) -> Stored {
        guard let d = UserDefaults.standard.data(forKey: key),
              let s = try? JSONDecoder().decode(Stored.self, from: d) else { return Stored() }
        return s
    }
}

/// The merge itself: pure data in, a list of changes out.
enum LibrarySync {
    struct Pull: Sendable { let item: MetaPreview; let status: LocalLibrary.Status }

    struct Plan: Sendable {
        var pulls: [Pull] = []
        var pushes: [SimklListAdd] = []
        /// Ids to remember as present on both sides after this sync.
        var synced: Set<String> = []
        /// The subset of `synced` that only exists on both sides if the push succeeds.
        var pushedIDs: Set<String> = []
    }

    private struct Remote { let item: MetaPreview; let status: String }

    private static func nameKey(_ m: MetaPreview, year: Bool) -> String {
        "\(m.type)|\(m.name.lowercased())" + (year ? "|\(m.year ?? 0)" : "")
    }

    private static func add(_ m: MetaPreview, aliases: [String], list: String) -> SimklListAdd? {
        let ids = [m.id] + aliases
        let isMovie = m.type != "series"
        if let tt = ids.first(where: { $0.hasPrefix("tt") }) {
            return SimklListAdd(imdb: tt, tmdb: nil, isMovie: isMovie, list: list)
        }
        if let t = ids.first(where: { $0.hasPrefix("tmdb:") }), let n = Int(t.dropFirst(5)) {
            return SimklListAdd(imdb: nil, tmdb: n, isMovie: isMovie, list: list)
        }
        return nil
    }

    static func plan(simklRows: [CatalogRow], local: [LocalLibrary.Entry], history: [WatchHistory.Entry],
                     synced: Set<String>, since: Date?) -> Plan {
        var remote: [Remote] = []
        for row in simklRows where row.id.hasPrefix("simkl-") {
            let status = String(row.id.dropFirst("simkl-".count))
            for item in row.items { remote.append(Remote(item: item, status: status)) }
        }
        var byID: [String: Int] = [:], byName: [String: Int] = [:], byLoose: [String: Int] = [:]
        for (i, r) in remote.enumerated() {
            byID[r.item.id] = i
            byName[nameKey(r.item, year: true)] = i
            byLoose[nameKey(r.item, year: false)] = i
        }
        func find(_ m: MetaPreview, aliases: [String]) -> Int? {
            for id in [m.id] + aliases { if let i = byID[id] { return i } }
            if let i = byName[nameKey(m, year: true)] { return i }
            if m.year == nil, let i = byLoose[nameKey(m, year: false)] { return i }
            return nil
        }

        var plan = Plan()
        var matched = Set<Int>()
        var covered = Set<String>()

        for e in local {
            let aliases = e.alias.map { [$0] } ?? []
            let ids = [e.item.id] + aliases
            covered.formUnion(ids)
            if let i = find(e.item, aliases: aliases) {
                matched.insert(i)
                plan.synced.formUnion(ids)
                plan.synced.insert(remote[i].item.id)
                if e.status == .planToWatch && remote[i].status == "completed" {
                    plan.pulls.append(Pull(item: e.item, status: .watched))
                } else if e.status == .watched && remote[i].status != "completed",
                          let p = add(e.item, aliases: aliases, list: "completed") {
                    plan.pushes.append(p)
                }
            } else if !synced.isDisjoint(with: ids), e.added <= (since ?? .distantFuture) {
                // On both sides last time, gone from Simkl now: removed there on purpose. Keep it here, don't resend.
                plan.synced.formUnion(ids)
            } else if let p = add(e.item, aliases: aliases, list: e.status == .watched ? "completed" : "plantowatch") {
                plan.pushes.append(p)
                plan.synced.formUnion(ids)
                plan.pushedIDs.formUnion(ids)
            }
        }

        for (i, r) in remote.enumerated() where !matched.contains(i) {
            // "Watching" on Simkl has no local list of its own: here it comes from the profile's history.
            guard r.status == "completed" || r.status == "plantowatch" else { continue }
            plan.synced.insert(r.item.id)
            if synced.contains(r.item.id) { continue }              // removed here after the last sync
            plan.pulls.append(Pull(item: r.item, status: r.status == "completed" ? .watched : .planToWatch))
        }

        // Things being watched that aren't saved anywhere: they go to Simkl as Watching (or Completed for a finished movie).
        for h in history where !covered.contains(h.id) && plan.pushes.count < 300 {
            if find(h.item, aliases: []) != nil || synced.contains(h.id) { continue }
            let list: String?
            if h.item.type != "series" && h.isFinished { list = "completed" }
            else if h.position > 30 { list = "watching" }
            else { list = nil }
            if let list, let p = add(h.item, aliases: [], list: list) {
                plan.pushes.append(p)
                plan.synced.insert(h.id)
                plan.pushedIDs.insert(h.id)
            }
        }
        return plan
    }
}
