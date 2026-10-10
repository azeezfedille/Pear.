import Foundation

/// Native metadata + suggestions via TMDB (free API key, entered in Settings).
/// Results are mapped to MetaPreview with id "tmdb:<id>"; the IMDb id is resolved lazily
/// when a title is opened for playback, so lists cost one request, not one per item.
actor TMDBClient {
    static let shared = TMDBClient()
    private let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.urlCache = URLCache(memoryCapacity: 10 << 20, diskCapacity: 50 << 20)
        cfg.timeoutIntervalForRequest = 10
        return URLSession(configuration: cfg)
    }()
    /// IMDb id -> TMDB id, and show -> network icon. Both are permanent facts, so they are kept on disk: posters
    /// don't re-ask TMDB about the same titles on every launch (each ask is a radio wake-up).
    private var idCache: [String: Int] = (UserDefaults.standard.dictionary(forKey: "tmdb.idCache") as? [String: Int]) ?? [:]
    private var networkCache: [String: NetworkBadge] = {
        guard let raw = UserDefaults.standard.dictionary(forKey: "tmdb.networkCache") as? [String: [String]] else { return [:] }
        return raw.compactMapValues { v in
            v.first.map { NetworkBadge(name: $0, logo: v.count > 1 ? URL(string: v[1]) : nil) }
        }
    }()
    /// TMDB id -> IMDb id ("movie:603" -> "tt0133093"). Permanent facts, kept on disk, so opening a TMDB title never
    /// waits on this lookup twice. Lookups already in flight are shared.
    private var imdbCache: [String: String] = (UserDefaults.standard.dictionary(forKey: "tmdb.imdbIDs") as? [String: String]) ?? [:]
    private var imdbInFlight: [String: Task<String?, Never>] = [:]
    /// IMDb id -> TMDB id lookups already running. A detail page asks for the same id from half a dozen places at
    /// once (details, recommendations, trailers, logo, network...); they now share one `/find` request.
    private var idInFlight: [String: Task<Int?, Error>] = [:]
    /// IMDb ids TMDB answered "not found" for this launch, so they aren't asked again on every redraw.
    private var idMisses: Set<String> = []
    private var cachePersistPending = false
    private var networkMisses: Set<String> = []
    private var seasonCache: [String: [EpisodeInfo]] = [:]
    private var genreCache: [String: [Genre]] = [:]

    /// Hosted proxy (Supabase Edge Function) that holds the app's TMDB key server-side, so users don't need their own.
    /// Both values are safe to ship in the app: the anon key is a public identifier and the TMDB key never leaves the server.
    static let proxyBase = "https://ilmsadjrawdqxgaxvjfk.supabase.co/functions/v1/tmdb"
    static let anonKey = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImlsbXNhZGpyYXdkcXhnYXh2amZrIiwicm9sZSI6ImFub24iLCJpYXQiOjE3OTE1NjUxMTgsImV4cCI6MjEwNzE0MTExOH0.fSoWIHZbOrkA6G8CShILapwcteYQ_Gbo3GVVcEo5hYE"
    static var hasProxy: Bool { !proxyBase.isEmpty && !anonKey.isEmpty }

    /// The user's own key from Settings. When set, requests go straight to TMDB and the proxy is bypassed.
    nonisolated var apiKey: String { UserDefaults.standard.string(forKey: "tmdb.key") ?? "" }
    nonisolated var hasKey: Bool { !apiKey.isEmpty || Self.hasProxy }

    struct Item: Decodable { let id: Int; let title: String?; let name: String?; let overview: String?
        let posterPath: String?; let backdropPath: String?; let releaseDate: String?; let firstAirDate: String?
        let mediaType: String?; let voteAverage: Double?
        let genreIds: [Int]?
        /// Where the title comes from (anime vs. other animation). Movie lists only carry the language.
        let originalLanguage: String?; let originCountry: [String]? }
    private struct Page: Decodable { let results: [Item] }
    private struct Find: Decodable { let movieResults: [Item]; let tvResults: [Item] }
    private struct External: Decodable { let imdbId: String? }
    private struct SeasonResponse: Decodable { let episodes: [EpisodeInfo] }

    struct Genre: Decodable, Identifiable, Hashable, Sendable { let id: Int; let name: String }
    private struct GenreList: Decodable { let genres: [Genre] }
    private struct KeywordPage: Decodable {
        struct K: Decodable { let id: Int; let name: String }
        let results: [K]
    }
    /// "small town" -> TMDB keyword id. Kept on disk: ids never change, so each phrase is looked up once ever.
    private var keywordCache: [String: Int] = (UserDefaults.standard.dictionary(forKey: "tmdb.keywordIDs") as? [String: Int]) ?? [:]
    private struct ImageSet: Decodable {
        struct Logo: Decodable { let filePath: String; let iso6391: String?; let voteAverage: Double?; let width: Int? }
        /// Posters and backdrops arrive in the same response, so artwork rotation costs no extra request.
        struct Art: Decodable { let filePath: String; let iso6391: String?; let voteAverage: Double?; let width: Int?; let height: Int? }
        let logos: [Logo]?
        let posters: [Art]?
        let backdrops: [Art]?
    }

    private static let img = "https://image.tmdb.org/t/p/"

    struct Video: Decodable, Identifiable, Sendable, Hashable {
        let id: String; let key: String; let name: String; let site: String; let type: String
        let official: Bool?; let publishedAt: String?
        var thumbnail: URL? { URL(string: "https://i.ytimg.com/vi/\(key)/hqdefault.jpg") }
        var watchURL: URL? { URL(string: "https://www.youtube.com/watch?v=\(key)") }
    }
    private struct VideoPage: Decodable { let results: [Video] }
    private var videoCache: [String: [Video]] = [:]

    /// YouTube trailers, teasers and clips, trailers first, official and newest first within a kind.
    func videos(for id: String, type: String) async -> [Video] {
        guard hasKey else { return [] }
        if let hit = videoCache[id] { return hit }
        guard let tid = try? await tmdbID(for: id, type: type),
              let p: VideoPage = try? await get("/\(kind(type))/\(tid)/videos", ["include_video_language": "en,null"]) else { return [] }
        func rank(_ t: String) -> Int {
            switch t { case "Trailer": return 0; case "Teaser": return 1; case "Clip": return 2
            case "Featurette": return 3; case "Behind the Scenes": return 4; default: return 9 }
        }
        let out = p.results.filter { $0.site == "YouTube" && rank($0.type) < 9 }.sorted { a, b in
            if rank(a.type) != rank(b.type) { return rank(a.type) < rank(b.type) }
            if (a.official ?? false) != (b.official ?? false) { return a.official ?? false }
            return (a.publishedAt ?? "") > (b.publishedAt ?? "")
        }
        let limited = Array(out.prefix(10))
        videoCache[id] = limited
        return limited
    }

    /// Broadcaster / streamer icon shown on show posters.
    struct NetworkBadge: Sendable { let name: String; let logo: URL? }
    private struct TVNetworks: Decodable {
        struct Net: Decodable { let name: String; let logoPath: String? }
        let networks: [Net]?
    }

    struct SeasonInfo: Decodable, Identifiable, Sendable {
        let id: Int; let name: String?; let seasonNumber: Int
        let posterPath: String?; let episodeCount: Int?; let airDate: String?
        var posterURL: URL? { posterPath.flatMap { URL(string: TMDBClient.img + "w342" + $0) } }
        var title: String {
            if let n = name, !n.isEmpty { return n }
            return seasonNumber == 0 ? "Specials" : "Season \(seasonNumber)"
        }
    }

    struct EpisodeInfo: Decodable, Identifiable, Sendable {
        let id: Int; let name: String?; let overview: String?; let episodeNumber: Int
        let stillPath: String?; let voteAverage: Double?; let voteCount: Int?; let runtime: Int?; let airDate: String?
        var stillURL: URL? { stillPath.flatMap { URL(string: TMDBClient.img + "w300" + $0) } }
    }

    struct Details: Decodable, Sendable {
        let overview: String?; let tagline: String?; let runtime: Int?; let episodeRunTime: [Int]?
        let voteAverage: Double?; let genres: [Named]?
        let numberOfSeasons: Int?; let numberOfEpisodes: Int?
        let credits: Credits?; let seasons: [SeasonInfo]?
        let networks: [Named]?; let status: String?
        let productionCompanies: [Named]?; let productionCountries: [Named]?
        let spokenLanguages: [Language]?; let createdBy: [Named]?
        let firstAirDate: String?; let lastAirDate: String?; let releaseDate: String?
        let budget: Int?; let revenue: Int?

        struct Named: Decodable, Sendable { let name: String }
        struct Language: Decodable, Sendable { let englishName: String? }
        struct Credits: Decodable, Sendable { let cast: [Person]?; let crew: [Person]? }
        struct Person: Decodable, Sendable { let name: String; let job: String? }
        var minutes: Int? { runtime ?? episodeRunTime?.first }
    }

    private func get<T: Decodable>(_ path: String, _ query: [String: String] = [:]) async throws -> T {
        guard hasKey else { throw URLError(.userAuthenticationRequired) }
        let own = apiKey
        var req: URLRequest
        if !own.isEmpty {
            // Paths embed ids that add-ons supply; an odd one must fail this request, not crash the app.
            guard var c = URLComponents(string: "https://api.themoviedb.org/3\(path)") else { throw URLError(.badURL) }
            c.queryItems = [URLQueryItem(name: "api_key", value: own)] + query.map { URLQueryItem(name: $0, value: $1) }
            guard let url = c.url else { throw URLError(.badURL) }
            req = URLRequest(url: url)
        } else {
            guard var c = URLComponents(string: Self.proxyBase + path) else { throw URLError(.badURL) }
            if !query.isEmpty { c.queryItems = query.map { URLQueryItem(name: $0, value: $1) } }
            guard let url = c.url else { throw URLError(.badURL) }
            req = URLRequest(url: url)
            req.setValue("Bearer \(Self.anonKey)", forHTTPHeaderField: "Authorization")
            req.setValue(Self.anonKey, forHTTPHeaderField: "apikey")
        }
        let (d, r) = try await session.data(for: req)
        guard (r as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        let dec = JSONDecoder(); dec.keyDecodingStrategy = .convertFromSnakeCase
        return try dec.decode(T.self, from: d)
    }

    private func kind(_ type: String) -> String { type == "series" ? "tv" : "movie" }

    private func preview(_ i: Item, kind: String) -> MetaPreview {
        MetaPreview(id: "tmdb:\(i.id)", type: kind == "tv" ? "series" : "movie",
            name: i.title ?? i.name ?? "Untitled",
            poster: i.posterPath.map { Self.img + "w342" + $0 }, background: i.backdropPath.map { Self.img + "w780" + $0 },
            logo: nil, description: i.overview, releaseInfo: (i.releaseDate ?? i.firstAirDate).map { String($0.prefix(4)) },
            rating: (i.voteAverage ?? 0) > 0 ? i.voteAverage : nil,
            genreIDs: i.genreIds, language: i.originalLanguage, countries: i.originCountry)
    }

    func trending(_ kind: String, page: Int = 1) async throws -> [MetaPreview] {
        let p: Page = try await get("/trending/\(kind)/week", ["page": String(page)])
        return p.results.map { preview($0, kind: kind) }
    }

    /// Movies + shows matching a free-text query.
    func search(_ query: String) async -> [MetaPreview] {
        guard hasKey, let p: Page = try? await get("/search/multi", ["query": query, "include_adult": "false"]) else { return [] }
        return p.results.compactMap { i in
            guard let t = i.mediaType, t == "movie" || t == "tv" else { return nil }
            return preview(i, kind: t)
        }
    }

    /// Network of a show (cached; shows only). One lookup per title, resolved lazily from visible posters.
    func network(for id: String, type: String) async -> NetworkBadge? {
        guard type == "series" else { return nil }
        if let hit = networkCache[id] { return hit }
        if networkMisses.contains(id) { return nil }
        guard let tid = try? await tmdbID(for: id, type: type),
              let t: TVNetworks = try? await get("/tv/\(tid)") else { return nil }
        guard let n = t.networks?.first(where: { $0.logoPath != nil }) ?? t.networks?.first else {
            networkMisses.insert(id); return nil
        }
        let badge = NetworkBadge(name: n.name, logo: n.logoPath.flatMap { URL(string: Self.img + "w92" + $0) })
        networkCache[id] = badge
        scheduleCachePersist()
        return badge
    }

    /// "More like this": TMDB recommendations, falling back to /similar when there are none.
    func recommendations(for id: String, type: String) async throws -> [MetaPreview] {
        let k = kind(type)
        let tid = try await tmdbID(for: id, type: type)
        var p: Page = try await get("/\(k)/\(tid)/recommendations")
        if p.results.isEmpty { p = try await get("/\(k)/\(tid)/similar") }
        return p.results.map { preview($0, kind: k) }
    }

    func details(for id: String, type: String) async throws -> Details {
        try await get("/\(kind(type))/\(try await tmdbID(for: id, type: type))", ["append_to_response": "credits"])
    }

    /// Details without credits (much smaller response). Used by the profile statistics.
    func basicDetails(for id: String, type: String) async -> Details? {
        guard hasKey, let tid = try? await tmdbID(for: id, type: type) else { return nil }
        let d: Details? = try? await get("/\(kind(type))/\(tid)")
        return d
    }

    private struct TraitsResponse: Decodable {
        struct Country: Decodable { let iso31661: String? }
        let genres: [Genre]?
        let originalLanguage: String?
        let originCountry: [String]?
        let productionCountries: [Country]?
    }

    /// Genres and origin of one title: a single small request. The content filter uses it for titles that arrive
    /// without genres (some add-ons) or as plain "Animation" (anime or a cartoon?). Results are cached by the caller.
    func traits(for id: String, type: String) async -> TitleTraits? {
        guard hasKey, let tid = try? await tmdbID(for: id, type: type),
              let r: TraitsResponse = try? await get("/\(kind(type))/\(tid)") else { return nil }
        let origin = r.originCountry ?? []
        let countries = origin.isEmpty ? (r.productionCountries ?? []).compactMap(\.iso31661) : origin
        return TitleTraits(genres: Set((r.genres ?? []).map(\.id)), language: r.originalLanguage, countries: countries)
    }

    /// Cached details lookup for quick actions (long-press menus). nil when there is no key or the title fails to resolve.
    private var detailsCache: [String: Details] = [:]
    func cachedDetails(for id: String, type: String) async -> Details? {
        guard hasKey else { return nil }
        if let hit = detailsCache[id] { return hit }
        guard let d = try? await details(for: id, type: type) else { return nil }
        detailsCache[id] = d
        return d
    }

    /// Episodes of one season with still image, overview and TMDB rating.
    func episodes(for id: String, type: String, season: Int) async -> [EpisodeInfo] {
        let key = "\(id):\(season)"
        if let hit = seasonCache[key] { return hit }
        guard let tid = try? await tmdbID(for: id, type: type),
              let s: SeasonResponse = try? await get("/tv/\(tid)/season/\(season)") else { return [] }
        seasonCache[key] = s.episodes
        return s.episodes
    }

    /// Numeric TMDB id for any title id we hold ("tt…" or "tmdb:…").
    func tmdbIdentifier(for id: String, type: String) async -> Int? {
        guard hasKey else { return id.hasPrefix("tmdb:") ? Int(id.dropFirst(5)) : nil }
        return try? await tmdbID(for: id, type: type)
    }

    private static func raw(_ a: ImageSet.Art) -> ArtworkPool.Raw {
        ArtworkPool.Raw(path: a.filePath, language: a.iso6391, width: a.width ?? 0, height: a.height ?? 0, votes: a.voteAverage ?? 0)
    }

    /// Best title logo (transparent PNG): English or language-less, highest voted. SVGs are skipped (ImageIO can't draw them).
    func logo(for id: String, type: String) async -> URL? {
        guard hasKey, let tid = try? await tmdbID(for: id, type: type),
              let set: ImageSet = try? await get("/\(kind(type))/\(tid)/images", ["include_image_language": "en,null"]) else { return nil }
        ArtworkPool.shared.ingest(id: id, posters: (set.posters ?? []).map(Self.raw), backdrops: (set.backdrops ?? []).map(Self.raw))
        let usable = (set.logos ?? []).filter { !$0.filePath.lowercased().hasSuffix(".svg") && ($0.iso6391 == "en" || $0.iso6391 == nil) }
        let best = usable.max { a, b in
            let la = a.iso6391 == "en" ? 1 : 0, lb = b.iso6391 == "en" ? 1 : 0
            if la != lb { return la < lb }
            if (a.voteAverage ?? 0) != (b.voteAverage ?? 0) { return (a.voteAverage ?? 0) < (b.voteAverage ?? 0) }
            return (a.width ?? 0) < (b.width ?? 0)
        }
        return best.flatMap { URL(string: Self.img + "w500" + $0.filePath) }
    }

    /// Genre list for Explore ("movie" | "tv"), cached.
    func genres(_ kind: String) async -> [Genre] {
        if let hit = genreCache[kind] { return hit }
        guard let g: GenreList = try? await get("/genre/\(kind)/list") else { return [] }
        genreCache[kind] = g.genres
        return g.genres
    }

    /// Filtered browsing for Explore.
    func discover(kind: String, genre: Int?, year: Int?, sort: DiscoverSort, page: Int,
                  rules: ContentRules = .none) async throws -> [MetaPreview] {
        var q = ["page": String(page), "include_adult": "false"]
        if let excluded = rules.excludedGenreQuery { q["without_genres"] = excluded }
        let dateField = kind == "tv" ? "first_air_date" : "primary_release_date"
        switch sort {
        case .popular: q["sort_by"] = "popularity.desc"
        case .topRated:
            q["sort_by"] = "vote_average.desc"
            q["vote_count.gte"] = kind == "tv" ? "200" : "500"     // keeps one-vote wonders out of "top rated"
        case .newest:
            q["sort_by"] = dateField + ".desc"
            q[dateField + ".lte"] = Self.today                      // nothing unreleased
            q["vote_count.gte"] = "5"
        }
        if let genre { q["with_genres"] = String(genre) }
        if let year { q[kind == "tv" ? "first_air_date_year" : "primary_release_year"] = String(year) }
        let p: Page = try await get("/discover/\(kind)", q)
        return p.results.map { preview($0, kind: kind) }
    }

    private static let isoDay: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"
        return f
    }()
    private static var today: String { isoDay.string(from: .now) }

    // MARK: Themed collections (Home)

    private func keywordID(_ phrase: String) async -> Int? {
        let q = phrase.lowercased()
        if let hit = keywordCache[q] { return hit }
        guard let p: KeywordPage = try? await get("/search/keyword", ["query": q]),
              let k = p.results.first(where: { $0.name.lowercased() == q }) ?? p.results.first else { return nil }
        keywordCache[q] = k.id
        scheduleCachePersist()
        return k.id
    }

    /// Shows and movies tagged with any of the keywords, most popular first, shows and movies interleaved.
    /// Each result carries its genre names for the card caption (discover only returns genre ids).
    /// `language` (ISO 639-1 original language) narrows the match; with no keywords at all it is the whole theme.
    func themed(keywords: [String], language: String? = nil, limit: Int = 8, rules: ContentRules = .none) async -> [ThemedTitle] {
        if let language, rules.hidesLanguage(language) { return [] }
        guard hasKey else { return [] }
        var ids: [Int] = []
        for q in keywords { if let id = await keywordID(q) { ids.append(id) } }
        // Keywords that TMDB doesn't know would otherwise widen the theme to "everything": skip it instead.
        guard !ids.isEmpty || (keywords.isEmpty && language != nil) else { return [] }
        let joined = ids.map(String.init).joined(separator: "|")      // "|" = OR
        async let tv = themedPage(kind: "tv", keywords: joined, language: language, rules: rules)
        async let mv = themedPage(kind: "movie", keywords: joined, language: language, rules: rules)
        let (t, m) = await (tv, mv)
        var out: [ThemedTitle] = []
        var seen = Set<String>()
        for i in 0..<max(t.count, m.count) {
            for list in [t, m] where i < list.count {
                if seen.insert(list[i].item.id).inserted { out.append(list[i]) }
            }
        }
        return Array(out.prefix(limit))
    }

    private func themedPage(kind: String, keywords: String, language: String?, rules: ContentRules) async -> [ThemedTitle] {
        var q: [String: String] = [
            "sort_by": "popularity.desc", "include_adult": "false",
            "vote_count.gte": kind == "tv" ? "100" : "200",
        ]
        if !keywords.isEmpty { q["with_keywords"] = keywords }
        if let language { q["with_original_language"] = language }
        if let excluded = rules.excludedGenreQuery { q["without_genres"] = excluded }
        guard let p: Page = try? await get("/discover/\(kind)", q) else { return [] }
        let names = Dictionary(await genres(kind).map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
        let titles = p.results.filter { $0.posterPath != nil }.map { i in
            ThemedTitle(item: preview(i, kind: kind), genres: Array((i.genreIds ?? []).compactMap { names[$0] }.prefix(2)))
        }
        // TMDB items always carry their genres and language, so this never needs a lookup.
        return titles.filter { rules.outcome(for: $0.item) != .hide }
    }

    func imdbID(tmdb id: Int, type: String) async -> String? {
        let key = "\(kind(type)):\(id)"
        if let hit = imdbCache[key] { return hit }
        if let running = imdbInFlight[key] { return await running.value }
        let task = Task<String?, Never> {
            let e: External? = try? await self.get("/\(self.kind(type))/\(id)/external_ids")
            guard let imdb = e?.imdbId, !imdb.isEmpty else { return nil } // misses are not cached
            return imdb
        }
        imdbInFlight[key] = task
        let result = await task.value
        imdbInFlight[key] = nil
        if let result { imdbCache[key] = result; scheduleCachePersist() }
        return result
    }

    private func tmdbID(for id: String, type: String) async throws -> Int {
        if id.hasPrefix("tmdb:"), let n = Int(id.dropFirst(5)) { return n }
        if let hit = idCache[id] { return hit }
        // `/find` only understands IMDb ids. Add-on specific ones (kitsu:, mal:, yt:...) can never resolve, so they
        // don't cost a request.
        guard id.hasPrefix("tt") else { throw URLError(.resourceUnavailable) }
        let kindName = kind(type)
        let key = kindName + ":" + id
        if idMisses.contains(key) { throw URLError(.resourceUnavailable) }

        let task: Task<Int?, Error>
        if let running = idInFlight[key] {
            task = running
        } else {
            task = Task<Int?, Error> {
                let f: Find = try await self.get("/find/\(id)", ["external_source": "imdb_id"])
                return (kindName == "tv" ? f.tvResults : f.movieResults).first?.id
            }
            idInFlight[key] = task
        }
        do {
            let found = try await task.value
            idInFlight[key] = nil
            guard let found else { idMisses.insert(key); throw URLError(.resourceUnavailable) }
            idCache[id] = found
            scheduleCachePersist()
            return found
        } catch {
            idInFlight[key] = nil          // a network failure is not remembered: the next ask tries again
            throw error
        }
    }

    /// Writes the id and network caches at most once every few seconds, however many titles resolve in between.
    private func scheduleCachePersist() {
        guard !cachePersistPending else { return }
        cachePersistPending = true
        Task {
            try? await Task.sleep(for: .seconds(8))
            flushPending()
        }
    }

    /// Writes anything still waiting. Also called when the app leaves the foreground, so a quick exit loses nothing.
    func flushPending() {
        guard cachePersistPending else { return }
        flushCaches()
    }

    private func flushCaches() {
        cachePersistPending = false
        if idCache.count > 3000 { idCache = Dictionary(uniqueKeysWithValues: Array(idCache.prefix(2000))) }
        if networkCache.count > 1500 { networkCache = Dictionary(uniqueKeysWithValues: Array(networkCache.prefix(1000))) }
        if imdbCache.count > 3000 { imdbCache = Dictionary(uniqueKeysWithValues: Array(imdbCache.prefix(2000))) }
        UserDefaults.standard.set(idCache, forKey: "tmdb.idCache")
        UserDefaults.standard.set(imdbCache, forKey: "tmdb.imdbIDs")
        UserDefaults.standard.set(keywordCache, forKey: "tmdb.keywordIDs")
        UserDefaults.standard.set(networkCache.mapValues { [$0.name, $0.logo?.absoluteString ?? ""] }, forKey: "tmdb.networkCache")
    }
}

enum DiscoverSort: String, CaseIterable, Identifiable, Sendable {
    case popular = "Popular", topRated = "Top rated", newest = "Newest"
    var id: String { rawValue }
}

/// A title in a themed Home row, with the genre names shown under its logo.
struct ThemedTitle: Identifiable, Sendable {
    let item: MetaPreview
    let genres: [String]
    var id: String { item.id }
}
