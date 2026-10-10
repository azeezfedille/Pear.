import Foundation

/// Aggregated ratings + the user's own MDBList lists. Needs an API key (Settings).
/// Requests are on demand only; ratings and list items are cached in memory.
actor MDBListClient {
    static let shared = MDBListClient()
    nonisolated var apiKey: String { UserDefaults.standard.string(forKey: "mdblist.key") ?? "" }
    nonisolated var hasKey: Bool { !apiKey.isEmpty }

    struct UserList: Decodable, Identifiable, Sendable { let id: Int; let name: String; let items: Int? }
    struct Rating: Identifiable, Sendable { let label: String; let text: String; var score: Double? = nil; var id: String { label } }

    private struct RatingsResponse: Decodable {
        struct R: Decodable { let source: String; let value: Double? }
        let ratings: [R]?
    }
    private struct ListItem: Decodable { let title: String; let imdbId: String?; var mediatype: String?; let releaseYear: Int? }
    private struct ListItems: Decodable {
        var items: [ListItem] = []
        enum K: String, CodingKey { case movies, shows }
        init(from d: Decoder) throws {
            // Newer API returns {movies:[], shows:[]}; older returns a bare array.
            if let c = try? d.container(keyedBy: K.self) {
                func load(_ k: K, _ kind: String) -> [ListItem] {
                    var a = (try? c.decode([ListItem].self, forKey: k)) ?? []
                    for i in a.indices where a[i].mediatype == nil { a[i].mediatype = kind }
                    return a
                }
                items = load(.movies, "movie") + load(.shows, "show")
            } else { items = try d.singleValueContainer().decode([ListItem].self) }
        }
    }

    private var ratingCache: [String: [Rating]] = [:]
    private var listCache: [Int: (Date, [MetaPreview])] = [:]

    private func get<T: Decodable>(_ path: String, _ q: [String: String] = [:]) async throws -> T {
        guard hasKey else { throw URLError(.userAuthenticationRequired) }
        guard var c = URLComponents(string: "https://api.mdblist.com\(path)") else { throw URLError(.badURL) }
        c.queryItems = [URLQueryItem(name: "apikey", value: apiKey)] + q.map { URLQueryItem(name: $0, value: $1) }
        guard let url = c.url else { throw URLError(.badURL) }
        let (d, r) = try await URLSession.shared.data(from: url)
        guard (r as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        let dec = JSONDecoder(); dec.keyDecodingStrategy = .convertFromSnakeCase
        return try dec.decode(T.self, from: d)
    }

    func ratings(imdb: String, type: String) async -> [Rating] {
        if let hit = ratingCache[imdb] { return hit }
        guard imdb.hasPrefix("tt") else { return [] }       // MDBList is keyed by IMDb id; anything else can't match
        guard let r: RatingsResponse = try? await get("/imdb/\(type == "series" ? "show" : "movie")/\(imdb)") else { return [] }
        let by = Dictionary(r.ratings?.compactMap { x in x.value.map { (x.source, $0) } } ?? [], uniquingKeysWith: { a, _ in a })
        var out: [Rating] = []
        if let v = by["imdb"] { out.append(Rating(label: "IMDb", text: String(format: "%.1f", v), score: v)) }
        if let v = by["tomatoes"] { out.append(Rating(label: "Rotten Tomatoes", text: "\(Int(v))%", score: v)) }
        if let v = by["tomatoesaudience"] ?? by["popcorn"] { out.append(Rating(label: "RT Audience", text: "\(Int(v))%", score: v)) }
        if let v = by["metacritic"] { out.append(Rating(label: "Metacritic", text: "\(Int(v))", score: v)) }
        if let v = by["letterboxd"] { out.append(Rating(label: "Letterboxd", text: String(format: "%.1f", v), score: v)) }
        if let v = by["trakt"] { out.append(Rating(label: "Trakt", text: "\(Int(v))%", score: v)) }
        ratingCache[imdb] = out
        return out
    }

    func userLists() async -> [UserList] { (try? await get("/lists/user")) ?? [] }

    func items(listID: Int) async -> [MetaPreview] {
        if let (t, v) = listCache[listID], Date().timeIntervalSince(t) < 1800 { return v }
        guard let r: ListItems = try? await get("/lists/\(listID)/items", ["limit": "30"]) else { return [] }
        // List items carry no artwork; MetaPreview falls back to image URLs keyed by IMDb id.
        let out = r.items.compactMap { i -> MetaPreview? in
            guard let id = i.imdbId else { return nil }
            return MetaPreview(id: id, type: i.mediatype == "show" ? "series" : "movie", name: i.title, poster: nil,
                               background: nil, logo: nil, description: nil, releaseInfo: i.releaseYear.map(String.init))
        }
        listCache[listID] = (.now, out)
        return out
    }
}
