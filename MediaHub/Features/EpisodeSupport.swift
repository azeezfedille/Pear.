import Foundation
import os

struct EpisodeItem: Identifiable {
    let id: Int          // episode number
    var name: String
    var overview: String?
    var image: URL?
    var rating: Double?
    var runtime: Int?
    var airDate: String?        // yyyy-MM-dd, when known
    var votes: Int?             // TMDB vote count behind `rating`, when known
    /// Best rated episode of its season (set by `EpisodeLoader`, see `markTopRated`).
    var isTopRated = false
}

extension EpisodeItem {
    private static let isoDay: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"; return f
    }()

    private struct DayStamp: Sendable { var text = ""; var expires = Date.distantPast }
    private static let dayStamp = OSAllocatedUnfairLock(initialState: DayStamp())

    /// Today as "yyyy-MM-dd" (local calendar day), formatted once per day. Every episode card asks several times per
    /// redraw whether its episode is upcoming; formatting a date each time added up across a season's worth of cards.
    static var todayString: String {
        dayStamp.withLock { s in
            let now = Date()
            if now >= s.expires {
                s.text = isoDay.string(from: now)
                let cal = Calendar.current
                s.expires = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: now)) ?? now.addingTimeInterval(3600)
            }
            return s.text
        }
    }

    /// The air date is known and still ahead of today (local calendar day). Unknown dates count as aired, same as
    /// `UpNext` and `Downloads`, so a show whose source gives no dates never looks unreleased.
    var isUpcoming: Bool {
        guard let d = airDate, !d.isEmpty else { return false }
        return d > Self.todayString
    }

    enum Freshness {
        case justAired, new
        var label: String { self == .justAired ? "JUST AIRED" : "NEW" }
        /// For running text, e.g. the line under an episode's description.
        var text: String { self == .justAired ? "Just aired" : "New" }
    }

    /// Aired today or yesterday = "Just aired"; within the last week = "New"; nil otherwise (older, upcoming or no date).
    var freshness: Freshness? {
        guard let d = airDate, let date = Self.isoDay.date(from: d) else { return nil }
        let cal = Calendar.current
        guard let days = cal.dateComponents([.day], from: cal.startOfDay(for: date), to: cal.startOfDay(for: .now)).day,
              days >= 0 else { return nil }
        if days <= 1 { return .justAired }
        return days <= 7 ? .new : nil
    }

    /// Flags the season's best rated episode(s). Only aired episodes with a real rating count (and, when TMDB says how
    /// many votes stand behind it, at least 5), at least three of them must be rated, and the top score has to beat
    /// the lowest, so a season of identical scores doesn't crown everything.
    static func markTopRated(_ list: inout [EpisodeItem]) {
        for i in list.indices { list[i].isTopRated = false }
        let rated = list.filter { !$0.isUpcoming && ($0.rating ?? 0) > 0 && ($0.votes ?? 5) >= 5 }
        guard rated.count >= 3,
              let top = rated.compactMap(\.rating).max(),
              let low = rated.compactMap(\.rating).min(), top > low else { return }
        for i in list.indices where list[i].rating == top && !list[i].isUpcoming { list[i].isTopRated = true }
    }

    /// "Oct 14, 2026" for an episode that hasn't aired yet; nil once it has (or when the date is unknown).
    var airsOn: String? {
        guard isUpcoming, let d = airDate, let date = Self.isoDay.date(from: d) else { return nil }
        return date.formatted(.dateTime.month(.abbreviated).day().year())
    }
}

struct NextEpisode {
    let season: Int
    let episode: EpisodeItem
}

struct SeasonOption: Identifiable, Hashable {
    let id: Int          // season number
    let title: String
}

/// What the player needs to browse and switch episodes without going back to the detail page.
/// Built by DetailView, which owns the add-ons, pins and metadata clients.
struct EpisodeProvider {
    var seasons: [SeasonOption]
    var episodes: @MainActor (Int) async -> [EpisodeItem]
    /// Finds a playable source for the episode and returns a ready-to-play request, or nil if none exists.
    var resolve: @MainActor (Int, EpisodeItem, PlayRequest) async -> PlayRequest?
    /// The episode after the one in `PlayRequest`, if there is one that has aired.
    var next: @MainActor (PlayRequest) async -> NextEpisode?
}

enum EpisodeLoader {
    /// TMDB first (stills, overviews, ratings); TVDB fills missing thumbnails or stands in when TMDB has nothing.
    static func load(itemID: String, type: String, season: Int,
                     imdb resolveIMDB: () async -> String?) async -> [EpisodeItem] {
        var list = await TMDBClient.shared.episodes(for: itemID, type: type, season: season).map {
            EpisodeItem(id: $0.episodeNumber, name: $0.name ?? "Episode \($0.episodeNumber)", overview: $0.overview,
                        image: $0.stillURL, rating: $0.voteAverage, runtime: $0.runtime, airDate: $0.airDate,
                        votes: $0.voteCount)
        }
        let needsArt = list.contains(where: { $0.image == nil })
        if (list.isEmpty || needsArt), TVDBClient.shared.hasKey, let imdb = await resolveIMDB() {
            let tv = await TVDBClient.shared.episodes(imdb: imdb, season: season)
            if list.isEmpty {
                list = tv.compactMap { e in
                    e.number.map { EpisodeItem(id: $0, name: e.name ?? "Episode \($0)", overview: e.overview,
                                               image: e.imageURL, rating: nil, runtime: e.runtime, airDate: e.aired) }
                }
            } else {
                for i in list.indices where list[i].image == nil {
                    list[i].image = tv.first(where: { $0.number == list[i].id })?.imageURL
                }
            }
        }
        EpisodeItem.markTopRated(&list)
        return list
    }
}

enum SourceResolver {
    /// Stremio id for a title: TMDB-sourced items are mapped to their IMDb id.
    static func stremioID(for item: MetaPreview) async -> String? {
        if item.id.hasPrefix("tmdb:"), let n = Int(item.id.dropFirst(5)) {
            return await TMDBClient.shared.imdbID(tmdb: n, type: item.type)
        }
        return item.id
    }

    /// Picks the stream for another episode, preferring (1) the add-on and release name that is playing now,
    /// (2) the pinned source, (3) the first playable stream from any add-on.
    @MainActor
    static func request(season: Int, episode: EpisodeItem, current: PlayRequest,
                        addons: [Addon], pins: PinnedSources) async -> PlayRequest? {
        let groups = await AddonClient.shared.streams(for: "\(current.imdb):\(season):\(episode.id)",
                                                      type: "series", addons: addons)
        // Task-group results arrive in completion order; keep the user's add-on order.
        let ordered = addons.compactMap { a in groups.first(where: { $0.0.id == a.id }) }

        func match(_ addonID: String, _ signature: String?) -> (Addon, StreamItem)? {
            guard let g = ordered.first(where: { $0.0.id == addonID }) else { return nil }
            let playable = g.1.filter(\.isPlayable)
            guard let s = playable.first(where: { $0.signature == signature }) ?? playable.first else { return nil }
            return (g.0, s)
        }

        // The source you are watching now wins (so "next episode" keeps your quality / provider), then the pin.
        var chosen: (Addon, StreamItem)?
        if let a = current.sourceAddonID { chosen = match(a, current.sourceSignature) }
        if chosen == nil, let pin = pins.pin(for: current.imdb) { chosen = match(pin.addonID, pin.signature) }
        if chosen == nil {
            for g in ordered { if let s = g.1.first(where: \.isPlayable) { chosen = (g.0, s); break } }
        }
        guard let (addon, stream) = chosen, let target = stream.playTarget else { return nil }

        return PlayRequest(url: target.url, headers: stream.requestHeaders, item: current.item,
                           key: "\(season):\(episode.id)", imdb: current.imdb,
                           season: season, episode: episode.id, episodeTitle: episode.name,
                           logo: current.logo, thumb: episode.image ?? current.item.backdropURL,
                           sourceAddonID: addon.id, sourceSignature: stream.signature, p2p: target.p2p)
    }
}
