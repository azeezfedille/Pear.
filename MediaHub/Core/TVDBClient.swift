import Foundation

/// TheTVDB v4: episode list with thumbnails + clear-logo title art. Needs the user's API key
/// (and PIN if it's a subscriber key). Token lives in the Keychain, refreshed monthly or on 401.
actor TVDBClient {
    static let shared = TVDBClient()
    private let base = "https://api4.thetvdb.com/v4"
    nonisolated var apiKey: String { UserDefaults.standard.string(forKey: "tvdb.key") ?? "" }
    nonisolated var pin: String { UserDefaults.standard.string(forKey: "tvdb.pin") ?? "" }
    nonisolated var hasKey: Bool { !apiKey.isEmpty }

    struct Episode: Decodable, Identifiable, Sendable {
        let id: Int; let name: String?; let overview: String?; let image: String?
        let number: Int?; let seasonNumber: Int?; let runtime: Int?
        /// "2024-05-01". Lets the episode list tell what hasn't aired yet when TVDB stands in for TMDB.
        let aired: String?
        var imageURL: URL? { image.flatMap { TVDBClient.absolute($0) } }
    }
    private struct Envelope<T: Decodable>: Decodable { let data: T }
    private struct Login: Decodable { let token: String }
    private struct EpPage: Decodable { let episodes: [Episode] }
    private struct Remote: Decodable { let series: Ref?; let movie: Ref? }
    private struct Art: Decodable { let image: String; let type: Int; let score: Int?; let language: String? }
    private struct Arts: Decodable { let artworks: [Art]? }
    /// TVDB sometimes sends ids as numbers, sometimes as strings.
    private struct Ref: Decodable {
        let id: Int
        enum K: String, CodingKey { case id }
        init(from d: Decoder) throws {
            let c = try d.container(keyedBy: K.self)
            if let i = try? c.decode(Int.self, forKey: .id) { id = i }
            else if let s = try? c.decode(String.self, forKey: .id), let i = Int(s) { id = i }
            else { throw DecodingError.dataCorruptedError(forKey: .id, in: c, debugDescription: "bad id") }
        }
    }

    private let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.urlCache = URLCache(memoryCapacity: 10 << 20, diskCapacity: 50 << 20)
        return URLSession(configuration: cfg)
    }()
    private var token: String? = Keychain.get("tvdb.token")
    private var tokenFor: String?
    private var tokenDate = UserDefaults.standard.object(forKey: "tvdb.tokenDate") as? Date
    private var idCache: [String: (series: Int?, movie: Int?)] = [:]
    private var episodeCache: [String: [Episode]] = [:]

    nonisolated static func absolute(_ s: String) -> URL? {
        URL(string: s.hasPrefix("http") ? s : "https://artworks.thetvdb.com" + s)
    }

    private func authToken() async throws -> String {
        let who = apiKey + "|" + pin
        if let t = token, tokenFor == nil || tokenFor == who, let d = tokenDate, Date().timeIntervalSince(d) < 25 * 86400 {
            tokenFor = who; return t
        }
        var r = URLRequest(url: URL(string: base + "/login")!)
        r.httpMethod = "POST"
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body = ["apikey": apiKey]
        if !pin.isEmpty { body["pin"] = pin }
        r.httpBody = try JSONEncoder().encode(body)
        let (d, resp) = try await session.data(for: r)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.userAuthenticationRequired) }
        let t = try JSONDecoder().decode(Envelope<Login>.self, from: d).data.token
        token = t; tokenFor = who; tokenDate = .now
        Keychain.set(t, "tvdb.token")
        UserDefaults.standard.set(tokenDate, forKey: "tvdb.tokenDate")
        return t
    }

    private func get<T: Decodable>(_ path: String, retry: Bool = true) async throws -> T {
        guard hasKey else { throw URLError(.userAuthenticationRequired) }
        var r = URLRequest(url: URL(string: base + path)!)
        r.setValue("Bearer \(try await authToken())", forHTTPHeaderField: "Authorization")
        let (d, resp) = try await session.data(for: r)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code == 401, retry { token = nil; return try await get(path, retry: false) }
        guard code == 200 else { throw URLError(.badServerResponse) }
        return try JSONDecoder().decode(Envelope<T>.self, from: d).data
    }

    private func ids(_ imdb: String) async -> (series: Int?, movie: Int?) {
        if let hit = idCache[imdb] { return hit }
        let r: [Remote]? = try? await get("/search/remoteid/\(imdb)")
        let out = (series: r?.compactMap { $0.series }.first?.id, movie: r?.compactMap { $0.movie }.first?.id)
        if out.series != nil || out.movie != nil { idCache[imdb] = out }
        return out
    }

    func episodes(imdb: String, season: Int) async -> [Episode] {
        let key = "\(imdb):\(season)"
        if let hit = episodeCache[key] { return hit }
        guard let sid = await ids(imdb).series,
              let p: EpPage = try? await get("/series/\(sid)/episodes/default?season=\(season)&page=0") else { return [] }
        let out = p.episodes.filter { $0.seasonNumber == season }.sorted { ($0.number ?? 0) < ($1.number ?? 0) }
        episodeCache[key] = out
        return out
    }

    /// Title logo (PNG with transparency) for the detail header. Artwork type ids: series 23, movie 25.
    func logo(imdb: String, type: String) async -> URL? {
        let i = await ids(imdb)
        let arts: Arts?
        if type == "series" {
            guard let s = i.series else { return nil }
            arts = try? await get("/series/\(s)/artworks?type=23")
        } else {
            guard let m = i.movie else { return nil }
            arts = try? await get("/movies/\(m)/extended")
        }
        let want = type == "series" ? 23 : 25
        let best = (arts?.artworks ?? [])
            .filter { $0.type == want && ($0.language == nil || $0.language == "eng") }
            .max { ($0.score ?? 0) < ($1.score ?? 0) }
        return best.flatMap { TVDBClient.absolute($0.image) }
    }
}
