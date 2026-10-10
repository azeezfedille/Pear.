import Foundation
import Observation

// MARK: - Per-title facts (genres, runtime, year, season sizes)

/// What the statistics need to know about a title. Fetched once from TMDB and kept on disk (ids never change).
struct TitleFacts: Codable, Sendable {
    var genres: [String] = []
    var runtime: Int? = nil              // minutes per episode, or of the movie
    var year: Int? = nil
    var seasons: [Int: Int] = [:]        // season number -> episode count (specials excluded)
    var totalEpisodes: Int? = nil
}

actor TitleFactsStore {
    static let shared = TitleFactsStore()
    private let key = "stats.titleFacts"
    private var cache: [String: TitleFacts]

    init() {
        if let d = UserDefaults.standard.data(forKey: "stats.titleFacts"),
           let v = try? JSONDecoder().decode([String: TitleFacts].self, from: d) { cache = v } else { cache = [:] }
    }

    func snapshot() -> [String: TitleFacts] { cache }

    /// Cached facts, else one TMDB request (not cached when it fails, so offline never poisons the store).
    func facts(for item: MetaPreview) async -> TitleFacts? {
        if let hit = cache[item.id] { return hit }
        guard let d = await TMDBClient.shared.basicDetails(for: item.id, type: item.type) else { return nil }
        var f = TitleFacts()
        f.genres = (d.genres ?? []).map(\.name)
        if let m = d.minutes, m > 0 { f.runtime = m }
        f.year = (d.firstAirDate ?? d.releaseDate).flatMap { Int($0.prefix(4)) }
        for s in d.seasons ?? [] where s.seasonNumber > 0 {
            if let c = s.episodeCount, c > 0 { f.seasons[s.seasonNumber] = c }
        }
        f.totalEpisodes = f.seasons.isEmpty ? d.numberOfEpisodes : f.seasons.values.reduce(0, +)
        cache[item.id] = f
        return f
    }

    func save() {
        if let d = try? JSONEncoder().encode(cache) { UserDefaults.standard.set(d, forKey: key) }
    }
}

// MARK: - Results

enum StatKind: String, CaseIterable, Identifiable {
    case all = "All", shows = "Shows", movies = "Movies"
    var id: String { rawValue }
    func includes(_ t: StatTitle) -> Bool {
        switch self {
        case .all: return true
        case .shows: return t.isSeries
        case .movies: return !t.isSeries
        }
    }
}

struct StatTitle: Identifiable {
    enum Status { case watching, completed, planned }
    let id: String
    let item: MetaPreview
    var status: Status
    var episodes: Int            // shows: episodes seen. Movies: 0
    var minutes: Double          // time spent on it (episodes x runtime, or the movie)
    var facts: TitleFacts?
    var isSeries: Bool { item.type == "series" }
    var year: Int? { facts?.year ?? item.year }
}

struct ProfileStats {
    enum HoursSource { case tracked, estimated, none }
    struct Share: Identifiable { let id: String; let percent: Double }
    struct DayPart: Identifiable { let id: String; let symbol: String; let range: String; let percent: Double }
    struct Era { let buckets: [Share]; let medianYear: Int?; let recentShare: Double }

    var titles: [StatTitle] = []
    var hourSeconds = Array(repeating: 0.0, count: 24)
    var hoursSource: HoursSource = .none
    var trackedSeconds = 0.0
    var trackedDailySeconds: Double?
    var earliest: Date?

    // MARK: Counts

    func count(_ s: StatTitle.Status, _ kind: StatKind = .all) -> Int {
        titles.filter { $0.status == s && kind.includes($0) }.count
    }
    var episodesSeen: Int { titles.reduce(0) { $0 + $1.episodes } }

    // MARK: Watch time

    func minutes(_ kind: StatKind) -> Double { titles.filter { kind.includes($0) }.reduce(0) { $0 + $1.minutes } }
    /// Library-based figure, raised to the tracked playback time if that is ever larger.
    var totalMinutes: Double { max(minutes(.all), trackedSeconds / 60) }

    /// Minutes per day, and whether it comes from tracked playback (last 30 days) or is estimated from the library.
    var averageDaily: (minutes: Double, tracked: Bool)? {
        if let t = trackedDailySeconds, t > 0 { return (t / 60, true) }
        guard let e = earliest else { return nil }
        let days = max(Date().timeIntervalSince(e) / 86_400, 7)
        let m = minutes(.all)
        return m > 0 ? (m / days, false) : nil
    }

    // MARK: Taste

    private var counted: [StatTitle] { titles.filter { $0.status != .planned && $0.minutes > 0 } }
    var hasGenreData: Bool { counted.contains { !($0.facts?.genres.isEmpty ?? true) } }

    func genreShares(_ kind: StatKind, top: Int = 6) -> [Share] {
        var w: [String: Double] = [:]
        for t in counted where kind.includes(t) {
            let g = t.facts?.genres ?? []
            guard !g.isEmpty else { continue }
            let part = t.minutes / Double(g.count)
            for n in g { w[n, default: 0] += part }
        }
        let total = w.values.reduce(0, +)
        guard total > 0 else { return [] }
        let sorted = w.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
        var out = sorted.prefix(top).map { Share(id: $0.key, percent: $0.value / total * 100) }
        let rest = sorted.dropFirst(top).reduce(0) { $0 + $1.value }
        if rest > 0 { out.append(Share(id: "Other", percent: rest / total * 100)) }
        return out
    }

    func era(_ kind: StatKind) -> Era? {
        let rows: [(year: Int, w: Double)] = counted.filter { kind.includes($0) }.compactMap { t in t.year.map { (year: $0, w: t.minutes) } }
        let total = rows.reduce(0) { $0 + $1.w }
        guard total > 0 else { return nil }
        let labels = ["Before 1990", "1990s", "2000s", "2010s", "2020s"]
        var w = Array(repeating: 0.0, count: labels.count)
        for r in rows { w[r.year < 1990 ? 0 : min((r.year - 1990) / 10 + 1, 4)] += r.w }
        var acc = 0.0
        var median: Int?
        for r in rows.sorted(by: { $0.year < $1.year }) {
            acc += r.w
            if acc >= total / 2 { median = r.year; break }
        }
        let now = Calendar.current.component(.year, from: .now)
        let recent = rows.filter { $0.year >= now - 5 }.reduce(0) { $0 + $1.w } / total
        return Era(buckets: labels.indices.map { Share(id: labels[$0], percent: w[$0] / total * 100) },
                   medianYear: median, recentShare: recent)
    }

    // MARK: Time of day

    var peakHour: Int? {
        guard let m = hourSeconds.max(), m > 0 else { return nil }
        return hourSeconds.firstIndex(of: m)
    }

    var dayParts: [DayPart] {
        let total = hourSeconds.reduce(0, +)
        guard total > 0 else { return [] }
        func pct(_ hours: [Int]) -> Double { hours.reduce(0) { $0 + hourSeconds[$1] } / total * 100 }
        return [
            DayPart(id: "Morning", symbol: "sunrise.fill", range: "5 AM – 12 PM", percent: pct(Array(5..<12))),
            DayPart(id: "Afternoon", symbol: "sun.max.fill", range: "12 – 5 PM", percent: pct(Array(12..<17))),
            DayPart(id: "Evening", symbol: "sunset.fill", range: "5 – 10 PM", percent: pct(Array(17..<22))),
            DayPart(id: "Night", symbol: "moon.stars.fill", range: "10 PM – 5 AM", percent: pct([22, 23] + Array(0..<5))),
        ]
    }
}

// MARK: - Model

/// Builds the statistics from everything the profile knows: watch history (including titles that dropped off
/// Continue Watching), the local library or Simkl's library, manual "mark as watched" actions, and the playback log.
@MainActor @Observable
final class ProfileStatsModel {
    private(set) var stats = ProfileStats()
    private(set) var loading = false
    private(set) var done = 0
    private(set) var total = 0
    private(set) var loaded = false

    func refresh(history: WatchHistory, library: LocalLibrary, simkl: SimklStore, log: WatchLog, includeSimkl: Bool = true) async {
        loading = true
        defer { loading = false; loaded = true; total = 0; done = 0 }
        let entries = history.allEntries
        let drafts = Self.drafts(history: entries, library: library.entries, simkl: simkl, includeSimkl: includeSimkl)
        var facts = await TitleFactsStore.shared.snapshot()
        stats = Self.makeStats(drafts: drafts, facts: facts, entries: entries, log: log)

        guard TMDBClient.shared.hasKey else { return }
        // Only titles that count need facts; plan-to-watch ones never feed the statistics.
        let pending = stats.titles.filter { $0.status != .planned && $0.facts == nil }.map(\.item)
        guard !pending.isEmpty else { return }
        total = pending.count
        var i = 0
        while i < pending.count, !Task.isCancelled {
            let chunk = Array(pending[i..<min(i + 4, pending.count)])
            await withTaskGroup(of: (String, TitleFacts?).self) { group in
                for item in chunk { group.addTask { (item.id, await TitleFactsStore.shared.facts(for: item)) } }
                for await (id, f) in group { if let f { facts[id] = f } }
            }
            i += chunk.count
            done = i
            stats = Self.makeStats(drafts: drafts, facts: facts, entries: entries, log: log)
        }
        await TitleFactsStore.shared.save()
    }

    // MARK: Merging the sources

    private struct Draft {
        var item: MetaPreview
        var ids: Set<String>
        var history: WatchHistory.Entry? = nil
        var local: LocalLibrary.Status? = nil
        var simkl: String? = nil                    // "watching" | "completed" | "plantowatch"
        var count: SimklEpisodeCount? = nil
        var added: Date? = nil
    }

    /// One draft per title, however many sources know it (and whichever id they use: IMDb, TMDB or the saved alias).
    private static func drafts(history: [WatchHistory.Entry], library: [LocalLibrary.Entry], simkl: SimklStore,
                               includeSimkl: Bool) -> [Draft] {
        var out: [Draft] = []
        func slot(_ item: MetaPreview, extra: [String] = []) -> Int {
            let ids = Set([item.id] + extra)
            let name = item.name.lowercased()
            if let i = out.firstIndex(where: { d in
                d.item.type == item.type && (!d.ids.isDisjoint(with: ids)
                    || (d.item.name.lowercased() == name && (d.item.year == nil || item.year == nil || d.item.year == item.year)))
            }) {
                out[i].ids.formUnion(ids)
                return i
            }
            out.append(Draft(item: item, ids: ids))
            return out.count - 1
        }
        for e in history {
            let i = slot(e.item)
            if let h = out[i].history, h.updated >= e.updated { continue }
            out[i].history = e
        }
        for e in library {
            let i = slot(e.item, extra: e.alias.map { [$0] } ?? [])
            if out[i].local != .watched { out[i].local = e.status }
            out[i].added = e.added
        }
        // A profile that uses its own library doesn't mix Simkl's lists into its statistics.
        for row in (includeSimkl ? simkl.library : []) where row.id.hasPrefix("simkl-") {
            let status = String(row.id.dropFirst("simkl-".count))
            for item in row.items {
                let i = slot(item)
                out[i].simkl = status
                out[i].count = simkl.episodeCounts[item.id]
            }
        }
        return out
    }

    // MARK: Counting

    /// Episodes covered by "watched through Season s, episode e" (the app's marker means everything up to there).
    private static func through(season s: Int, episode e: Int, facts f: TitleFacts?) -> Int {
        guard s >= 1, e >= 0 else { return 0 }
        var n = 0
        if let f, !f.seasons.isEmpty {
            let avg = max(f.seasons.values.reduce(0, +) / f.seasons.count, 1)
            for k in 1..<s { n += f.seasons[k] ?? avg }
            n += min(e, f.seasons[s] ?? e)            // clamps "episode 99" / "whole-show" markers to the season's size
        } else {
            n = (s - 1) * 10 + min(e, 30)             // no season data (no TMDB key): assume 10 per season
        }
        if let t = f?.totalEpisodes, t > 0 { n = min(n, t) }
        return max(n, 0)
    }

    private static func runtime(_ f: TitleFacts?, series: Bool) -> Double {
        if let r = f?.runtime, r > 0 { return Double(r) }
        if series { return (f?.genres.contains("Animation") ?? false) ? 24 : 42 }
        return 105
    }

    private static func build(_ drafts: [Draft], facts: [String: TitleFacts]) -> [StatTitle] {
        var out: [StatTitle] = []
        for d in drafts {
            let f = facts[d.item.id] ?? d.ids.compactMap { facts[$0] }.first
            let isSeries = d.item.type == "series"
            let h = d.history
            let simklWatched = d.count?.watched ?? 0

            var through = 0
            if isSeries, let h {
                if let w = h.watchedThrough { through = Self.through(season: w.season, episode: w.episode, facts: f) }
                else if let se = h.seasonEpisode { through = Self.through(season: se.season, episode: se.episode - 1, facts: f) }
            }
            through = max(through, simklWatched)

            var status: StatTitle.Status?
            if d.local == .watched || d.simkl == "completed" {
                status = .completed
            } else if isSeries {
                if let t = f?.totalEpisodes, t > 0, through >= t { status = .completed }
                else if through > 0 || (h?.position ?? 0) > 30 || d.simkl == "watching" { status = .watching }
            } else {
                if h?.isTitleWatched == true { status = .completed }
                else if (h?.position ?? 0) > 30 || d.simkl == "watching" { status = .watching }
            }
            if status == nil, d.local == .planToWatch || d.simkl == "plantowatch" { status = .planned }
            guard let status else { continue }

            var episodes = 0
            var minutes = 0.0
            let rt = runtime(f, series: isSeries)
            if status != .planned {
                if isSeries {
                    episodes = through
                    if status == .completed { episodes = max(episodes, f?.totalEpisodes ?? 0, 1) }
                    if let t = f?.totalEpisodes, t > 0 { episodes = min(episodes, t) }
                    minutes = Double(episodes) * rt
                    if let h, !h.isFinished, h.position > 30 { minutes += min(h.position / 60, rt * 1.5) }
                } else if status == .completed {
                    // A real playback gives the true runtime; otherwise TMDB's.
                    minutes = f?.runtime != nil ? rt : ((h?.duration ?? 0) > 1200 ? (h?.duration ?? 0) / 60 : rt)
                } else if let h {
                    minutes = min(h.position / 60, rt)
                }
            }
            out.append(StatTitle(id: d.item.id, item: d.item, status: status, episodes: episodes, minutes: minutes, facts: f))
        }
        return out
    }

    private static func makeStats(drafts: [Draft], facts: [String: TitleFacts], entries: [WatchHistory.Entry], log: WatchLog) -> ProfileStats {
        var s = ProfileStats()
        s.titles = build(drafts, facts: facts)
        s.trackedSeconds = log.totalSeconds
        s.trackedDailySeconds = log.averageDailySeconds()
        let tracked = log.hourTotals
        if tracked.reduce(0, +) >= 1800 {
            s.hourSeconds = tracked
            s.hoursSource = .tracked
        } else {
            // Not enough playback logged yet: use when each title was last watched, one vote per title.
            var est = Array(repeating: 0.0, count: 24)
            for e in entries { est[Calendar.current.component(.hour, from: e.updated)] += 1 }
            if est.reduce(0, +) > 0 { s.hourSeconds = est; s.hoursSource = .estimated }
        }
        s.earliest = drafts.compactMap { [$0.history?.updated, $0.added].compactMap { $0 }.min() }.min()
        return s
    }
}
