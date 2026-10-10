import Foundation

// MARK: - Sign-in and discovery

enum PlexAPI {
    struct Pin: Sendable {
        let id: Int
        let code: String
        /// The page where the user approves the sign-in (Plex's own login, so passwords and 2FA never touch this app).
        var authURL: URL? {
            URL(string: "https://app.plex.tv/auth#?clientID=\(ServerIdentity.deviceID)&code=\(code)&context%5Bdevice%5D%5Bproduct%5D=Pear")
        }
    }

    struct Connection: Sendable { let uri: String; let local: Bool; let relay: Bool }

    struct ServerInfo: Sendable, Identifiable {
        let id: String            // machine identifier
        let name: String
        let owned: Bool
        /// Shared servers have their own token; for your own servers it equals the account token.
        let token: String?
        let connections: [Connection]
    }

    private struct PinDTO: Decodable { let id: Int; let code: String; let authToken: String? }
    private struct ResourceDTO: Decodable {
        let name: String?
        let provides: String?
        let clientIdentifier: String?
        let owned: Bool?
        let accessToken: String?
        let connections: [Lossy<ConnectionDTO>]?
    }
    private struct ConnectionDTO: Decodable { let uri: String?; let local: Bool?; let relay: Bool? }

    /// Headers Plex asks every client to send.
    static func headers(token: String? = nil) -> [String: String] {
        var h = [
            "Accept": "application/json",
            "X-Plex-Client-Identifier": ServerIdentity.deviceID,
            "X-Plex-Product": "Pear",
            "X-Plex-Version": ServerIdentity.version,
            "X-Plex-Platform": "iOS",
            "X-Plex-Device-Name": "Pear",
        ]
        if let token { h["X-Plex-Token"] = token }
        return h
    }

    private static func request(_ urlString: String, method: String = "GET", token: String? = nil) throws -> URLRequest {
        guard let url = URL(string: urlString) else { throw ServerError.badAddress }
        var req = URLRequest(url: url)
        req.httpMethod = method
        headers(token: token).forEach { req.setValue($1, forHTTPHeaderField: $0) }
        return req
    }

    // PIN sign-in: ask plex.tv for a code, open its login page, poll until the user has approved.

    static func createPin() async throws -> Pin {
        let d = try await ServerHTTP.data(try request("https://plex.tv/api/v2/pins?strong=true", method: "POST"), timeout: 10)
        let dto = try JSONDecoder().decode(PinDTO.self, from: d)
        return Pin(id: dto.id, code: dto.code)
    }

    /// The account token once the user has approved, nil while they haven't.
    static func checkPin(_ pin: Pin) async throws -> String? {
        do {
            let d = try await ServerHTTP.data(try request("https://plex.tv/api/v2/pins/\(pin.id)"), timeout: 10)
            let token = try JSONDecoder().decode(PinDTO.self, from: d).authToken
            return (token?.isEmpty ?? true) ? nil : token
        } catch ServerError.http(404) {
            throw ServerError.expired
        }
    }

    /// Servers this account can reach (its own and ones shared with it).
    static func servers(token: String) async throws -> [ServerInfo] {
        let req = try request("https://clients.plex.tv/api/v2/resources?includeHttps=1&includeRelay=1", token: token)
        let d = try await ServerHTTP.data(req, timeout: 15)
        let list = try JSONDecoder().decode([Lossy<ResourceDTO>].self, from: d).compactMap(\.value)
        return list.compactMap { r -> ServerInfo? in
            guard (r.provides ?? "").split(separator: ",").contains("server"),
                  let id = r.clientIdentifier, let name = r.name else { return nil }
            let conns = (r.connections ?? []).compactMap(\.value).compactMap { c -> Connection? in
                guard let uri = c.uri else { return nil }
                return Connection(uri: uri, local: c.local ?? false, relay: c.relay ?? false)
            }
            guard !conns.isEmpty else { return nil }
            return ServerInfo(id: id, name: name, owned: r.owned ?? false, token: r.accessToken, connections: conns)
        }
    }

    /// LAN first, then direct remote (https before http), relay last.
    static func preferred(_ a: Connection, _ b: Connection) -> Bool { rank(a) < rank(b) }

    private static func rank(_ c: Connection) -> Int {
        if c.relay { return 4 }
        let https = c.uri.hasPrefix("https")
        if c.local { return https ? 0 : 1 }
        return https ? 2 : 3
    }

    /// The connections that answer right now (`/identity` needs no token), in the order they were given.
    static func reachable(_ connections: [Connection]) async -> [Connection] {
        await withTaskGroup(of: (Int, Bool).self, returning: [Connection].self) { group in
            for (i, c) in connections.enumerated() {
                group.addTask {
                    guard let url = URL(string: c.uri + "/identity") else { return (i, false) }
                    var req = URLRequest(url: url)
                    req.setValue("application/json", forHTTPHeaderField: "Accept")
                    return (i, (try? await ServerHTTP.data(req, timeout: 4)) != nil)
                }
            }
            var up = Set<Int>()
            for await (i, ok) in group where ok { up.insert(i) }
            return connections.enumerated().filter { up.contains($0.offset) }.map(\.element)
        }
    }
}

// MARK: - Library

private struct PlexEntry: Sendable {
    let key: String
    let type: String          // "movie" | "series"
    let title: String
    let year: Int?
    let added: Int
    let imdb: String?
    let tmdb: String?
    let summary: String?
    let genres: [String]
    let thumb: String?
}

private struct PlexEnvelope: Decodable {
    let MediaContainer: Container
    struct Container: Decodable {
        let Metadata: [Lossy<PlexItem>]?
        let Directory: [Lossy<PlexSection>]?
        let totalSize: Int?
    }
}
private struct PlexSection: Decodable { let key: String?; let type: String? }
private struct PlexTag: Decodable { let id: String?; let tag: String? }
private struct PlexPart: Decodable { let key: String?; let file: String?; let size: Int64?; let container: String? }
private struct PlexMedia: Decodable {
    let bitrate: Int?
    let width: Int?
    let height: Int?
    let videoResolution: String?
    let container: String?
    let videoCodec: String?
    let audioCodec: String?
    let audioChannels: Int?
    let Part: [Lossy<PlexPart>]?
}
private struct PlexItem: Decodable {
    let ratingKey: String?
    let type: String?
    let title: String?
    let year: Int?
    let addedAt: Int?
    let summary: String?
    let thumb: String?
    let guid: String?
    let index: Int?
    let parentIndex: Int?
    let Guid: [Lossy<PlexTag>]?
    let Genre: [Lossy<PlexTag>]?
    let Media: [Lossy<PlexMedia>]?
}

/// One Plex server. Plex can't be asked "which item has IMDb id tt…" directly, so the first time it is needed the
/// whole library is listed once (ids, titles, added dates; about 500 titles per request) and kept for 15 minutes.
/// Matching, "recently added" and search all run on that list. Episodes are fetched per show, only when one is opened.
actor PlexBackend: MediaServerBackend {
    private let token: String
    private var base: String
    private let alternates: [String]
    private var index: [PlexEntry] = []
    private var indexLoadedAt: Date?
    private var indexTask: Task<[PlexEntry], Error>?
    private var leafCache: [String: (at: Date, items: [PlexItem])] = [:]

    init(account: MediaServerAccount, token: String) {
        self.token = token
        self.base = account.baseURL
        self.alternates = account.alternates
    }

    func warm() async { _ = try? await entries() }

    // MARK: Requests

    /// Tries the address in use first, then the server's other connections (home vs. away, relay), keeping the one that worked.
    private func get(_ path: String, _ query: [URLQueryItem] = [], timeout: TimeInterval = 8) async throws -> PlexEnvelope {
        var seen = Set<String>()
        let order = ([base] + alternates).filter { seen.insert($0).inserted }.prefix(3)
        var last: Error = ServerError.unreachable
        for (n, root) in order.enumerated() {
            guard let rootURL = URL(string: root), let url = ServerHTTP.url(rootURL, path, query) else { continue }
            var req = URLRequest(url: url)
            PlexAPI.headers(token: token).forEach { req.setValue($1, forHTTPHeaderField: $0) }
            do {
                let d = try await ServerHTTP.data(req, timeout: n == 0 ? timeout : 4)
                let env = try JSONDecoder().decode(PlexEnvelope.self, from: d)
                if root != base { base = root }
                return env
            } catch is CancellationError {
                throw CancellationError()
            } catch ServerError.unauthorized {
                throw ServerError.unauthorized
            } catch {
                last = error
            }
        }
        throw last
    }

    // MARK: Library index

    private func entries() async throws -> [PlexEntry] {
        if let at = indexLoadedAt, Date().timeIntervalSince(at) < 900 { return index }
        if let running = indexTask { return try await running.value }
        let task = Task { try await self.buildIndex() }
        indexTask = task
        defer { indexTask = nil }
        do {
            let built = try await task.value
            index = built
            indexLoadedAt = Date()
            return built
        } catch {
            if !index.isEmpty { return index }      // a stale list beats no list
            throw error
        }
    }

    private func buildIndex() async throws -> [PlexEntry] {
        let sections = try await get("library/sections").MediaContainer.Directory?.compactMap(\.value) ?? []
        var out: [PlexEntry] = []
        for section in sections {
            guard let key = section.key, section.type == "movie" || section.type == "show" else { continue }
            let kind = section.type == "show" ? "series" : "movie"
            var start = 0
            while true {
                let page = try await get("library/sections/\(key)/all", [
                    URLQueryItem(name: "includeGuids", value: "1"),
                    URLQueryItem(name: "X-Plex-Container-Start", value: String(start)),
                    URLQueryItem(name: "X-Plex-Container-Size", value: "500"),
                ], timeout: 25)
                let items = page.MediaContainer.Metadata?.compactMap(\.value) ?? []
                out += items.compactMap { entry($0, kind: kind) }
                start += 500
                if items.isEmpty || start >= (page.MediaContainer.totalSize ?? 0) { break }
            }
        }
        return out
    }

    private func entry(_ item: PlexItem, kind: String) -> PlexEntry? {
        guard let key = item.ratingKey, let title = item.title else { return nil }
        // New agent: `Guid` entries like imdb://tt0111161. Old agents: the main `guid` carries one id.
        let raw = (item.Guid ?? []).compactMap { $0.value?.id } + [item.guid].compactMap { $0 }
        func id(_ prefixes: [String]) -> String? {
            for s in raw {
                for p in prefixes {
                    guard let r = s.range(of: p) else { continue }
                    let rest = s[r.upperBound...].prefix { $0.isLetter || $0.isNumber }
                    if !rest.isEmpty { return String(rest) }
                }
            }
            return nil
        }
        return PlexEntry(key: key, type: kind, title: title, year: item.year, added: item.addedAt ?? 0,
                         imdb: id(["imdb://"]), tmdb: id(["tmdb://", "themoviedb://"]),
                         summary: item.summary, genres: (item.Genre ?? []).compactMap { $0.value?.tag }, thumb: item.thumb)
    }

    // MARK: Sources

    func streams(type: String, id: String) async -> [StreamItem] {
        let parts = id.split(separator: ":").map(String.init)
        guard let imdb = parts.first, imdb.hasPrefix("tt") else { return [] }
        let kind = type == "series" ? "series" : "movie"
        do {
            guard let hit = try await entries().first(where: { $0.type == kind && $0.imdb == imdb }) else { return [] }
            if kind == "movie" {
                let env = try await get("library/metadata/\(hit.key)")
                return (env.MediaContainer.Metadata ?? []).compactMap(\.value).flatMap(sources)
            }
            guard parts.count == 3, let season = Int(parts[1]), let number = Int(parts[2]) else { return [] }
            let episodes = try await leaves(of: hit.key)
            guard let ep = episodes.first(where: { $0.parentIndex == season && $0.index == number }) else { return [] }
            return sources(ep)
        } catch { return [] }
    }

    private func leaves(of showKey: String) async throws -> [PlexItem] {
        if let c = leafCache[showKey], Date().timeIntervalSince(c.at) < 600 { return c.items }
        let env = try await get("library/metadata/\(showKey)/allLeaves", timeout: 20)
        let items = (env.MediaContainer.Metadata ?? []).compactMap(\.value)
        leafCache[showKey] = (Date(), items)
        return items
    }

    private func sources(_ item: PlexItem) -> [StreamItem] {
        (item.Media ?? []).compactMap(\.value).compactMap { m -> StreamItem? in
            guard let part = (m.Part ?? []).compactMap(\.value).first, let key = part.key,
                  var c = URLComponents(string: base + key) else { return nil }
            c.queryItems = (c.queryItems ?? []) + [URLQueryItem(name: "X-Plex-Token", value: token)]
            guard let url = c.url else { return nil }
            let ext = ServerFormat.fileExtension(path: part.file, container: part.container ?? m.container)
            let res = ServerFormat.resolution(width: m.width, height: m.height) ?? Self.resolutionLabel(m.videoResolution)
            let label = ServerFormat.join([res, ext?.uppercased()])
            let detail = ServerFormat.join([
                ServerFormat.videoCodec(m.videoCodec),
                ServerFormat.audio(codec: m.audioCodec, channels: m.audioChannels),
                ServerFormat.size(part.size),
                ServerFormat.bitrate(m.bitrate.map { $0 * 1000 }),      // Plex reports kbps
            ])
            return StreamItem.server(name: label.isEmpty ? "Plex" : label, detail: detail, url: url,
                                     filename: ext.map { "video.\($0)" })
        }
    }

    private static func resolutionLabel(_ raw: String?) -> String? {
        guard let r = raw?.lowercased(), !r.isEmpty else { return nil }
        if r == "4k" { return "4K" }
        if r == "sd" { return "SD" }
        return Int(r) != nil ? "\(r)p" : r.uppercased()
    }

    // MARK: Catalogue and search

    func catalog(type: String, id: String, skip: Int, search: String?) async throws -> [MetaPreview] {
        let kind = type == "series" ? "series" : "movie"
        var list = try await entries().filter { $0.type == kind }
        if let q = search?.trimmingCharacters(in: .whitespacesAndNewlines), !q.isEmpty {
            list = list.filter { $0.title.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
            let lowered = q.lowercased()
            list.sort { a, b in
                let pa = a.title.lowercased().hasPrefix(lowered), pb = b.title.lowercased().hasPrefix(lowered)
                if pa != pb { return pa }
                return a.title.localizedCaseInsensitiveCompare(b.title) == .orderedAscending
            }
        } else {
            list.sort { $0.added > $1.added }
        }
        return list.dropFirst(max(skip, 0)).prefix(40).compactMap { e in
            MetaPreview.server(imdb: e.imdb, tmdb: e.tmdb, type: type, name: e.title, year: e.year, overview: e.summary,
                               genres: e.genres, poster: posterURL(e.thumb))
        }
    }

    /// Only used for titles that have no IMDb id (the usual artwork can't be found for those); carries the token.
    private func posterURL(_ thumb: String?) -> String? {
        guard let thumb, var c = URLComponents(string: base + thumb) else { return nil }
        c.queryItems = (c.queryItems ?? []) + [URLQueryItem(name: "X-Plex-Token", value: token)]
        return c.url?.absoluteString
    }
}
