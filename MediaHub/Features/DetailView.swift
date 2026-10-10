import SwiftUI
import SafariServices

private struct SeasonChip: Identifiable {
    let id: Int          // season number
    let title: String
    let poster: URL?
    let count: Int?
}

struct DetailView: View {
    let item: MetaPreview
    private let explicitStart: Bool

    /// `startSeason`/`startEpisode`: open with that episode selected (Continue Watching).
    init(item: MetaPreview, startSeason: Int? = nil, startEpisode: Int? = nil) {
        self.item = item
        explicitStart = startSeason != nil
        _season = State(initialValue: startSeason ?? 1)
        _episode = State(initialValue: startEpisode ?? 1)
    }
    @Environment(AddonStore.self) private var store
    @Environment(SimklStore.self) private var simkl
    @Environment(LibraryPrefs.self) private var prefs
    @Environment(PinnedSources.self) private var pins
    @Environment(WatchHistory.self) private var history
    @Environment(LocalLibrary.self) private var library
    @Environment(ThemeStore.self) private var theme
    @Environment(DownloadManager.self) private var downloads
    @Environment(ContentPrefs.self) private var contentPrefs
    @Environment(\.wideLayout) private var wide
    @State private var imdbID: String?
    @State private var onWatchlist = false
    @State private var ratings: [MDBListClient.Rating] = []
    @State private var logoURL: URL?
    @State private var details: TMDBClient.Details?
    @State private var similar: [MetaPreview] = []
    @State private var streams: [(Addon, [StreamItem])] = []
    @State private var loadingStreams = false
    @State private var showSources = false
    /// Set while the sources sheet is open to choose a download source: tapping a row enqueues it instead of playing.
    @State private var downloadTarget: DownloadTarget?
    private struct DownloadTarget { let season: Int?; let episode: Int?; let ep: EpisodeItem? }
    /// Add-on id the sources sheet is narrowed to; nil = all add-ons.
    @State private var sourceFilter: String?
    @State private var playRequest: PlayRequest?
    @State private var upNext: UpNextItem?
    @State private var userPicked = false
    /// Bumped when the opening episode is restored from history, so the strip scrolls to it even if the season did not change.
    @State private var restoreTick = 0
    @State private var pendingPlay: PlayRequest?
    @State private var season = 1
    @State private var episode = 1
    @State private var episodes: [EpisodeItem] = []
    @State private var loadingEpisodes = false
    @State private var seasonsExpanded = false
    @State private var trailers: [TMDBClient.Video] = []
    @State private var openTrailer: TMDBClient.Video?

    private var isSeries: Bool { item.type == "series" }

    /// Height of the collapsing hero (artwork + title block), roughly 60% of a phone screen like the Apple TV app.
    private static let heroHeight: CGFloat = 500

    // MARK: Derived data

    private var metaLine: String {
        var parts: [String] = []
        if let y = item.releaseInfo { parts.append(y) }
        if let m = details?.minutes { parts.append("\(m) min") }
        if let g = details?.genres?.prefix(2).map(\.name), !g.isEmpty { parts.append(g.joined(separator: ", ")) }
        return parts.joined(separator: "  ·  ")
    }

    /// TV: broadcaster/streamer. Movies: production studio.
    private var networkText: String? {
        let list = (isSeries ? details?.networks : details?.productionCompanies) ?? []
        let names = list.prefix(2).map(\.name)
        return names.isEmpty ? nil : names.joined(separator: ", ")
    }

    private var allRatings: [MDBListClient.Rating] {
        var out = ratings
        if let r = details?.voteAverage, r > 0, !out.contains(where: { $0.label == "TMDB" }) {
            out.append(MDBListClient.Rating(label: "TMDB", text: String(format: "%.1f", r), score: r))
        }
        return out
    }

    private var seasonChips: [SeasonChip] {
        if let s = details?.seasons, !s.isEmpty {
            return s.filter { ($0.episodeCount ?? 1) > 0 }
                .sorted { ($0.seasonNumber == 0 ? Int.max : $0.seasonNumber) < ($1.seasonNumber == 0 ? Int.max : $1.seasonNumber) }
                .map { SeasonChip(id: $0.seasonNumber, title: $0.title, poster: $0.posterURL, count: $0.episodeCount) }
        }
        return (1...max(details?.numberOfSeasons ?? 1, 1)).map {
            SeasonChip(id: $0, title: "Season \($0)", poster: nil, count: nil)
        }
    }

    // MARK: Body

    var body: some View {
        // A ZStack (not a bare if/else) so the loading tasks below belong to one stable view and don't restart
        // when the layout flips between phone and sidebar.
        ZStack {
            if wide { wideBody } else { phoneBody }
        }
        .ignoresSafeArea(edges: .top)
        .toolbarTitleDisplayMode(.inline)
        .sheet(isPresented: $showSources, onDismiss: { downloadTarget = nil; startPendingPlayback() }) { sourceSheet }
        // Presented from the page itself (not from inside the sources sheet): the sheet closes first,
        // then the player opens. This keeps dismissing the player reliable.
        .fullScreenCover(item: $playRequest) { r in
            PlayerScreen(request: r, provider: makeProvider(), onClose: { playRequest = nil })
        }
        .task {
            // Native metadata + suggestions (no-ops without a TMDB key).
            async let d = try? TMDBClient.shared.details(for: item.id, type: item.type)
            async let s = try? TMDBClient.shared.recommendations(for: item.id, type: item.type)
            details = await d
            let recommended = await s ?? []
            similar = await TitleClassifier.shared.filter(recommended, rules: contentPrefs.rules)
        }
        .task {
            guard MDBListClient.shared.hasKey, let imdb = await stremioID() else { return }
            imdbID = imdb
            ratings = await MDBListClient.shared.ratings(imdb: imdb, type: item.type)
        }
        .task { logoURL = await LogoResolver.shared.logo(for: item) }
        // The IMDb id keys downloads, so it is resolved up front for the badges.
        .task { _ = await ensureIMDB() }
        .task { trailers = await TMDBClient.shared.videos(for: item.id, type: item.type) }

        .task { await configureFromHistory() }
        .task(id: season) { await loadEpisodes() }
        .task(id: showSources) {
            // Query stream add-ons only when the picker opens.
            guard showSources else { return }
            streams = []
            sourceFilter = nil
            loadingStreams = true; defer { loadingStreams = false }
            // Reuses the id the page already resolved (or is resolving: lookups in flight are shared).
            guard let imdb = await ensureIMDB() else { return }
            let sid = isSeries ? "\(imdb):\(season):\(episode)" : imdb
            // Each add-on's answer is shown as it arrives, kept in the user's add-on order.
            let addons = store.enabledAddons
            for await group in AddonClient.shared.streamUpdates(for: sid, type: item.type, addons: addons) {
                guard showSources else { return }
                streams = AddonClient.ordered(streams + [group], by: addons)
            }
        }
    }

    // MARK: Page layouts

    private var phoneBody: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ParallaxHero(height: Self.heroHeight) {
                    RotatingArtwork(item: item, kind: .detail, size: 800)
                } info: {
                    heroInfo.padding(.horizontal, 20)
                }
                header.padding(.horizontal, 20)
                if isSeries { seasonSection }
                if !trailers.isEmpty { trailersSection }
                if !similar.isEmpty {
                    CatalogRowView(row: CatalogRow(id: "similar-\(item.id)", title: "More like this", items: similar))
                        .padding(.top, 8)
                }
                detailsSection
            }
            .padding(.bottom, 40)
        }
    }

    /// Sidebar layout: poster, title, facts, buttons and synopsis big on the left; seasons, episodes, trailers,
    /// similar titles and the details list on the right. Drag the right side left to cover the poster.
    private var wideBody: some View {
        CollapsingSplit {
            widePoster
        } pane: { ctx in
            PaneScroll(ctx: ctx) {
                VStack(alignment: .leading, spacing: 16) {
                    if isSeries { seasonSection }
                    if !trailers.isEmpty { trailersSection }
                    if !similar.isEmpty {
                        CatalogRowView(row: CatalogRow(id: "similar-\(item.id)", title: "More like this", items: similar))
                            .padding(.top, 8)
                    }
                    detailsSection
                }
                .padding(.leading, 8)
            }
        }
        .ignoresSafeArea(.container, edges: .bottom)
    }

    private var widePoster: some View {
        GeometryReader { geo in
            let compact = geo.size.height < 560
            ZStack(alignment: .bottomLeading) {
                RotatingArtwork(item: item, kind: .poster, size: 1000)
                    .frame(width: geo.size.width, height: geo.size.height)
                    .clipped()
                LinearGradient(stops: [.init(color: .clear, location: 0.2),
                                       .init(color: .black.opacity(0.6), location: 0.55),
                                       .init(color: .black.opacity(0.92), location: 1)],
                               startPoint: .top, endPoint: .bottom)
                VStack(alignment: .leading, spacing: compact ? 9 : 14) {
                    TitleArt(item: item, maxWidth: 300, maxHeight: compact ? 58 : 100, font: .largeTitle.bold())
                    if !metaLine.isEmpty || networkText != nil { metaRow }
                    if !allRatings.isEmpty { ratingsRow }
                    header
                }
                .foregroundStyle(.white)
                .scrollDisabled(true)       // the ratings strip must not swallow the drag that collapses the poster
                .padding(.horizontal, 22)
                .padding(.bottom, max(geo.safeAreaInsets.bottom, 0) + (compact ? 18 : 30))
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }

    // MARK: Header

    /// Title, facts and ratings: anchored to the bottom of the parallax hero, over the fade into the page.
    private var heroInfo: some View {
        VStack(alignment: .leading, spacing: 10) {
            TitleArt(item: item, maxWidth: 280, maxHeight: 100, font: .largeTitle.bold())
            if !metaLine.isEmpty || networkText != nil { metaRow }
            if !allRatings.isEmpty { ratingsRow }
        }
    }

    /// Below the hero, two calm groups with room between them: what to do (buttons), then what it's about
    /// (tagline + synopsis), so the Play button sits right under the title block.
    private var header: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 12) {
                actionBar
                if !isSeries, let imdb = imdbID, let rec = downloads.record(imdb: imdb, season: nil, episode: nil) {
                    downloadStatus(rec)
                }
            }
            if details?.tagline?.isEmpty == false || descriptionText != nil { synopsis }
        }
    }

    private var synopsis: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let t = details?.tagline, !t.isEmpty {
                Text(t).font(.footnote.italic()).foregroundStyle(.tertiary)
            }
            if let d = descriptionText { ExpandableText(text: d, lines: 2) }
        }
    }

    /// Year, runtime and genres, with the network / studio right next to them.
    private var metaRow: some View {
        let icon = isSeries ? "tv" : "building.2"
        let lead = metaLine.isEmpty ? "" : metaLine + "  ·  "
        return Group {
            if let n = networkText { Text("\(lead)\(Image(systemName: icon)) \(n)") } else { Text(metaLine) }
        }
        .font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
    }

    private var descriptionText: String? {
        [details?.overview, item.description].lazy.compactMap { $0 }.first { !$0.isEmpty }
    }

    // MARK: Action bar (play + small round buttons)

    /// Play button with compact round actions next to it: library toggle and watched toggle.
    private var actionBar: some View {
        HStack(spacing: 10) {
            Button { showSources = true } label: {
                Label(isSeries ? "Play S\(season):E\(episode)" : "Play", systemImage: "play.fill")
                    .font(.headline).frame(maxWidth: .infinity)
                    .foregroundStyle(theme.onAccent)
            }
            .buttonStyle(.glassProminent).controlSize(.large)
            .contextMenu { downloadMenu(season: isSeries ? season : nil, episode: isSeries ? episode : nil) }
            listButton
            watchedButton
        }
    }

    /// Round bookmark button: adds/removes the title from the watchlist (Simkl when connected).
    private var listButton: some View {
        Button {
            if viaSimkl {
                guard !onWatchlist else { return }
                Task {
                    if let imdb = await stremioID() { await simkl.addToWatchlist(imdb, type: item.type); onWatchlist = true }
                }
            } else {
                withAnimation {
                    if inList { library.remove(item.id) } else { saveLocal(.planToWatch) }
                }
            }
        } label: {
            Image(systemName: listSaved ? "bookmark.fill" : "bookmark")
                .font(.system(size: 17, weight: .semibold))
                .frame(width: 34, height: 34)
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.circle)
        .disabled(viaSimkl && onWatchlist)
        .accessibilityLabel(listSaved ? "Remove from watchlist" : "Add to watchlist")
    }

    /// Round checkmark button: marks the whole title watched, or unmarks it.
    private var watchedButton: some View {
        Button {
            withAnimation {
                if isWatched {
                    TitleActions.unmarkWatched(item, history: history)
                } else {
                    TitleActions.markWatched(item, history: history)
                    if let e = library.entry(for: item.id), e.status != .watched { library.set(e.item, status: .watched) }
                }
            }
        } label: {
            Image(systemName: isWatched ? "checkmark.circle.fill" : "checkmark.circle")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(isWatched ? theme.accent : Color.primary)
                .frame(width: 34, height: 34)
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.circle)
        .accessibilityLabel(isWatched ? "Unmark as watched" : "Mark as watched")
    }

    private var isWatched: Bool { history.entry(for: item.id)?.isTitleWatched ?? false }
    private var inList: Bool { library.entry(for: item.id) != nil }
    /// Simkl is this profile's library (connected and chosen); otherwise the list button works on the local library.
    private var viaSimkl: Bool { prefs.usesSimkl(simkl) }
    private var listSaved: Bool { viaSimkl ? onWatchlist : inList }

    /// Saves instantly, then looks up the title's other id in the background so it is recognised from any source.
    private func saveLocal(_ status: LocalLibrary.Status) {
        let isNew = library.entry(for: item.id) == nil
        library.set(item, status: status)
        guard isNew else { return }
        Task {
            if let other = await stremioID(), other != item.id { library.setAlias(other, for: item.id); history.link(item.id, other) }
        }
    }

    private var ratingsRow: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 16) {
                ForEach(allRatings) { RatingBadge(rating: $0, flat: true) }
            }
        }
        .scrollIndicators(.hidden)
    }

    // MARK: Up next / continue

    /// Opens on the episode you should watch: where you stopped, or the one after a finished episode. When there is
    /// no next episode (you finished the last one, or the last one that has aired), it stays on the episode you
    /// finished instead of falling back to S1 E1.
    private func configureFromHistory() async {
        guard isSeries, let e = history.entry(for: item.id) else { return }
        var target: (season: Int, episode: Int)?
        if e.isInProgress, let se = e.seasonEpisode {
            target = se
        } else if let w = e.watchedThrough {
            if let n = await UpNext.resolve(e) {
                upNext = n
                target = (n.season, n.episode)
            } else {
                target = w
            }
        } else if let se = e.seasonEpisode {
            target = se
        }
        guard let t = target, !explicitStart, !userPicked else { return }
        season = t.season
        episode = t.episode
        restoreTick += 1
    }

    // MARK: Seasons + episodes

    private var seasonSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Seasons").font(.title3.bold())
                Spacer()
                if seasonChips.contains(where: { $0.poster != nil }) {
                    Button { withAnimation(.snappy) { seasonsExpanded.toggle() } } label: {
                        HStack(spacing: 4) {
                            Text("Artwork")
                            Image(systemName: "chevron.down").rotationEffect(.degrees(seasonsExpanded ? 180 : 0))
                        }
                        .font(.subheadline)
                    }
                }
            }
            .padding(.horizontal, 20)
            seasonPills
            if seasonsExpanded { seasonPosters.transition(.opacity.combined(with: .move(edge: .top))) }
            episodeCarousel
        }
    }

    private func select(season n: Int) {
        guard n != season else { return }
        userPicked = true
        withAnimation(.snappy) { season = n; episode = 1; episodes = [] }
    }

    private var seasonPills: some View {
        ScrollView(.horizontal) {
            // One glass container for the whole strip: long shows have a pill per season, and separate glass layers
            // are each sampled and composited on their own.
            GlassEffectContainer(spacing: 8) {
                HStack(spacing: 8) {
                    ForEach(seasonChips) { c in
                        Button { select(season: c.id) } label: {
                            Text(c.title).font(.subheadline.weight(.semibold))
                                .padding(.horizontal, 16).padding(.vertical, 9)
                                .foregroundStyle(c.id == season ? theme.onAccent : Color.primary)
                                .glassEffect(c.id == season ? .regular.tint(theme.accent).interactive() : .regular.interactive(),
                                             in: .capsule)
                        }
                        .buttonStyle(.plain)
                        // Long tap: mark the whole season as watched (or unmark it).
                        .contextMenu { seasonMenu(c.id) }
                    }
                }
            }
            .padding(.horizontal, 20)
        }
        .scrollIndicators(.hidden)
    }

    /// The show's watched marker sits on its last-watched episode; a season counts when that episode is inside it.
    private func seasonProgress(_ s: Int) -> (watchedEpisodes: Int, total: Int)? {
        guard let se = history.entry(for: item.id)?.watchedThrough else { return nil }
        let total: Int?
        if se.season == s { total = episodes.isEmpty ? details?.seasons?.first(where: { $0.seasonNumber == s })?.episodeCount : episodes.count }
        else { total = details?.seasons?.first(where: { $0.seasonNumber == s })?.episodeCount }
        guard let total, total > 0 else { return nil }
        if se.season > s { return (total, total) }
        guard se.season == s else { return nil }
        return (min(se.episode, total), total)
    }

    private func isSeasonWatched(_ s: Int) -> Bool {
        guard let p = seasonProgress(s) else { return false }
        return p.watchedEpisodes >= p.total
    }

    private func setSeasonWatched(_ s: Int, _ watched: Bool) {
        withAnimation {
            if watched {
                let count = details?.seasons?.first(where: { $0.seasonNumber == s })?.episodeCount
                    ?? (s == season && !episodes.isEmpty ? episodes.count : nil)
                    ?? 10
                TitleActions.markWatched(item, history: history, season: s, episode: count)
            } else if isSeasonWatched(s) {
                history.unmarkThrough(episode: 1, season: s, item: item)
            } else {
                history.unmarkWatched(item.id)
            }
        }
    }

    private var seasonPosters: some View {
        ScrollView(.horizontal) {
            HStack(alignment: .top, spacing: 12) {
                ForEach(seasonChips) { c in
                    Button { select(season: c.id) } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            RemoteImage(url: c.poster, size: 56).frame(width: 56, height: 84)
                                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                .overlay(alignment: .topLeading) {
                                    if isSeasonWatched(c.id) {
                                        Image(systemName: "checkmark.circle.fill")
                                            .font(.system(size: 12, weight: .bold))
                                            .foregroundStyle(theme.onAccent, theme.accent).padding(3)
                                    }
                                }
                                .selectionRing(c.id == season, radius: 8, width: 1)
                            Text(c.title).font(.caption.weight(.medium)).lineLimit(1)
                            if let n = c.count { Text("\(n) episodes").font(.caption2).foregroundStyle(.secondary) }
                        }
                        .frame(width: 84, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    // Long tap: mark the whole season as watched (or unmark it).
                    .contextMenu { seasonMenu(c.id) }
                }
            }
            .padding(.horizontal, 20)
        }
        .scrollIndicators(.hidden)
    }

    private var episodeCarousel: some View {
        VStack(alignment: .leading, spacing: 10) {
            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    LazyHStack(spacing: 12) {
                        if loadingEpisodes && episodes.isEmpty {
                            ProgressView().frame(width: EpisodeCard<EmptyView>.width, height: EpisodeCard<EmptyView>.height)
                        }
                        ForEach(episodes) { episodeCard($0).id($0.id) }
                    }
                    .scrollTargetLayout()
                }
                .contentMargins(.horizontal, 20, for: .scrollContent)
                .scrollTargetBehavior(.viewAligned)
                .scrollIndicators(.hidden)
                // A fresh strip per season, so switching seasons starts at the first episode instead of keeping the old offset.
                .id(season)
                .onChange(of: episodes.count) { _, _ in
                    if episode > 1 { proxy.scrollTo(episode, anchor: .center) }
                }
                .onChange(of: restoreTick) { _, _ in
                    if episode > 1, !episodes.isEmpty { proxy.scrollTo(episode, anchor: .center) }
                }
            }
            // No TMDB/TVDB data: keep a manual way to pick the episode.
            if episodes.isEmpty && !loadingEpisodes {
                Stepper("Episode \(episode)", value: $episode, in: 1...99).padding(.horizontal, 20)
            }
        }
    }

    private func episodeCard(_ ep: EpisodeItem) -> some View {
        let watched = history.isWatched(id: item.id, season: season, episode: ep.id)
        return EpisodeCard(ep: ep, selected: ep.id == episode,
                    watched: watched,
                    upNext: !watched && upNext?.season == season && upNext?.episode == ep.id,
                    download: imdbID.flatMap { downloads.record(imdb: $0, season: season, episode: ep.id) },
                    onTap: { userPicked = true; episode = ep.id; showSources = true }) {
            // Same actions in the long-press menu and the card's "..." button.
            downloadMenu(season: season, episode: ep.id, ep: ep)
            Button("Mark as Watched", systemImage: "checkmark.circle") {
                withAnimation {
                    history.markWatched(item, key: "\(season):\(ep.id)", season: season, episode: ep.id,
                                        duration: Double(ep.runtime ?? 45) * 60,
                                        episodeTitle: ep.name, thumb: ep.image?.absoluteString)
                }
            }
            Button("Mark Episodes Until Here as Watched", systemImage: "checkmark.circle.fill") {
                withAnimation {
                    history.markThrough(episode: ep.id, season: season, item: item,
                                        duration: Double(ep.runtime ?? 45) * 60,
                                        episodeTitle: ep.name, thumb: ep.image?.absoluteString)
                }
            }
            Button("Unmark as Watched", systemImage: "circle", role: .destructive) {
                withAnimation {
                    history.unmarkThrough(episode: ep.id, season: season, item: item)
                }
            }
        }
    }

    private func loadEpisodes() async {
        guard isSeries else { return }
        loadingEpisodes = true
        let list = await EpisodeLoader.load(itemID: item.id, type: item.type, season: season) { await ensureIMDB() }
        guard !Task.isCancelled else { return }
        episodes = list
        loadingEpisodes = false
    }

    // MARK: Downloads

    /// Long-press menu entry: Download, or (depending on its state) Cancel / Delete / Retry.
    /// With `stream` set (sources sheet) it saves that exact source; otherwise the source is picked automatically.
    @ViewBuilder
    private func downloadMenu(season s: Int?, episode e: Int?, ep: EpisodeItem? = nil,
                              addon: Addon? = nil, stream: StreamItem? = nil) -> some View {
        if let r = imdbID.flatMap({ downloads.record(imdb: $0, season: s, episode: e) }) {
            switch r.state {
            case .done:
                Button("Delete Download", systemImage: "trash", role: .destructive) { downloads.delete(r.id) }
            case .queued, .downloading:
                Button("Pause Download", systemImage: "pause.circle") { downloads.pause(r.id) }
                Button("Cancel Download", systemImage: "xmark.circle", role: .destructive) { downloads.delete(r.id) }
            case .paused:
                Button("Resume Download", systemImage: "play.circle") { downloads.resume(r.id) }
                Button("Cancel Download", systemImage: "xmark.circle", role: .destructive) { downloads.delete(r.id) }
            case .failed:
                Button("Retry Download", systemImage: "arrow.clockwise") { downloads.retry(r.id) }
            }
        } else {
            Button("Download", systemImage: "arrow.down.circle") {
                if stream != nil { queueDownload(season: s, episode: e, ep: ep, addon: addon, stream: stream) }
                else { chooseDownloadSource(season: s, episode: e, ep: ep) }
            }
        }
    }

    /// Opens the sources sheet for that episode (or movie) so the download uses the source you pick.
    private func chooseDownloadSource(season s: Int?, episode e: Int?, ep: EpisodeItem?) {
        if isSeries, let s, let e { userPicked = true; season = s; episode = e }
        downloadTarget = DownloadTarget(season: s, episode: e, ep: ep)
        showSources = true
    }

    private func queueDownload(season s: Int?, episode e: Int?, ep: EpisodeItem? = nil,
                               addon: Addon? = nil, stream: StreamItem? = nil) {
        Task {
            guard let imdb = await ensureIMDB() else { return }
            let info = ep ?? (e != nil ? episodes.first(where: { $0.id == e }) : nil)
            downloads.enqueue(item: item, imdb: imdb, season: s, episode: e, episodeTitle: info?.name,
                              thumb: info?.image ?? item.backdropURL, logo: logoURL,
                              runtime: info?.runtime ?? details?.minutes, addonID: addon?.id, stream: stream)
        }
    }

    /// Long-press on a season name: download it episode by episode, or delete everything saved for it at once.
    @ViewBuilder
    private func seasonMenu(_ s: Int) -> some View {
        let recs = imdbID.map { downloads.records(imdb: $0, season: s) } ?? []
        let total = details?.seasons?.first(where: { $0.seasonNumber == s })?.episodeCount
            ?? (s == season && !episodes.isEmpty ? episodes.count : nil)
        if total == nil || recs.filter({ $0.state != .failed }).count < total! {
            Button("Download Season", systemImage: "arrow.down.circle") { downloadSeason(s) }
        }
        if !recs.isEmpty, let imdb = imdbID {
            Button(recs.count == 1 ? "Delete 1 Downloaded Episode" : "Delete \(recs.count) Downloaded Episodes",
                   systemImage: "trash", role: .destructive) { downloads.delete(imdb: imdb, season: s) }
        }
        if isSeasonWatched(s) {
            Button("Unmark Season as Watched", systemImage: "circle") { setSeasonWatched(s, false) }
        } else {
            Button("Mark Season as Watched", systemImage: "checkmark.circle") { setSeasonWatched(s, true) }
        }
    }

    private func downloadSeason(_ s: Int) {
        Task {
            guard let imdb = await ensureIMDB() else { return }
            let list = (s == season && !episodes.isEmpty) ? episodes
                : await EpisodeLoader.load(itemID: item.id, type: item.type, season: s) { await ensureIMDB() }
            downloads.enqueueSeason(item: item, imdb: imdb, season: s, episodes: list, logo: logoURL)
        }
    }

    /// Movie only (episodes carry a badge instead).
    private func downloadStatus(_ r: DownloadRecord) -> some View {
        let size = ByteCountFormatter.string(fromByteCount: r.bytes, countStyle: .file)
        let text: String, symbol: String
        switch r.state {
        case .done: text = "Downloaded · \(size)"; symbol = "arrow.down.circle.fill"
        case .downloading: text = "Downloading \(Int(r.progress * 100))%"; symbol = "arrow.down.circle"
        case .paused: text = r.progress > 0 ? "Paused \(Int(r.progress * 100))%" : "Paused"; symbol = "pause.circle"
        case .queued: text = "Waiting to download"; symbol = "clock"
        case .failed: text = r.error ?? "Download failed"; symbol = "exclamationmark.triangle.fill"
        }
        return HStack(spacing: 0) {
            Label(text, systemImage: symbol)
            if r.state == .downloading { DownloadSpeedText(id: r.id, prefix: " · ") }
        }
        .font(.footnote.weight(.medium))
        .foregroundStyle(r.state == .done ? theme.accent : Color.secondary)
    }

    // MARK: Trailers

    private var trailersSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Trailers & Extras").font(.title3.bold()).padding(.horizontal, 20)
            ScrollView(.horizontal) {
                LazyHStack(spacing: 12) {
                    ForEach(trailers) { v in TrailerCard(video: v) { openTrailer = v } }
                }
                .scrollTargetLayout()
            }
            .contentMargins(.horizontal, 20, for: .scrollContent)
            .scrollTargetBehavior(.viewAligned)
            .scrollIndicators(.hidden)
        }
        .fullScreenCover(item: $openTrailer) { v in
            if let u = v.watchURL { SafariView(url: u).ignoresSafeArea() }
        }
    }

    // MARK: Details footer

    private var detailRows: [(String, String)] {
        guard let d = details else { return [] }
        var rows: [(String, String)] = []
        func add(_ k: String, _ v: String?) { if let v, !v.isEmpty { rows.append((k, v)) } }
        func names(_ a: [TMDBClient.Details.Named]?) -> String? { a?.map(\.name).joined(separator: ", ") }
        func money(_ n: Int?) -> String? {
            guard let n, n > 0 else { return nil }
            return n.formatted(.currency(code: "USD").precision(.fractionLength(0)))
        }
        if isSeries {
            add("Network", names(d.networks))
            add("Status", d.status)
            add("First aired", prettyDate(d.firstAirDate))
            add("Last aired", prettyDate(d.lastAirDate))
            add("Seasons", d.numberOfSeasons.map(String.init))
            add("Episodes", d.numberOfEpisodes.map(String.init))
            add("Created by", names(d.createdBy))
        } else {
            add("Released", prettyDate(d.releaseDate))
            add("Director", d.credits?.crew?.filter { $0.job == "Director" }.map(\.name).joined(separator: ", "))
            add("Budget", money(d.budget))
            add("Box office", money(d.revenue))
        }
        add("Runtime", d.minutes.map { "\($0) min" })
        add("Genres", names(d.genres))
        add("Studio", names(d.productionCompanies))
        add("Country", names(d.productionCountries))
        add("Languages", d.spokenLanguages?.compactMap(\.englishName).joined(separator: ", "))
        add("Cast", d.credits?.cast?.prefix(10).map(\.name).joined(separator: ", "))
        return rows
    }

    private static let isoDay: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private func prettyDate(_ s: String?) -> String? {
        guard let s else { return nil }
        return Self.isoDay.date(from: s)?.formatted(date: .long, time: .omitted)
    }

    @ViewBuilder private var detailsSection: some View {
        let rows = detailRows
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                Text(isSeries ? "About the show" : "About the movie").font(.title3.bold()).padding(.bottom, 8)
                ForEach(rows, id: \.0) { row in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.0).font(.caption).foregroundStyle(.secondary)
                        Text(row.1).font(.subheadline)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 8)
                    Divider()
                }
            }
            .padding(.horizontal, 20).padding(.top, 8)
        }
    }

    // MARK: IDs

    private func ensureIMDB() async -> String? {
        if imdbID == nil { imdbID = await stremioID() }
        if let other = imdbID, other != item.id { history.link(item.id, other) }
        return imdbID
    }

    private func stremioID() async -> String? { await SourceResolver.stremioID(for: item) }

    // MARK: Sources + pinning

    /// The pinned stream for this show: exact add-on + name match, else that add-on's first playable stream.
    private var pinned: (addon: Addon, stream: StreamItem)? {
        guard let imdb = imdbID, let pin = pins.pin(for: imdb),
              let group = streams.first(where: { $0.0.id == pin.addonID }) else { return nil }
        let playable = group.1.filter(\.isPlayable)
        guard let s = playable.first(where: { $0.signature == pin.signature }) ?? playable.first else { return nil }
        return (group.0, s)
    }

    private func play(_ addon: Addon, _ s: StreamItem) {
        guard let t = s.playTarget, let imdb = imdbID else { return }
        let ep = isSeries ? episodes.first(where: { $0.id == episode }) : nil
        pendingPlay = PlayRequest(url: t.url, headers: s.requestHeaders, item: item,
                                  key: isSeries ? "\(season):\(episode)" : "movie", imdb: imdb,
                                  season: isSeries ? season : nil, episode: isSeries ? episode : nil,
                                  episodeTitle: ep?.name, logo: logoURL,
                                  thumb: ep?.image ?? item.backdropURL,
                                  sourceAddonID: addon.id, sourceSignature: s.signature, p2p: t.p2p)
        showSources = false
    }

    /// Runs once the sources sheet has fully closed.
    private func startPendingPlayback() {
        guard let p = pendingPlay else { return }
        pendingPlay = nil
        Task {
            try? await Task.sleep(for: .milliseconds(80))
            playRequest = p
        }
    }

    /// Lets the player browse episodes and jump to another one using the same add-ons and pins.
    private func makeProvider() -> EpisodeProvider? {
        guard isSeries else { return nil }
        let item = item, addons = store.enabledAddons, pins = pins
        let options = seasonChips.map { SeasonOption(id: $0.id, title: $0.title) }
        return EpisodeProvider(
            seasons: options,
            episodes: { s in
                await EpisodeLoader.load(itemID: item.id, type: item.type, season: s) { await SourceResolver.stremioID(for: item) }
            },
            resolve: { s, ep, current in
                await SourceResolver.request(season: s, episode: ep, current: current, addons: addons, pins: pins)
            },
            next: { current in
                guard let s = current.season, let e = current.episode,
                      let n = await UpNext.next(for: item, after: s, e) else { return nil }
                return NextEpisode(season: n.season, episode: n.episode)
            })
    }

    private func row(_ addon: Addon, _ s: StreamItem, isPinned: Bool) -> some View {
        Button {
            if let t = downloadTarget {
                queueDownload(season: t.season, episode: t.episode, ep: t.ep, addon: addon, stream: s)
                showSources = false
            } else { play(addon, s) }
        } label: {
            HStack {
                VStack(alignment: .leading) {
                    Text(s.name ?? s.title ?? "Stream").font(.headline)
                    if let t = s.description ?? s.title { Text(t).font(.caption).foregroundStyle(.secondary) }
                }
                Spacer()
                if s.p2pOff {
                    Label("P2P off", systemImage: "antenna.radiowaves.left.and.right.slash")
                        .font(.caption).foregroundStyle(.secondary)
                } else if s.isTorrent {
                    Image(systemName: s.p2pLocked ? "lock.fill" : "antenna.radiowaves.left.and.right").foregroundStyle(.secondary)
                }
                if isPinned { Image(systemName: "pin.fill").foregroundStyle(.tint) }
            }
        }
        .disabled(downloadTarget != nil ? !s.isDownloadable : !s.isPlayable)
        .contextMenu {
            if downloadTarget != nil {
                EmptyView()
            } else if s.isDownloadable {
                downloadMenu(season: isSeries ? season : nil, episode: isSeries ? episode : nil, addon: addon, stream: s)
            } else if s.isTorrent {
                Button("Torrents can't be downloaded", systemImage: "nosign") {}.disabled(true)
            }
        }
        .swipeActions {
            if let imdb = imdbID {
                if isPinned { Button("Unpin", systemImage: "pin.slash") { pins.remove(for: imdb) }.tint(.gray) }
                else if s.isPlayable {
                    Button("Pin", systemImage: "pin") { pins.set(Pin(addonID: addon.id, signature: s.signature), for: imdb) }.tint(.orange)
                }
            }
        }
    }

    private var sourceSheet: some View {
        NavigationStack {
            List {
                // Worked out once per redraw: `pinned` scans every add-on's streams, and the filter below used to
                // recompute it for each row.
                let pin = pinned
                if let p = pin, sourceFilter == nil || sourceFilter == p.addon.id {
                    Section("Pinned · \(p.addon.manifest.name)") { row(p.addon, p.stream, isPinned: true) }
                }
                let visible = SourceFilter.apply(streams, sourceFilter)
                ForEach(visible, id: \.0.id) { addon, items in
                    Section {
                        ForEach(items.filter { $0.id != pin?.stream.id }) { row(addon, $0, isPinned: false) }
                    } header: { Text(addon.manifest.name) } footer: {
                        VStack(alignment: .leading, spacing: 4) {
                            if addon.id == visible.first?.0.id { Text("Swipe a source to pin it to the top for this show.") }
                            if items.contains(where: \.p2pOff) {
                                Text("P2P is off, so torrent sources can't be played. Turn it on in Settings → Peer-to-peer.")
                            }
                        }
                    }
                }
            }
            // Pinned above the list (not the last row) so it is seen while sources keep arriving, scrolled or not.
            .safeAreaInset(edge: .top, spacing: 0) {
                if loadingStreams && !streams.isEmpty {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Checking more add-ons…").font(.footnote).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 8)
                    .background(.bar)
                    .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.2), value: loadingStreams)
            .overlay {
                if loadingStreams && streams.isEmpty { ProgressView() }
                else if !loadingStreams && streams.isEmpty {
                    ContentUnavailableView("No sources", systemImage: "play.slash",
                        description: Text("Add a stream add-on or connect a media server in Settings."))
                }
            }
            .navigationTitle(downloadTarget != nil ? "Download from…" : "Sources")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if streams.count > 1 {
                    ToolbarItem(placement: .topBarTrailing) { AddonFilterMenu(groups: streams, selection: $sourceFilter) }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
