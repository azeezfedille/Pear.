import Foundation

/// Finds a title logo (clear-logo PNG) for a movie or show. Sources, in order:
/// TMDB images (needs the TMDB key) → TheTVDB (needs the TVDB key) → the add-on's own logo → Metahub (no key).
/// Results are cached on disk, so each title is looked up once.
actor LogoResolver {
    static let shared = LogoResolver()
    private var cache: [String: URL] = [:]
    /// Titles with no logo anywhere, and the time (epoch seconds) until which that answer is trusted. Kept on disk:
    /// without it every launch re-asked TMDB, TVDB and two image hosts about each logo-less title it showed.
    private var misses: [String: Double] = [:]
    private static let missTTL: TimeInterval = 6 * 3600
    private let missKey = "logo.misses"
    private var persistPending = false
    /// Lookups already running, so a title asked for by several views at once is resolved (and fetched) only once.
    private var inflight: [String: Task<URL?, Never>] = [:]
    private let storeKey = "logo.cache"

    nonisolated var enabled: Bool { UserDefaults.standard.object(forKey: "ui.titleLogos") as? Bool ?? true }

    init() {
        if let d = UserDefaults.standard.dictionary(forKey: "logo.cache") as? [String: String] {
            cache = d.compactMapValues { URL(string: $0) }
        }
        if let m = UserDefaults.standard.dictionary(forKey: "logo.misses") as? [String: Double] {
            let now = Date().timeIntervalSince1970
            misses = m.filter { $0.value > now }
        }
    }

    /// Logos an enrichment source (the AIOMetadata add-on, on Home's theme rows) vouched for this launch. They win over
    /// TMDB / TVDB for that title, but are never saved: remove the add-on and the usual logos are back immediately.
    private var preferred: [String: URL] = [:]

    /// Remembers `url` as the logo to use for `id`, if it really loads. Returns whether it was accepted.
    func prefer(_ url: URL, for id: String) async -> Bool {
        guard enabled else { return false }
        if preferred[id] == url { return true }
        guard await exists(url) else { return false }
        preferred[id] = url
        return true
    }

    func logo(for item: MetaPreview) async -> URL? {
        guard enabled else { return nil }
        if let url = preferred[item.id] { return url }
        if let hit = cache[item.id] { return hit }
        if let until = misses[item.id] {
            if until > Date().timeIntervalSince1970 { return nil }
            misses[item.id] = nil
        }
        if let running = inflight[item.id] { return await running.value }
        let lookup = Task { await find(item) }
        inflight[item.id] = lookup
        let result = await lookup.value
        inflight[item.id] = nil
        guard let found = result else {
            // A lookup that failed because the phone was offline says nothing about the title: try again next time.
            if NetworkConditions.current.online {
                misses[item.id] = Date().timeIntervalSince1970 + Self.missTTL
                schedulePersist()
            }
            return nil
        }
        cache[item.id] = found
        schedulePersist()
        return found
    }

    private func find(_ item: MetaPreview) async -> URL? {
        if TMDBClient.shared.hasKey, let u = await TMDBClient.shared.logo(for: item.id, type: item.type) { return u }

        var imdb: String? = item.id.hasPrefix("tt") ? item.id : nil
        if imdb == nil, TMDBClient.shared.hasKey, item.id.hasPrefix("tmdb:"), let n = Int(item.id.dropFirst(5)) {
            imdb = await TMDBClient.shared.imdbID(tmdb: n, type: item.type)
        }
        if let imdb, TVDBClient.shared.hasKey, let u = await TVDBClient.shared.logo(imdb: imdb, type: item.type) { return u }
        if let l = item.logo.flatMap(URL.init(string:)), await exists(l) { return l }
        if let imdb, let u = URL(string: "https://images.metahub.space/logo/medium/\(imdb)/img"), await exists(u) { return u }
        return nil
    }

    private func exists(_ url: URL) async -> Bool {
        var r = URLRequest(url: url)
        r.httpMethod = "HEAD"; r.timeoutInterval = 6
        guard let (_, resp) = try? await URLSession.shared.data(for: r) else { return false }
        return (resp as? HTTPURLResponse)?.statusCode == 200
    }

    /// Writes at most once every few seconds, however many logos resolve in between (Home resolves dozens at once).
    private func schedulePersist() {
        guard !persistPending else { return }
        persistPending = true
        Task {
            try? await Task.sleep(for: .seconds(5))
            flush()
        }
    }

    /// Writes anything still waiting. Also called when the app leaves the foreground.
    func flush() {
        guard persistPending else { return }
        persistPending = false
        if cache.count > 600 { cache = Dictionary(uniqueKeysWithValues: Array(cache.prefix(400))) }
        UserDefaults.standard.set(cache.mapValues(\.absoluteString), forKey: storeKey)
        let now = Date().timeIntervalSince1970
        misses = misses.filter { $0.value > now }
        UserDefaults.standard.set(misses, forKey: missKey)
    }
}
