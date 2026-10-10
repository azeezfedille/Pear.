import Foundation

/// One downloadable subtitle file for a title.
struct OnlineSubtitle: Identifiable, Sendable, Hashable {
    let id: String
    let url: URL
    let lang: String          // as the service reports it, e.g. "eng"
    /// "English" (falls back to the raw code).
    var languageName: String {
        if let c = SubLanguages.canonical(lang), let n = SubLanguages.all.first(where: { $0.code == c })?.name { return n }
        return Locale.current.localizedString(forLanguageCode: lang)?.capitalized ?? lang.uppercased()
    }
}

/// OpenSubtitles through the public Stremio OpenSubtitles v3 endpoint: no account or API key.
/// GET {base}/subtitles/{movie|series}/{imdb}[:{season}:{episode}].json  ->  { subtitles: [{ id, url, lang }] }
actor OpenSubtitlesClient {
    static let shared = OpenSubtitlesClient()
    static let defaultBase = "https://opensubtitles-v3.strem.io"
    private var cache: [String: [OnlineSubtitle]] = [:]

    nonisolated var enabled: Bool { UserDefaults.standard.object(forKey: "subs.online") as? Bool ?? true }

    private struct Response: Decodable {
        struct Raw: Decodable {
            let id: String?; let url: String?; let lang: String?
            enum K: String, CodingKey { case id, url, lang }
            init(from d: Decoder) throws {
                let c = try d.container(keyedBy: K.self)
                if let s = try? c.decode(String.self, forKey: .id) { id = s }
                else if let n = try? c.decode(Int.self, forKey: .id) { id = String(n) }
                else { id = nil }
                url = try? c.decode(String.self, forKey: .url)
                lang = try? c.decode(String.self, forKey: .lang)
            }
        }
        let subtitles: [Raw]?
    }

    func search(imdb: String, season: Int?, episode: Int?) async -> [OnlineSubtitle] {
        guard enabled, imdb.hasPrefix("tt") else { return [] }
        let isSeries = season != nil && episode != nil
        let key = isSeries ? "\(imdb):\(season!):\(episode!)" : imdb
        if let hit = cache[key] { return hit }
        let base = UserDefaults.standard.string(forKey: "subs.baseURL").flatMap { $0.isEmpty ? nil : $0 } ?? Self.defaultBase
        guard let url = URL(string: base.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/subtitles/\(isSeries ? "series" : "movie")/\(key).json") else { return [] }
        var r = URLRequest(url: url)
        r.timeoutInterval = 15
        guard let (d, resp) = try? await URLSession.shared.data(for: r),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let parsed = try? JSONDecoder().decode(Response.self, from: d) else { return [] }
        let out: [OnlineSubtitle] = (parsed.subtitles ?? []).enumerated().compactMap { i, s in
            guard let u = s.url.flatMap(URL.init(string:)), let lang = s.lang, !lang.isEmpty else { return nil }
            return OnlineSubtitle(id: s.id ?? "\(i)-\(lang)", url: u, lang: lang)
        }
        cache[key] = out            // a 200 with nothing in it is an answer too: don't ask again this launch
        return out
    }

    /// What the player lists: up to `perPreferred` files in the preferred language first, then the best file of every other language.
    nonisolated static func choices(_ all: [OnlineSubtitle], preferred: String?, perPreferred: Int = 3) -> [OnlineSubtitle] {
        var out: [OnlineSubtitle] = []
        if let p = preferred, p != "off" { out += all.filter { SubLanguages.matches($0.lang, p) }.prefix(perPreferred) }
        var seen = Set(out.compactMap { SubLanguages.canonical($0.lang) ?? $0.lang })
        for s in all {
            let c = SubLanguages.canonical(s.lang) ?? s.lang
            if seen.insert(c).inserted { out.append(s) }
        }
        return out
    }
}
