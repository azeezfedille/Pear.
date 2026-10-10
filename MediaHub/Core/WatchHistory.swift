import Foundation
import Observation

/// Local progress for the active profile. Powers Continue Watching, resume, and "Because you watched…" suggestions.
/// (Simkl sync will mirror this later.)
@MainActor @Observable
final class WatchHistory {
    struct Entry: Codable, Identifiable {
        let item: MetaPreview
        var key: String            // stream id incl. episode, so resume only applies to the same episode
        var position: Double
        var duration: Double
        var updated: Date
        // Added later; optional so history saved by older builds still decodes.
        var season: Int? = nil
        var episode: Int? = nil
        var episodeTitle: String? = nil
        var thumb: String? = nil   // episode still, or the movie backdrop
        // Watched state, kept apart from playback progress. Optional so older saves still decode.
        var wS: Int? = nil         // series: everything up to wS·wE is watched (0·0 = explicitly cleared)
        var wE: Int? = nil
        var done: Bool? = nil      // movies: explicitly watched / unwatched
        var alias: String? = nil   // the title's other id (tt… vs tmdb:…)
        // Up Next dismissed while the watched marker was at hS·hE. It comes back once a later episode is finished.
        var hS: Int? = nil
        var hE: Int? = nil
        var id: String { item.id }
        func matches(_ x: String) -> Bool { item.id == x || alias == x }

        /// Series watched marker. Older saves without one fall back to a finished last episode.
        var watchedThrough: (season: Int, episode: Int)? {
            if let s = wS, let e = wE { return s == 0 ? nil : (s, e) }
            return isFinished && item.type == "series" ? seasonEpisode : nil
        }
        /// Watched as a whole: a series with a marker, a movie that was finished or marked.
        var isTitleWatched: Bool { item.type == "series" ? watchedThrough != nil : (done ?? isFinished) }
        var isInProgress: Bool { position > 30 && !isFinished }

        var progress: Double { duration > 0 ? min(max(position / duration, 0), 1) : 0 }
        /// Watched far enough that the next episode is the natural thing to offer.
        var isFinished: Bool { duration > 0 && position >= duration * 0.92 }
        /// Season/episode, from the stored fields or (older entries) parsed from the "2:5" key.
        var seasonEpisode: (season: Int, episode: Int)? {
            if let s = season, let e = episode { return (s, e) }
            let p = key.split(separator: ":").compactMap { Int($0) }
            return p.count == 2 ? (p[0], p[1]) : nil
        }
        /// Eligible for "Up Next": a finished series episode whose numbers we can read.
        var isUpNextCandidate: Bool {
            guard item.type == "series", let w = watchedThrough, !isInProgress else { return false }
            if let s = hS, let e = hE, (s, e) == (w.season, w.episode) { return false }
            return true
        }
    }
    private(set) var entries: [Entry] = []
    /// Everything that dropped off `entries` (the list is capped at 30 for Continue Watching) or was removed from it.
    /// Never shown in the UI; the profile statistics read it so no watched title is ever forgotten.
    private(set) var archive: [Entry] = []
    @ObservationIgnored private var profileID = ProfileKeys.activeID
    private var storeKey: String { ProfileKeys.scoped("watch.history", profileID) }
    private var archiveKey: String { ProfileKeys.scoped("watch.archive", profileID) }

    init() { entries = Self.read(storeKey); archive = Self.read(archiveKey) }

    /// Re-reads the active profile's history from storage (after a settings import).
    func reload() { profileID = ProfileKeys.activeID; entries = Self.read(storeKey); archive = Self.read(archiveKey) }

    /// Switches to another profile's history. No-op when it is already loaded.
    func load(profile id: String) {
        guard id != profileID else { return }
        profileID = id
        entries = Self.read(storeKey)
        archive = Self.read(archiveKey)
    }

    /// Live entries plus archived ones (a live entry wins when a title is in both).
    var allEntries: [Entry] {
        let live = Set(entries.map(\.id))
        return entries + archive.filter { !live.contains($0.id) }
    }

    private func stash(_ e: Entry) {
        archive.removeAll { $0.id == e.id }
        archive.append(e)
        persistArchive()
    }

    private static func read(_ key: String) -> [Entry] {
        guard let d = UserDefaults.standard.data(forKey: key),
              let e = try? JSONDecoder().decode([Entry].self, from: d) else { return [] }
        return e
    }

    var lastWatched: MetaPreview? { entries.first?.item }
    var continueEntries: [Entry] {
        entries.filter { $0.isInProgress }
    }
    /// Ids of the shows whose last episode is done — cheap to diff, so views use them as `.task(id:)` keys.
    var finishedSeries: Set<String> { Set(entries.compactMap { $0.isUpNextCandidate ? $0.id : nil }) }
    /// Shows whose last episode is done: candidates for "Up Next".
    var finishedEntries: [Entry] {
        entries.filter { $0.isUpNextCandidate }
    }
    var continueWatching: [MetaPreview] { continueEntries.map(\.item) }
    func entry(for id: String) -> Entry? {
        entries.first { $0.matches(id) } ?? archive.first { $0.matches(id) }
    }
    private func index(of id: String) -> Int? { entries.firstIndex { $0.matches(id) } }

    /// Records that two ids are the same title (tt… and tmdb:…), merging any split entries.
    func link(_ a: String, _ b: String) {
        guard a != b, let i = index(of: a), let j = index(of: b), i != j else {
            if a != b, let i = index(of: a), entries[i].alias == nil, entries[i].item.id != b { entries[i].alias = b; persist() }
            else if a != b, let i = index(of: b), entries[i].alias == nil, entries[i].item.id != a { entries[i].alias = a; persist() }
            return
        }
        var keep = entries[min(i, j)]; let other = entries[max(i, j)]
        if let w = other.watchedThrough, w >= (keep.watchedThrough ?? (0, 0)) { keep.wS = w.season; keep.wE = w.episode }
        if keep.done != true { keep.done = other.done ?? keep.done }
        keep.alias = keep.item.id == a ? b : a
        entries[min(i, j)] = keep
        entries.remove(at: max(i, j))
        persist()
    }

    /// New progress record for `item`. Watched state is carried over from the old entry and only ever raised
    /// by finishing an episode here; playing an episode partway never clears it.
    private func build(_ item: MetaPreview, key: String, position: Double, duration: Double,
                       season: Int?, episode: Int?, episodeTitle: String?, thumb: String?) -> Entry {
        let old = entry(for: item.id)
        var e = Entry(item: item, key: key, position: position, duration: duration, updated: .now,
                      season: season, episode: episode, episodeTitle: episodeTitle, thumb: thumb)
        e.alias = old?.alias
        e.done = old?.done
        e.hS = old?.hS; e.hE = old?.hE
        var wt = old?.watchedThrough
        if e.isFinished {
            if item.type == "series" {
                if let se = e.seasonEpisode, (se.season, se.episode) > (wt?.season ?? 0, wt?.episode ?? 0) { wt = se }
            } else { e.done = true }
        }
        if let wt { e.wS = wt.season; e.wE = wt.episode }
        else if old?.wS == 0 { e.wS = 0; e.wE = 0 }
        return e
    }

    func update(_ item: MetaPreview, key: String, position: Double, duration: Double,
                season: Int? = nil, episode: Int? = nil, episodeTitle: String? = nil, thumb: String? = nil) {
        let e = build(item, key: key, position: position, duration: duration,
                      season: season, episode: episode, episodeTitle: episodeTitle, thumb: thumb)
        entries.removeAll { $0.matches(item.id) || $0.matches(e.alias ?? item.id) }
        entries.insert(e, at: 0)
        if archive.contains(where: { $0.matches(item.id) }) {
            archive.removeAll { $0.matches(item.id) }
            persistArchive()
        }
        trim()
        persist()
    }

    /// Keeps the list near 30, but never pushes out a show that is in progress or has a watched marker.
    private func trim() {
        while entries.count > 30,
              let i = entries.lastIndex(where: { !$0.isInProgress && !($0.item.type == "series" && $0.watchedThrough != nil) }) {
            stash(entries.remove(at: i))
        }
        if entries.count > 100 { for d in entries[100...] { stash(d) }; entries = Array(entries.prefix(100)) }
    }

    /// Periodic progress save while a video plays. It goes straight to storage and leaves the observed lists alone,
    /// so Home, Library and every poster don't redraw behind the player every few seconds. The save when the
    /// player closes (`update`) brings the in-memory list up to date.
    func checkpoint(_ item: MetaPreview, key: String, position: Double, duration: Double,
                    season: Int? = nil, episode: Int? = nil, episodeTitle: String? = nil, thumb: String? = nil) {
        guard entries.contains(where: { $0.matches(item.id) }) else {
            update(item, key: key, position: position, duration: duration,
                   season: season, episode: episode, episodeTitle: episodeTitle, thumb: thumb)
            return
        }
        let e = build(item, key: key, position: position, duration: duration,
                      season: season, episode: episode, episodeTitle: episodeTitle, thumb: thumb)
        var list = entries
        list.removeAll { $0.matches(item.id) }
        list.insert(e, at: 0)
        if let d = try? JSONEncoder().encode(list) { UserDefaults.standard.set(d, forKey: storeKey) }
    }

    /// Hides a title from Continue Watching. Its progress still counts in the profile statistics,
    /// and a show with a watched marker stays (reset to no progress) so it keeps its marks and Up Next.
    func remove(_ id: String) {
        guard let i = index(of: id) else { return }
        if entries[i].item.type == "series", entries[i].watchedThrough != nil {
            entries[i].position = 0
        } else {
            stash(entries[i]); entries.remove(at: i)
        }
        persist()
    }

    /// Hides the Up Next card for a show until another episode is finished. The watched marker is untouched.
    func dismissUpNext(_ id: String) {
        guard let i = index(of: id), let w = entries[i].watchedThrough else { return }
        entries[i].hS = w.season; entries[i].hE = w.episode
        persist()
    }

    // MARK: Mark as watched (used by long-press menus on posters, seasons and episodes)

    /// Marks a title watched. Series go through `markThrough`; a movie becomes a finished entry.
    func markWatched(_ item: MetaPreview, key: String = "watched", season: Int? = nil, episode: Int? = nil,
                     duration: Double? = nil, episodeTitle: String? = nil, thumb: String? = nil) {
        let old = entry(for: item.id)
        if item.type == "series" {
            let s = season ?? old?.seasonEpisode?.season ?? 1
            let e = episode ?? old?.seasonEpisode?.episode ?? 1
            markThrough(episode: e, season: s, item: item, duration: duration, episodeTitle: episodeTitle, thumb: thumb)
            return
        }
        let d = max(duration ?? 0, old.map { $0.isFinished ? $0.duration : 0 } ?? 0, 60)
        update(item, key: key, position: d, duration: d, season: nil, episode: nil,
               episodeTitle: episodeTitle ?? old?.episodeTitle, thumb: thumb ?? old?.thumb)
    }

    /// Clears the watched state without dropping the rest of the record.
    func unmarkWatched(_ id: String) {
        guard let i = index(of: id) else { return }
        entries[i].wS = 0; entries[i].wE = 0; entries[i].done = false
        entries[i].hS = nil; entries[i].hE = nil
        if entries[i].isFinished { entries[i].position = 0 }
        persist()
    }

    /// Everything up to and including `season`/`episode` counts as watched afterwards.
    func isWatched(id: String? = nil, season s: Int, episode e: Int) -> Bool {
        let target = id ?? lastWatchedSeriesID ?? ""
        guard let w = entry(for: target)?.watchedThrough else { return false }
        return (w.season, w.episode) >= (s, e)
    }

    /// The show the caller most recently resolved ids for — used only as a hint; callers pass explicit ids where possible.
    @ObservationIgnored var lastWatchedSeriesID: String?

    private func setMarker(_ i: Int, _ m: (season: Int, episode: Int)?) {
        entries[i].wS = m?.season ?? 0
        entries[i].wE = m?.episode ?? 0
        persist()
    }

    /// Marks Sx·Ey watched, which covers every earlier episode too. Never lowers an existing marker.
    func markThrough(episode ep: Int, season s: Int, item: MetaPreview, duration: Double?,
                     episodeTitle: String? = nil, thumb: String? = nil) {
        let old = entry(for: item.id)
        if let w = old?.watchedThrough, (w.season, w.episode) >= (s, ep) { return }
        if let old, old.isInProgress, let i = index(of: old.id) {
            setMarker(i, (s, ep))       // keep the episode being watched as the progress record
            return
        }
        let d = max(duration ?? 0, old?.duration ?? 0, 60)
        update(item, key: "\(s):\(ep)", position: d, duration: d, season: s, episode: ep,
               episodeTitle: episodeTitle, thumb: thumb)
    }

    /// Pulls the watched marker back to just before Sx·Ey. Episode 1 of a later season leaves "season s-1 done"
    /// as (s, 0); S1E1 clears the marker. The progress record is left alone.
    func unmarkThrough(episode ep: Int, season s: Int, item: MetaPreview) {
        guard let i = index(of: item.id), let w = entries[i].watchedThrough, (w.season, w.episode) >= (s, ep) else { return }
        if ep > 1 { setMarker(i, (s, ep - 1)) }
        else if s > 1 { setMarker(i, (s, 0)) }
        else { setMarker(i, nil) }
    }

    private func persist() {
        if let d = try? JSONEncoder().encode(entries) { UserDefaults.standard.set(d, forKey: storeKey) }
    }
    private func persistArchive() {
        if let d = try? JSONEncoder().encode(archive) { UserDefaults.standard.set(d, forKey: archiveKey) }
    }
}

/// Time formatting shared by the player and the Continue Watching cards.
enum Fmt {
    /// 83 -> "1:23", 3725 -> "1:02:05"
    static func clock(_ s: Double) -> String {
        guard s.isFinite, s >= 0 else { return "0:00" }
        let t = Int(s), h = t / 3600, m = (t % 3600) / 60, sec = t % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
    }
    /// 2460 -> "41 min left", 4500 -> "1h 15m left"
    static func remaining(_ s: Double) -> String {
        let m = max(Int((max(s, 0) / 60).rounded(.up)), 1)
        if m >= 60 { return m % 60 == 0 ? "\(m / 60)h left" : "\(m / 60)h \(m % 60)m left" }
        return "\(m) min left"
    }
}
