import Foundation

/// One skippable stretch of an episode or movie, in seconds.
struct SkipSegment: Equatable, Sendable, Identifiable {
    enum Kind: String, Sendable { case intro, recap, credits, preview }
    let kind: Kind
    let start: Double
    let end: Double?          // nil = runs to the end of the media
    var id: String { "\(kind.rawValue)-\(Int(start))" }
    var label: String {
        switch kind {
        case .intro: return "Skip Intro"
        case .recap: return "Skip Recap"
        case .credits: return "Skip Credits"
        case .preview: return "Skip Preview"
        }
    }
}

/// Intro / recap / credits / preview timestamps from TheIntroDB (community-verified, free, no API key for reads).
/// GET https://api.theintrodb.org/v3/media?tmdb_id=…&season=…&episode=…  →  { intro:[{start_ms,end_ms}], recap:[…], credits:[…], preview:[…] }
/// `null` start = beginning of the media, `null` end = end of the media.
actor IntroClient {
    static let shared = IntroClient()
    private var cache: [String: [SkipSegment]] = [:]

    nonisolated var enabled: Bool { UserDefaults.standard.object(forKey: "skip.enabled") as? Bool ?? true }

    private struct Seg: Decodable { let startMs: Double?; let endMs: Double? }
    private struct Media: Decodable { let intro: [Seg]?; let recap: [Seg]?; let credits: [Seg]?; let preview: [Seg]? }

    func segments(item: MetaPreview, imdb: String, season: Int?, episode: Int?) async -> [SkipSegment] {
        guard enabled else { return [] }
        let key = "\(item.id):\(season ?? 0):\(episode ?? 0)"
        if let hit = cache[key] { return hit }

        // TMDB id first (most accurate), then IMDb: a title missing under one id is often present under the other.
        var ids: [URLQueryItem] = []
        if let tmdb = await TMDBClient.shared.tmdbIdentifier(for: item.id, type: item.type) {
            ids.append(URLQueryItem(name: "tmdb_id", value: String(tmdb)))
        }
        if imdb.hasPrefix("tt") { ids.append(URLQueryItem(name: "imdb_id", value: imdb)) }
        guard !ids.isEmpty else { return [] }
        var episodeQ: [URLQueryItem] = []
        if let s = season, let e = episode {
            episodeQ = [URLQueryItem(name: "season", value: String(s)), URLQueryItem(name: "episode", value: String(e))]
        }

        var answered = false
        for id in ids {
            switch await fetch([id] + episodeQ) {
            case .found(let segs):
                cache[key] = segs
                return segs
            case .none: answered = true
            case .failed: break
            }
        }
        if answered { cache[key] = [] }        // the service answered: really nothing there. A network failure is not cached.
        return []
    }

    private enum Fetch { case found([SkipSegment]), none, failed }

    /// One request, retried once after a short pause if the network or the server hiccups.
    private func fetch(_ q: [URLQueryItem]) async -> Fetch {
        for attempt in 0..<2 {
            if attempt > 0 { try? await Task.sleep(for: .seconds(2)) }
            var c = URLComponents(string: "https://api.theintrodb.org/v3/media")!
            c.queryItems = q
            var r = URLRequest(url: c.url!)
            r.timeoutInterval = 10
            r.setValue("application/json", forHTTPHeaderField: "Accept")
            guard let (d, resp) = try? await URLSession.shared.data(for: r) else { continue }
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if status == 404 { return .none }
            guard status == 200 else { continue }
            let segs = Self.parse(d)
            return segs.isEmpty ? .none : .found(segs)
        }
        return .failed
    }

    private static func parse(_ d: Data) -> [SkipSegment] {
        let dec = JSONDecoder(); dec.keyDecodingStrategy = .convertFromSnakeCase
        guard let m = try? dec.decode(Media.self, from: d) else { return [] }
        var out: [SkipSegment] = []
        func add(_ kind: SkipSegment.Kind, _ segs: [Seg]?) {
            for s in segs ?? [] {
                let start = max((s.startMs ?? 0) / 1000, 0)
                let end = s.endMs.map { $0 / 1000 }
                if let end, end - start < 3 { continue }
                out.append(SkipSegment(kind: kind, start: start, end: end))
            }
        }
        add(.recap, m.recap); add(.intro, m.intro); add(.credits, m.credits); add(.preview, m.preview)
        return out.sorted { $0.start < $1.start }
    }
}
