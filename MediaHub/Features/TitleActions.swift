import SwiftUI

/// Shared actions behind the long-press menus on posters, seasons and episodes.
/// "Watched" lives in the watch history (a finished entry drives Up Next and clears Continue Watching);
/// library membership is LocalLibrary when Simkl isn't connected (Simkl's own library syncs itself).
@MainActor
enum TitleActions {
    /// Marks a whole title watched. For series it also records the last season/episode (from TMDB when
    /// a key is set) so Up Next offers what comes after; `season`/`episode` override that.
    static func markWatched(_ item: MetaPreview, history: WatchHistory, season: Int? = nil, episode: Int? = nil) {
        Task {
            var s = season, e = episode
            var minutes: Int?
            if item.type == "series", s == nil || e == nil,
               let d = await TMDBClient.shared.cachedDetails(for: item.id, type: item.type) {
                s = s ?? d.seasons?.map(\.seasonNumber).max().flatMap { $0 == 0 ? nil : $0 } ?? d.numberOfSeasons
                e = e ?? d.numberOfEpisodes
                minutes = d.minutes
            } else if item.type != "series",
                      let d = await TMDBClient.shared.cachedDetails(for: item.id, type: item.type) {
                minutes = d.minutes
            }
            if item.type == "series" {
                history.markWatched(item, key: "\(s ?? 1):\(e ?? 1)", season: s, episode: e,
                                    duration: Double(max(minutes ?? 45, 20) * max(e ?? 1, 1) * 60))
            } else {
                history.markWatched(item, duration: Double(max(minutes ?? 120, 30)) * 60)
            }
        }
    }

    static func unmarkWatched(_ item: MetaPreview, history: WatchHistory) {
        history.unmarkWatched(item.id)
    }

    /// Adds to the local library as planned, or flips an existing saved entry to watched.
    static func addToList(_ item: MetaPreview, library: LocalLibrary) {
        library.set(item, status: library.entry(for: item.id) == nil ? .planToWatch : .watched)
    }

    static func removeFromList(_ item: MetaPreview, library: LocalLibrary) {
        library.remove(item.id)
    }
}

/// The long-press ("dropdown") menu shown on any poster: watched state, list membership, and Details.
struct PosterContextMenu: View {
    let item: MetaPreview
    /// Offer "Keep Current Poster". Off on cards that don't show rotating artwork (Continue Watching).
    var artwork = true
    @Environment(WatchHistory.self) private var history
    @Environment(LocalLibrary.self) private var library

    private var isWatched: Bool { history.entry(for: item.id)?.isTitleWatched ?? false }
    private var inList: Bool { library.entry(for: item.id) != nil }

    var body: some View {
        Button {
            if isWatched { TitleActions.unmarkWatched(item, history: history) }
            else { TitleActions.markWatched(item, history: history) }
        } label: {
            Label(isWatched ? "Unmark as Watched" : "Mark as Watched",
                  systemImage: isWatched ? "circle" : "checkmark.circle")
        }
        Button {
            if inList { TitleActions.removeFromList(item, library: library) }
            else { library.set(item, status: .planToWatch) }
        } label: {
            Label(inList ? "Remove from Library" : "Add to Library",
                  systemImage: inList ? "bookmark.slash" : "bookmark")
        }
        if artwork {
            let kept = ArtworkRotation.shared.isPinned(item.id)
            Button {
                if kept { ArtworkRotation.shared.unpin(item.id) } else { ArtworkRotation.shared.pinPoster(item) }
            } label: {
                Label(kept ? "Resume Poster Rotation" : "Keep Current Poster", systemImage: kept ? "pin.slash" : "pin")
            }
        }
        NavigationLink(value: item) {
            Label("Details", systemImage: "info.circle")
        }
    }
}

extension View {
    /// Long-press menu for posters in carousels and grids. The card keeps its tap-to-open behaviour;
    /// this adds the dropdown with watched / library / details actions.
    func posterContextMenu(_ item: MetaPreview) -> some View {
        contextMenu { PosterContextMenu(item: item) }
    }
}
