import Foundation

/// The next episode of a show you've been watching.
struct UpNextItem: Identifiable, Hashable {
    let item: MetaPreview
    let season: Int
    let episode: Int
    let title: String
    let thumb: URL?
    let runtime: Int?
    /// When the finished episode was watched; orders this card among Continue Watching cards.
    let updated: Date
    var id: String { "\(item.id):\(season):\(episode)" }
}

enum UpNext {
    /// The episode after `season`/`episode`: the next one in the season, else episode 1 of the next season.
    /// Returns nil when the show has nothing further that has aired.
    static func next(for item: MetaPreview, after season: Int, _ episode: Int) async -> (season: Int, episode: EpisodeItem)? {
        func load(_ s: Int) async -> [EpisodeItem] {
            await EpisodeLoader.load(itemID: item.id, type: "series", season: s) { await SourceResolver.stremioID(for: item) }
        }
        let current = await load(season)
        if current.isEmpty {
            // No metadata source answered: assume the following episode exists.
            return (season, EpisodeItem(id: episode + 1, name: "Episode \(episode + 1)"))
        }
        if let n = current.filter({ $0.id > episode }).min(by: { $0.id < $1.id }) { return aired(n) ? (season, n) : nil }
        guard season >= 1 else { return nil }
        let following = await load(season + 1)
        if let first = following.filter({ $0.id >= 1 }).min(by: { $0.id < $1.id }), aired(first) { return (season + 1, first) }
        return nil
    }

    static func resolve(_ entry: WatchHistory.Entry) async -> UpNextItem? {
        guard let se = entry.watchedThrough ?? entry.seasonEpisode, let n = await next(for: entry.item, after: se.season, se.episode) else { return nil }
        return UpNextItem(item: entry.item, season: n.season, episode: n.episode.id, title: n.episode.name,
                          thumb: n.episode.image ?? entry.item.backdropURL, runtime: n.episode.runtime,
                          updated: entry.updated)
    }

    private static let isoDay: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private static func aired(_ e: EpisodeItem) -> Bool {
        guard let d = e.airDate, !d.isEmpty else { return true }
        return d <= isoDay.string(from: .now)
    }
}
