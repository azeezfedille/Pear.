import Foundation

// MARK: - What a media server is

enum MediaServerKind: String, Codable, CaseIterable, Sendable {
    case jellyfin, plex
    var title: String { self == .jellyfin ? "Jellyfin" : "Plex" }
    var symbol: String { self == .jellyfin ? "server.rack" : "play.rectangle.fill" }
}

/// One signed-in server. The access token is not stored here: it lives in the Keychain (`MediaServerStore.tokenKey`).
struct MediaServerAccount: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let kind: MediaServerKind
    var name: String
    /// The address in use. For Plex this is the best connection found when the server was added.
    var baseURL: String
    /// Plex only: the server's other connections (LAN, remote, relay), tried in order when `baseURL` stops answering.
    var alternates: [String] = []
    /// Jellyfin only.
    var userID: String? = nil
    /// Plex only: the server's machine identifier, so adding the same server twice replaces it.
    var serverID: String? = nil
    var enabled = true
    /// Whether its "Recently added" rows appear on Home. Search and sources work either way.
    var showOnHome = true

    var host: String { URL(string: baseURL)?.host ?? baseURL }
}

enum ServerError: LocalizedError {
    case badAddress, notAServer, unreachable, unauthorized, quickConnectOff, expired, http(Int)

    var errorDescription: String? {
        switch self {
        case .badAddress: return "That address doesn't look right."
        case .notAServer: return "Nothing that looks like a Jellyfin server answered at that address."
        case .unreachable: return "Couldn't reach the server."
        case .unauthorized: return "The server refused the sign-in. Check the username and password."
        case .quickConnectOff: return "Quick Connect isn't turned on for this server."
        case .expired: return "The sign-in code expired. Try again."
        case .http(let code): return "The server answered with an error (HTTP \(code))."
        }
    }
}

// MARK: - What the rest of the app talks to

/// A media server as the add-on code sees it. `AddonClient` hands stream and catalogue requests for a server's
/// synthetic add-on (see `Addon.server`) to its backend instead of fetching `…/stream/…json` over HTTP.
protocol MediaServerBackend: Sendable {
    /// Playable sources for one title or episode. `id` is the Stremio id: `tt0111161`, or `tt0944947:1:2` for an episode.
    /// Never throws: a server that is down or doesn't have the title simply has no sources.
    func streams(type: String, id: String) async -> [StreamItem]
    /// `id` is "recent" (the only catalogue offered); `search` narrows it by title.
    func catalog(type: String, id: String, skip: Int, search: String?) async throws -> [MetaPreview]
    /// Called when the app comes to the foreground, so the first title opened afterwards isn't the one that pays for it.
    func warm() async
}

extension MediaServerBackend {
    func warm() async {}
}

/// `AddonClient` is an actor and the store is on the main actor, so the lookup table between them is its own little
/// thread-safe box.
final class MediaServerRegistry: @unchecked Sendable {
    static let shared = MediaServerRegistry()
    private let lock = NSLock()
    private var table: [String: any MediaServerBackend] = [:]

    func set(_ new: [String: any MediaServerBackend]) {
        lock.lock(); defer { lock.unlock() }
        table = new
    }

    func backend(for addon: Addon) -> (any MediaServerBackend)? {
        lock.lock(); defer { lock.unlock() }
        return table[addon.id]
    }
}

// MARK: - Servers as add-ons

extension Addon {
    /// A stand-in add-on for a server. It is never fetched: its manifest is built here and its requests are answered by the
    /// server's backend. Being an `Addon` is what lets sources, pins, the source filter, the player's source switcher, next
    /// episode, Home rows and search treat a server like any other add-on, with no changes to those screens.
    static func server(_ account: MediaServerAccount) -> Addon? {
        guard let url = URL(string: "pear-server://\(account.id)/manifest.json") else { return nil }
        // With Home off, `search` becomes a required extra: the catalogue can still be searched but is no longer browsable.
        let extra: [[String: Any]] = [["name": "search", "isRequired": !account.showOnHome], ["name": "skip"]]
        func catalog(_ type: String, _ label: String) -> [String: Any] {
            ["type": type, "id": "recent", "name": "\(account.name) — \(label)", "extra": extra]
        }
        let manifest: [String: Any] = [
            "id": "pear.server.\(account.kind.rawValue).\(account.id)",
            "name": "\(account.kind.title) · \(account.name)",
            "description": "\(account.kind.title) library",
            "types": ["movie", "series"],
            "resources": [["name": "stream", "types": ["movie", "series"], "idPrefixes": ["tt"]], "catalog"],
            "catalogs": [catalog("movie", "New"), catalog("series", "New")],
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: manifest),
              let decoded = try? JSONDecoder().decode(AddonManifest.self, from: data) else { return nil }
        return Addon(manifestURL: url, manifest: decoded)
    }

    var isMediaServer: Bool { manifestURL.scheme == "pear-server" }
}

// MARK: - HTTP

enum ServerIdentity {
    /// One id per install, sent to Jellyfin as DeviceId and to Plex as X-Plex-Client-Identifier.
    static var deviceID: String {
        let key = "mediaserver.deviceID"
        if let s = UserDefaults.standard.string(forKey: key) { return s }
        let s = UUID().uuidString.lowercased()
        UserDefaults.standard.set(s, forKey: key)
        return s
    }
    static var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0" }
}

enum ServerHTTP {
    /// Ephemeral: nothing from a media server is written to the shared URL cache.
    static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 15
        c.timeoutIntervalForResource = 60
        c.httpMaximumConnectionsPerHost = 4
        return URLSession(configuration: c)
    }()

    static func data(_ request: URLRequest, timeout: TimeInterval = 8) async throws -> Data {
        var req = request
        req.timeoutInterval = timeout
        let (d, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw ServerError.unreachable }
        switch http.statusCode {
        case 200..<300: return d
        case 401, 403: throw ServerError.unauthorized
        default: throw ServerError.http(http.statusCode)
        }
    }

    /// `base` + `path` + query, keeping any path the base already has (a server behind a reverse proxy at `/jellyfin`).
    static func url(_ base: URL, _ path: String, _ query: [URLQueryItem] = []) -> URL? {
        guard var c = URLComponents(url: base, resolvingAgainstBaseURL: false) else { return nil }
        var head = c.path
        while head.hasSuffix("/") { head.removeLast() }
        c.path = head + "/" + path
        c.queryItems = query.isEmpty ? nil : query
        return c.url
    }
}

/// Decodes one element of a list without letting a single odd entry fail the whole list.
struct Lossy<T: Decodable>: Decodable {
    let value: T?
    init(from decoder: Decoder) throws { value = try? T(from: decoder) }
}

private struct PascalKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}

extension JSONDecoder {
    /// Jellyfin's JSON is PascalCase (`ProviderIds`). This reads it into ordinary camelCase properties (`providerIds`).
    /// It also lowercases the first letter of dictionary keys, so look those up case-insensitively.
    static var pascalCase: JSONDecoder {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .custom { keys in
            let k = keys.last?.stringValue ?? ""
            return PascalKey(stringValue: k.prefix(1).lowercased() + k.dropFirst())
        }
        return d
    }
}

func caseInsensitiveValue(_ dict: [String: String]?, _ key: String) -> String? {
    dict?.first { $0.key.caseInsensitiveCompare(key) == .orderedSame }?.value
}

// MARK: - Building what the app's models expect

extension StreamItem {
    /// StreamItem is decode-only (its hints can't be built directly), so a source is assembled as JSON and decoded.
    static func server(name: String, detail: String?, url: URL, filename: String?) -> StreamItem? {
        var obj: [String: Any] = ["name": name, "url": url.absoluteString]
        if let detail, !detail.isEmpty { obj["description"] = detail }
        if let filename { obj["behaviorHints"] = ["filename": filename] }
        guard let data = try? JSONSerialization.data(withJSONObject: obj) else { return nil }
        return try? JSONDecoder().decode(StreamItem.self, from: data)
    }
}

extension MetaPreview {
    /// A library title as Home, Search and the detail page expect it. Titles with neither an IMDb nor a TMDB id are
    /// dropped (the rest of the app can't open them). `poster` is used only for TMDB-only titles: for IMDb ids the
    /// app's usual artwork is used, which keeps the rows looking like the rest of Home.
    static func server(imdb: String?, tmdb: String?, type: String, name: String, year: Int?, overview: String?,
                       genres: [String], poster: String?) -> MetaPreview? {
        let id: String
        if let imdb, imdb.hasPrefix("tt") { id = imdb }
        else if let tmdb, Int(tmdb) != nil { id = "tmdb:\(tmdb)" }
        else { return nil }
        return MetaPreview(id: id, type: type, name: name, poster: id.hasPrefix("tt") ? nil : poster, background: nil, logo: nil,
                           description: overview, releaseInfo: year.map(String.init), rating: nil,
                           genreIDs: genres.isEmpty ? nil : GenreNames.ids(from: genres), language: nil, countries: nil)
    }
}

/// The one-line labels shown under a source's name.
enum ServerFormat {
    static func resolution(width: Int?, height: Int?) -> String? {
        guard let h = height, h > 0 else { return nil }
        let w = width ?? 0
        if h >= 2000 || w >= 3500 { return "4K" }
        if h >= 1000 || w >= 1800 { return "1080p" }
        if h >= 700 || w >= 1200 { return "720p" }
        return "\(h)p"
    }

    static func videoCodec(_ raw: String?) -> String? {
        guard let r = raw?.lowercased(), !r.isEmpty else { return nil }
        switch r {
        case "h264", "avc", "avc1": return "H.264"
        case "hevc", "h265": return "HEVC"
        case "mpeg4": return "MPEG-4"
        case "vc1": return "VC-1"
        default: return r.uppercased()
        }
    }

    static func audio(codec raw: String?, channels: Int?) -> String? {
        guard let r = raw?.lowercased(), !r.isEmpty else { return nil }
        let names = ["aac": "AAC", "ac3": "AC3", "eac3": "EAC3", "dts": "DTS", "truehd": "TrueHD", "flac": "FLAC", "opus": "Opus", "mp3": "MP3"]
        let name = names[r] ?? r.uppercased()
        guard let c = channels, c > 0 else { return name }
        let layout: String
        switch c { case 1: layout = "1.0"; case 2: layout = "2.0"; case 6: layout = "5.1"; case 8: layout = "7.1"; default: layout = "\(c)ch" }
        return "\(name) \(layout)"
    }

    static func size(_ bytes: Int64?) -> String? {
        guard let b = bytes, b > 0 else { return nil }
        return ByteCountFormatter.string(fromByteCount: b, countStyle: .file)
    }

    static func bitrate(_ bps: Int?) -> String? {
        guard let b = bps, b > 0 else { return nil }
        return String(format: "%.1f Mbps", Double(b) / 1_000_000)
    }

    static func join(_ parts: [String?]) -> String { parts.compactMap { $0 }.joined(separator: " · ") }

    /// The first container name from a list like "mov,mp4,m4a" (Jellyfin reports that for MP4 files).
    static func fileExtension(path: String?, container: String?) -> String? {
        if let p = path {
            let e = URL(fileURLWithPath: p).pathExtension.lowercased()
            if !e.isEmpty, e.count <= 5 { return e }
        }
        return container?.split(separator: ",").first.map { String($0).lowercased() }
    }
}
