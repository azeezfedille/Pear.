import Foundation

// MARK: - Sign-in

enum JellyfinAPI {
    struct Session: Sendable { let token: String; let userID: String }
    struct PublicInfo: Sendable { let name: String }
    struct QuickConnect: Sendable { let code: String; let secret: String }

    private struct PublicDTO: Decodable { let serverName: String? }
    private struct AuthDTO: Decodable {
        let accessToken: String
        let user: User
        struct User: Decodable { let id: String }
    }
    private struct QuickDTO: Decodable { let code: String; let secret: String }
    private struct QuickStateDTO: Decodable { let authenticated: Bool? }

    /// Jellyfin's client identification header. The token is added once there is one.
    static func authHeader(token: String?) -> String {
        var s = "MediaBrowser Client=\"Pear\", Device=\"iOS\", DeviceId=\"\(ServerIdentity.deviceID)\", Version=\"\(ServerIdentity.version)\""
        if let token { s += ", Token=\"\(token)\"" }
        return s
    }

    /// What was typed, as addresses to try. A bare `192.168.1.5:8096` is tried as http first, a bare domain as https first.
    /// A pasted web-UI link (`…/web/index.html#!/home`) is cut back to the server root.
    static func candidates(_ raw: String) -> [URL] {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let hash = s.firstIndex(of: "#") { s = String(s[..<hash]) }
        for tail in ["/web/index.html", "/web/", "/web"] where s.hasSuffix(tail) { s.removeLast(tail.count); break }
        while s.hasSuffix("/") { s.removeLast() }
        guard !s.isEmpty else { return [] }
        if s.contains("://") { return URL(string: s).map { [$0] } ?? [] }
        let hostPart = s.split(separator: "/").first.map(String.init) ?? s
        let bare = hostPart.split(separator: ":").first.map(String.init) ?? hostPart
        let lan = hostPart.contains(":") || bare.hasSuffix(".local")
            || bare.range(of: #"^\d{1,3}(\.\d{1,3}){3}$"#, options: .regularExpression) != nil
        return (lan ? ["http", "https"] : ["https", "http"]).compactMap { URL(string: "\($0)://\(s)") }
    }

    /// Finds the server: the first address that answers `/System/Info/Public` like a Jellyfin server.
    static func probe(_ raw: String) async throws -> (base: URL, info: PublicInfo) {
        let urls = candidates(raw)
        guard !urls.isEmpty else { throw ServerError.badAddress }
        for base in urls {
            guard let url = ServerHTTP.url(base, "System/Info/Public"),
                  let data = try? await ServerHTTP.data(URLRequest(url: url), timeout: 6),
                  let dto = try? JSONDecoder.pascalCase.decode(PublicDTO.self, from: data),
                  let name = dto.serverName else { continue }
            return (base, PublicInfo(name: name))
        }
        throw ServerError.notAServer
    }

    private static func post(_ base: URL, _ path: String, body: [String: Any]?) async throws -> Data {
        guard let url = ServerHTTP.url(base, path) else { throw ServerError.badAddress }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue(authHeader(token: nil), forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body ?? [:])
        return try await ServerHTTP.data(req, timeout: 10)
    }

    private static func session(from data: Data) throws -> Session {
        let dto = try JSONDecoder.pascalCase.decode(AuthDTO.self, from: data)
        return Session(token: dto.accessToken, userID: dto.user.id)
    }

    static func signIn(base: URL, username: String, password: String) async throws -> Session {
        let d = try await post(base, "Users/AuthenticateByName", body: ["Username": username, "Pw": password])
        return try session(from: d)
    }

    // Quick Connect: the server shows a code, the user approves it from a device that is already signed in
    // (Jellyfin web / app -> user menu -> Quick Connect).

    static func quickConnectStart(base: URL) async throws -> QuickConnect {
        do {
            let d = try await post(base, "QuickConnect/Initiate", body: nil)
            let dto = try JSONDecoder.pascalCase.decode(QuickDTO.self, from: d)
            return QuickConnect(code: dto.code, secret: dto.secret)
        } catch ServerError.unauthorized {
            throw ServerError.quickConnectOff       // a server with it switched off answers 401
        }
    }

    static func quickConnectCheck(base: URL, secret: String) async throws -> Bool {
        guard let url = ServerHTTP.url(base, "QuickConnect/Connect", [URLQueryItem(name: "secret", value: secret)]) else {
            throw ServerError.badAddress
        }
        var req = URLRequest(url: url)
        req.setValue(authHeader(token: nil), forHTTPHeaderField: "Authorization")
        let d = try await ServerHTTP.data(req, timeout: 10)
        return (try? JSONDecoder.pascalCase.decode(QuickStateDTO.self, from: d))?.authenticated ?? false
    }

    static func quickConnectFinish(base: URL, secret: String) async throws -> Session {
        let d = try await post(base, "Users/AuthenticateWithQuickConnect", body: ["Secret": secret])
        return try session(from: d)
    }
}

// MARK: - Library

/// One Jellyfin user's library. Matching is by IMDb id (`AnyProviderIdEquals`), so a title is found however the
/// server files it; sources are the original files, played as they are (`static=true`), never transcoded.
struct JellyfinBackend: MediaServerBackend {
    let base: URL
    let token: String
    let userID: String

    init?(account: MediaServerAccount, token: String) {
        guard let base = URL(string: account.baseURL), let user = account.userID else { return nil }
        self.base = base
        self.token = token
        self.userID = user
    }

    private struct ItemsDTO: Decodable { let items: [Lossy<ItemDTO>] }
    private struct ItemDTO: Decodable {
        let id: String
        let name: String?
        let overview: String?
        let productionYear: Int?
        let genres: [String]?
        let providerIds: [String: String]?
        let imageTags: [String: String]?
        let indexNumber: Int?
        let indexNumberEnd: Int?
        let parentIndexNumber: Int?
        let mediaSources: [SourceDTO]?
    }
    private struct SourceDTO: Decodable {
        let id: String?
        let name: String?
        let container: String?
        let path: String?
        let size: Int64?
        let bitrate: Int?
        let mediaStreams: [StreamDTO]?
    }
    private struct StreamDTO: Decodable {
        let type: String?
        let codec: String?
        let width: Int?
        let height: Int?
        let channels: Int?
    }

    private func get(_ path: String, _ query: [URLQueryItem]) async throws -> ItemsDTO {
        guard let url = ServerHTTP.url(base, path, query) else { throw ServerError.badAddress }
        var req = URLRequest(url: url)
        req.setValue(JellyfinAPI.authHeader(token: token), forHTTPHeaderField: "Authorization")
        return try JSONDecoder.pascalCase.decode(ItemsDTO.self, from: try await ServerHTTP.data(req))
    }

    private func q(_ name: String, _ value: String) -> URLQueryItem { URLQueryItem(name: name, value: value) }

    // MARK: Sources

    func streams(type: String, id: String) async -> [StreamItem] {
        let parts = id.split(separator: ":").map(String.init)
        guard let imdb = parts.first, imdb.hasPrefix("tt") else { return [] }
        do {
            if type == "series" {
                guard parts.count == 3, let season = Int(parts[1]), let number = Int(parts[2]),
                      let show = try await find(imdb: imdb, kind: "Series").first else { return [] }
                let eps = try await get("Shows/\(show.id)/Episodes", [
                    q("userId", userID), q("season", String(season)), q("fields", "MediaSources")])
                // IndexNumberEnd covers a file that holds two episodes.
                let hit = eps.items.compactMap(\.value).first {
                    ($0.indexNumber ?? -1) <= number && number <= ($0.indexNumberEnd ?? $0.indexNumber ?? -2)
                }
                return hit.map(sources) ?? []
            }
            return try await find(imdb: imdb, kind: "Movie").flatMap(sources)
        } catch { return [] }
    }

    /// Library items carrying this IMDb id. An old server that ignores the filter would answer with everything, so the
    /// id is checked on what comes back.
    private func find(imdb: String, kind: String) async throws -> [ItemDTO] {
        let r = try await get("Items", [
            q("userId", userID), q("Recursive", "true"), q("IncludeItemTypes", kind),
            q("AnyProviderIdEquals", "imdb.\(imdb)"), q("Fields", "MediaSources,ProviderIds"), q("Limit", "5"),
        ])
        return r.items.compactMap(\.value).filter {
            caseInsensitiveValue($0.providerIds, "imdb")?.lowercased() == imdb.lowercased()
        }
    }

    private func sources(_ item: ItemDTO) -> [StreamItem] {
        (item.mediaSources ?? []).compactMap { src in
            let sourceID = src.id ?? item.id
            guard let url = ServerHTTP.url(base, "Videos/\(item.id)/stream", [
                q("static", "true"), q("MediaSourceId", sourceID), q("api_key", token),
            ]) else { return nil }
            let video = src.mediaStreams?.first { $0.type == "Video" }
            let audio = src.mediaStreams?.first { $0.type == "Audio" }
            let ext = ServerFormat.fileExtension(path: src.path, container: src.container)
            let label = ServerFormat.join([ServerFormat.resolution(width: video?.width, height: video?.height), ext?.uppercased()])
            let detail = ServerFormat.join([
                ServerFormat.videoCodec(video?.codec),
                ServerFormat.audio(codec: audio?.codec, channels: audio?.channels),
                ServerFormat.size(src.size),
                ServerFormat.bitrate(src.bitrate),
            ])
            return StreamItem.server(name: label.isEmpty ? (src.name ?? "Jellyfin") : label, detail: detail, url: url,
                                     filename: ext.map { "video.\($0)" })
        }
    }

    // MARK: Catalogue and search

    func catalog(type: String, id: String, skip: Int, search: String?) async throws -> [MetaPreview] {
        let kind = type == "series" ? "Series" : "Movie"
        var query = [
            q("userId", userID), q("Recursive", "true"), q("IncludeItemTypes", kind),
            q("Fields", "ProviderIds,Overview,Genres"), q("Limit", "40"), q("StartIndex", String(max(skip, 0))),
            q("EnableTotalRecordCount", "false"),
        ]
        if let term = search?.trimmingCharacters(in: .whitespacesAndNewlines), !term.isEmpty {
            query.append(q("searchTerm", term))
        } else {
            query += [q("SortBy", "DateCreated"), q("SortOrder", "Descending")]
        }
        let r = try await get("Items", query)
        return r.items.compactMap(\.value).compactMap { preview($0, type: type) }
    }

    private func preview(_ item: ItemDTO, type: String) -> MetaPreview? {
        var poster: String?
        if caseInsensitiveValue(item.imageTags, "primary") != nil {
            poster = ServerHTTP.url(base, "Items/\(item.id)/Images/Primary", [q("maxWidth", "500")])?.absoluteString
        }
        return MetaPreview.server(imdb: caseInsensitiveValue(item.providerIds, "imdb"),
                                  tmdb: caseInsensitiveValue(item.providerIds, "tmdb"),
                                  type: type, name: item.name ?? "Untitled", year: item.productionYear,
                                  overview: item.overview, genres: item.genres ?? [], poster: poster)
    }
}
