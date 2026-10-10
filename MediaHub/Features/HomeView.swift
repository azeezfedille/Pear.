import SwiftUI

/// Navigation value for Continue Watching: opens the title with the episode you were on selected.
struct ResumeTarget: Hashable {
    let item: MetaPreview
    let season: Int?
    let episode: Int?
}

@MainActor @Observable
final class HomeModel {
    var rows: [CatalogRow] = []
    var suggested: [CatalogRow] = []
    var lists: [CatalogRow] = []
    var upNext: [UpNextItem] = []
    var themes: [ThemeRow] = []
    /// Set once the add-on rows and the TMDB suggestions have each finished loading at least once, so an empty Home
    /// can tell "still loading" from "your content settings hide everything".
    private var rowsLoaded = false
    private var suggestionsLoaded = false
    var settled: Bool { rowsLoaded && suggestionsLoaded }

    /// What each loader last finished with (its input key + when). Home's loading tasks restart every time the page
    /// comes back on screen (e.g. after leaving a catalogue or a title). Without this, each restart refetched
    /// everything and rebuilt the row lists from scratch, so the page shrank, re-grew and animated under your finger.
    /// A loader whose inputs are unchanged and whose data is recent now does nothing; pull-to-refresh forces it.
    @ObservationIgnored private var loadedAt: [String: (key: String, at: Date)] = [:]
    private static let freshFor: TimeInterval = 15 * 60
    private func isFresh(_ slot: String, _ key: String) -> Bool {
        guard let l = loadedAt[slot], l.key == key else { return false }
        return Date().timeIntervalSince(l.at) < Self.freshFor
    }
    private func markLoaded(_ slot: String, _ key: String) { loadedAt[slot] = (key, Date()) }
    @ObservationIgnored private var pendingThemes: [ThemeRow]?

    /// Rows that are already on screen, with today's content rules applied again. Used when a reload brings nothing
    /// back (no connection, add-ons down): the page keeps what it has instead of collapsing to empty, and a filter the
    /// user just switched on still takes effect.
    private func refiltered(_ old: [CatalogRow], rules: ContentRules) async -> [CatalogRow] {
        var kept: [CatalogRow] = []
        for row in old {
            let items = await TitleClassifier.shared.filter(row.items, rules: rules)
            guard !items.isEmpty else { continue }
            kept.append(CatalogRow(id: row.id, title: row.title, items: items, source: row.source,
                                   symbol: row.symbol, prefKey: row.prefKey, rawCount: row.rawCount))
        }
        return kept
    }

    /// Next episode for each show whose last episode you finished. Resolved concurrently, order kept.
    func loadUpNext(_ entries: [WatchHistory.Entry], key: String, force: Bool = false) async {
        if !force, isFresh("upNext", key) { return }
        let batch = entries
        guard !batch.isEmpty else { upNext = []; markLoaded("upNext", key); return }
        // Fill in as results land only when there is nothing on screen yet; otherwise swap once, at the end,
        // so a reload never shrinks the row the user is looking at.
        let progressive = upNext.isEmpty
        var done: [Int: UpNextItem] = [:]
        await withTaskGroup(of: (Int, UpNextItem?).self) { group in
            for (i, e) in batch.enumerated() { group.addTask { (i, await UpNext.resolve(e)) } }
            for await (i, n) in group {
                if let n { done[i] = n }
                if progressive { upNext = done.keys.sorted().compactMap { done[$0] } }
            }
        }
        guard !Task.isCancelled else { return }
        upNext = done.keys.sorted().compactMap { done[$0] }
        markLoaded("upNext", key)
    }

    /// Five themed collections, different every day. One spare theme is loaded in case another has too little data.
    func loadThemes(rules: ContentRules, enrichWith addon: Addon?, key: String, force: Bool = false) async {
        if !force, isFresh("themes", key) { return }
        let progressive = themes.isEmpty
        pendingThemes = nil
        await ThemeCatalog.load(count: ThemeCatalog.homeCandidates, show: ThemeCatalog.homeRows, rules: rules,
                                enrichWith: addon) { [weak self] rows in
            guard let self else { return }
            self.pendingThemes = rows
            if progressive { self.themes = rows }
        }
        guard !Task.isCancelled, let latest = pendingThemes else { return }
        themes = latest
        if !latest.isEmpty { markLoaded("themes", key) }
    }

    func loadLists(selected: Set<Int>, rules: ContentRules, key: String, force: Bool = false) async {
        guard MDBListClient.shared.hasKey, !selected.isEmpty else { lists = []; return }
        if !force, isFresh("lists", key) { return }
        let chosen = await MDBListClient.shared.userLists().filter { selected.contains($0.id) }
        let progressive = lists.isEmpty
        var done: [Int: CatalogRow] = [:]
        await withTaskGroup(of: (Int, CatalogRow?).self) { group in
            for (i, l) in chosen.enumerated() {
                group.addTask {
                    let raw = await MDBListClient.shared.items(listID: l.id)
                    let items = await TitleClassifier.shared.filter(raw, rules: rules)
                    return (i, items.isEmpty ? nil : CatalogRow(id: "mdb-\(l.id)", title: l.name, items: items, symbol: "list.star"))
                }
            }
            for await (i, row) in group {
                guard let row else { continue }
                done[i] = row
                if progressive { lists = done.keys.sorted().compactMap { done[$0] } }
            }
        }
        guard !Task.isCancelled else { return }
        // Nothing came back (MDBList unreachable): keep the lists on screen, minus any that were just deselected.
        if done.isEmpty, !lists.isEmpty {
            let wanted = Set(selected.map { "mdb-\($0)" })
            lists = await refiltered(lists.filter { wanted.contains($0.id) }, rules: rules)
            return
        }
        lists = done.keys.sorted().compactMap { done[$0] }
        if !done.isEmpty { markLoaded("lists", key) }
    }

    /// Calendar day number (local time). Changes at local midnight.
    static var currentDay: Int { Calendar.current.ordinality(of: .day, in: .era, for: .now) ?? 0 }

    /// Day the hero was last picked for. Stored so the hero is re-evaluated when it changes.
    var heroDay: Int = HomeModel.currentDay

    /// Re-picks the hero if the calendar day rolled over (call when the app returns to the foreground).
    func refreshHeroDay() {
        let d = Self.currentDay
        if d != heroDay { heroDay = d }
    }

    /// Trending movies and shows interleaved, so the hero mixes both. TMDB's weekly trending barely moves day to day,
    /// so instead of always taking the first 7, each day shows the next 7 along the list (wrapping around). Same
    /// items all day, a fresh set tomorrow, and no overlap between consecutive days.
    var hero: [MetaPreview] {
        let m = suggested.first { $0.id == "trend-movie" }?.items ?? []
        let t = suggested.first { $0.id == "trend-tv" }?.items ?? []
        var mixed: [MetaPreview] = []
        for i in 0..<max(m.count, t.count) {
            if i < m.count { mixed.append(m[i]) }
            if i < t.count { mixed.append(t[i]) }
        }
        let src = mixed.isEmpty ? (rows.first?.items ?? []) : mixed
        let pool = src.filter { $0.backdropURL != nil || $0.posterURL != nil }
        let size = 7
        guard pool.count > size else { return pool }
        let start = (heroDay * size) % pool.count
        return (0..<size).map { pool[(start + $0) % pool.count] }
    }

    private nonisolated static func recommendations(after last: MetaPreview?) async -> [MetaPreview] {
        guard let l = last else { return [] }
        return (try? await TMDBClient.shared.recommendations(for: l.id, type: l.type)) ?? []
    }

    /// TMDB trending + recommendations based on the last thing you watched.
    func loadSuggestions(last: MetaPreview?, rules: ContentRules, key: String, force: Bool = false) async {
        defer { suggestionsLoaded = true }
        guard TMDBClient.shared.hasKey else { suggested = []; return }
        if !force, isFresh("suggested", key) { return }
        async let movies = try? await TMDBClient.shared.trending("movie")
        async let shows = try? await TMDBClient.shared.trending("tv")
        async let because = Self.recommendations(after: last)
        let (rawM, rawT, rawB) = await (movies, shows, because)
        let m = await TitleClassifier.shared.filter(rawM ?? [], rules: rules)
        let t = await TitleClassifier.shared.filter(rawT ?? [], rules: rules)
        let b = await TitleClassifier.shared.filter(rawB, rules: rules)
        var out: [CatalogRow] = []
        if let l = last, !b.isEmpty {
            out.append(CatalogRow(id: "because", title: "Because you watched \(l.name)", items: b, symbol: "sparkles",
                                  prefKey: ContentRules.Builtin.because))
        }
        if !m.isEmpty { out.append(CatalogRow(id: "trend-movie", title: "Trending Movies", items: m, source: .tmdbTrending("movie"), symbol: "flame.fill", prefKey: ContentRules.Builtin.trendingMovies)) }
        if !t.isEmpty { out.append(CatalogRow(id: "trend-tv", title: "Trending Shows", items: t, source: .tmdbTrending("tv"), symbol: "flame.fill", prefKey: ContentRules.Builtin.trendingShows)) }
        guard !Task.isCancelled else { return }
        // Both trending requests failed (no connection): keep the rows on screen rather than blanking them.
        if rawM == nil, rawT == nil, !suggested.isEmpty {
            suggested = await refiltered(suggested, rules: rules)
            return
        }
        suggested = out
        if !out.isEmpty { markLoaded("suggested", key) }
    }

    /// Add-on catalogues that get a row on Home, in add-on order.
    /// Catalogues the user switched off are dropped first, so they don't use up the 12 row slots. Add-ons with a
    /// catalogue picker (AIOMetadata) contribute only what the user added, and those rows are never cut by the cap:
    /// the user asked for each one.
    nonisolated static func homeJobs(addons: [Addon], rules: ContentRules, pickers: Set<String>) -> [(Addon, AddonManifest.CatalogDef)] {
        var slots = 12
        var jobs: [(Addon, AddonManifest.CatalogDef)] = []
        for a in addons {
            let picker = a.isAIOMetadata || pickers.contains(a.id)
            for c in a.homeCatalogs where rules.showsOnHome(a, c, picker: picker) {
                if !picker {
                    guard slots > 0 else { continue }
                    slots -= 1
                }
                jobs.append((a, c))
            }
        }
        return jobs
    }

    func load(addons: [Addon], rules: ContentRules, pickers: Set<String> = [], key: String, force: Bool = false) async {
        if !force, rowsLoaded, isFresh("rows", key) { return }
        let jobs = Self.homeJobs(addons: addons, rules: rules, pickers: pickers)
        // Rows appear one by one only on the very first load. A reload keeps what is on screen and swaps once at
        // the end, so the page never collapses to a single row and re-grows (that was the jump after leaving a catalogue).
        let progressive = rows.isEmpty
        var done: [Int: CatalogRow] = [:]
        var fetchFailures = 0
        await withTaskGroup(of: (Int, CatalogRow?, Bool).self) { group in
            for (i, job) in jobs.enumerated() {
                group.addTask {
                    let (addon, cat) = job
                    // The Bool says the request itself failed (as opposed to an empty or fully filtered catalogue).
                    guard let raw = try? await AddonClient.shared.catalog(addon: addon, catalog: cat) else { return (i, nil, true) }
                    guard !raw.isEmpty else { return (i, nil, false) }
                    let items = await TitleClassifier.shared.filter(raw, rules: rules)
                    guard !items.isEmpty else { return (i, nil, false) }
                    let kind = cat.type == "movie" ? "Movies" : cat.type == "series" ? "Series" : cat.type.capitalized
                    return (i, CatalogRow(id: "\(addon.id)/\(cat.type)/\(cat.id)",
                                          title: "\(cat.name ?? cat.id) \(kind)", items: items,
                                          source: .addon(addon, cat), symbol: "film.stack",
                                          prefKey: ContentRules.rowKey(addon, cat), rawCount: raw.count), false)
                }
            }
            // Rows appear as each catalog lands; order stays stable.
            for await (i, row, failed) in group {
                if failed { fetchFailures += 1 }
                guard let row else { continue }
                done[i] = row
                if progressive { rows = done.keys.sorted().compactMap { done[$0] } }
            }
        }
        // Settle on exactly this run's result, so rows from an add-on that was just switched off (or whose
        // catalogs all failed) don't linger. Skipped when superseded by a newer load.
        guard !Task.isCancelled else { return }
        // Every request failed (no connection): keep the rows already on screen, for the add-ons still in use, instead
        // of swapping in an empty page. Not marked fresh, so the next visit tries again.
        if !jobs.isEmpty, fetchFailures == jobs.count, !rows.isEmpty {
            let wanted = Set(jobs.map { "\($0.0.id)/\($0.1.type)/\($0.1.id)" })
            rows = await refiltered(rows.filter { wanted.contains($0.id) }, rules: rules)
            rowsLoaded = true
            return
        }
        rows = done.keys.sorted().compactMap { done[$0] }
        rowsLoaded = true
        if !done.isEmpty || jobs.isEmpty { markLoaded("rows", key) }
    }
}

extension CatalogRow {
    /// Colour of the row's title icon. ThemeStore is @MainActor, so this must be too.
    @MainActor
    func accent(_ theme: ThemeStore) -> Color {
        switch id {
        case "because": return theme.accent2
        case "trend-movie": return .orange
        case "trend-tv": return .cyan
        default: return id.hasPrefix("mdb-") ? .teal : theme.accent
        }
    }
}

struct HomeView: View {
    @Environment(AddonStore.self) private var store
    @Environment(WatchHistory.self) private var history
    @Environment(ThemeStore.self) private var theme
    @Environment(ContentPrefs.self) private var contentPrefs
    @Environment(\.scenePhase) private var phase
    @Environment(\.wideLayout) private var wide
    @AppStorage("tmdb.key") private var tmdbKey = ""
    @AppStorage("mdblist.key") private var mdbKey = ""
    @AppStorage("mdblist.lists") private var mdbLists = ""
    @State private var model = HomeModel()
    /// Colour pulled from the current hero artwork; washes softly behind the first rows.
    @State private var tint: Color?
    /// Reloads the add-on rows when the add-ons, the catalogues chosen for Home, or the content filter change.
    /// `pickerKey` covers an add-on being switched to / from picking its catalogues by hand.
    private var addonTaskID: [String] {
        let ids: [String] = store.enabledAddons.map { $0.id }
        let rules = contentPrefs.rules
        let extra: [String] = [String(store.revision), String(MediaServerStore.shared.revision), rules.addonRowKey, rules.categoryKey, pickerKey]
        return ids + extra
    }
    private var pickerKey: String { store.pickerIDs.sorted().joined(separator: ",") }
    private var themesHidden: Bool { contentPrefs.rules.isRowHidden(ContentRules.Builtin.themes) }
    /// Everything on Home is switched off by the user's content settings (and nothing is still loading).
    private var hidesEverything: Bool {
        model.rows.isEmpty && model.suggested.isEmpty && model.settled
            && (contentPrefs.rules.hasFilters || !contentPrefs.rules.hiddenRows.isEmpty)
    }
    private func visible(_ rows: [CatalogRow]) -> [CatalogRow] { rows.filter { !contentPrefs.rules.isRowHidden($0.prefKey) } }
    private var heroDeps: Int { model.rows.count + model.suggested.count + model.lists.count + model.upNext.count + model.themes.count }
    /// Rows fade in while Home first fills; once it has settled, later changes (themes, lists, Up Next) land without
    /// animating the whole feed, which is what made the page lurch.
    private var loadAnimation: Animation? { model.settled ? nil : .smooth(duration: 0.5) }
    private var selectedLists: Set<Int> { Set(mdbLists.split(separator: ",").compactMap { Int($0) }) }

    var body: some View {
        NavigationStack {
            feed
                .navigationDestination(for: MetaPreview.self) { DetailView(item: $0) }
                .navigationDestination(for: ResumeTarget.self) { DetailView(item: $0.item, startSeason: $0.season, startEpisode: $0.episode) }
                .navigationDestination(for: CatalogRow.self) { CatalogGridView(row: $0) }
                .task(id: addonTaskID) { await model.load(addons: store.enabledAddons, rules: contentPrefs.rules, pickers: store.pickerIDs, key: addonTaskID.joined(separator: "|")) }
                .task(id: themesTaskID) { await model.loadThemes(rules: contentPrefs.rules, enrichWith: store.enrichmentAddon, key: themesTaskID) }
                .task(id: listsTaskID) { await model.loadLists(selected: selectedLists, rules: contentPrefs.rules, key: listsTaskID) }
                .task(id: suggestionsTaskID) { await model.loadSuggestions(last: history.lastWatched, rules: contentPrefs.rules, key: suggestionsTaskID) }
                .task(id: history.finishedSeries) { await model.loadUpNext(history.finishedEntries, key: history.finishedSeries.sorted().joined(separator: ",")) }
        }
    }

    // The task ids are built here, one typed String each: long `a + "|" + b + (c ? ...)` chains inside the
    // modifier list make the compiler give up ("unable to type-check this expression in reasonable time").
    private var themesTaskID: String {
        let off: String = themesHidden ? "|off" : ""
        let aio: String = store.enrichmentAddon?.id ?? ""
        return tmdbKey + "|" + contentPrefs.rules.categoryKey + off + "|" + aio
    }
    private var listsTaskID: String {
        return mdbKey + mdbLists + "|" + contentPrefs.rules.categoryKey
    }
    private var suggestionsTaskID: String {
        let last: String = history.lastWatched?.id ?? ""
        return tmdbKey + last + "|" + contentPrefs.rules.categoryKey
    }

    /// The Home feed with its chrome; navigation destinations and loading tasks are added in `body`.
    @ViewBuilder private var feed: some View {
        if wide { wideFeed } else { phoneFeed }
    }

    private var phoneFeed: some View {
        ScrollView {
            rows
                .padding(.bottom, 40)
                .animation(loadAnimation, value: heroDeps)
                .background(alignment: .top, content: { ambient })
        }
        .ignoresSafeArea(edges: .top)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
        .scrollEdgeEffectHidden(true, for: .top)
        .profileToolbar(logo: true)
        .scrollIndicators(.hidden)
        .refreshable { await refresh() }
        .onChange(of: phase) { _, p in if p == .active { model.refreshHeroDay() } }
        .overlay { emptyState }
    }

    /// Sidebar layout: the day's featured titles as a big poster panel on the left, the rows on the right. Drag the
    /// rows left to cover the poster and get the whole width for titles.
    private var wideFeed: some View {
        CollapsingSplit(showsHero: !model.hero.isEmpty) {
            WideHeroPanel(items: model.hero, tint: $tint)
        } pane: { ctx in
            PaneScroll(ctx: ctx, refresh: refresh) {
                LazyVStack(alignment: .leading, spacing: 30) { feedRows }
                    .padding(.leading, 14)
                    .animation(loadAnimation, value: heroDeps)
                    .background(alignment: .top, content: { ambient })
            }
        }
        .ignoresSafeArea(.container, edges: [.top, .bottom])
        .navigationBarTitleDisplayMode(.inline)
        .profileToolbar(logo: true)
        .onChange(of: phase) { _, p in if p == .active { model.refreshHeroDay() } }
        .overlay { emptyState }
    }

    private var rows: some View {
        LazyVStack(alignment: .leading, spacing: 30) {
            let hero = model.hero
            if !hero.isEmpty { HeroCarousel(items: hero, tint: $tint) }
            feedRows
        }
    }

    /// Everything under the hero: continue watching, themed collections and the catalogue rows.
    @ViewBuilder private var feedRows: some View {
        if !history.continueEntries.isEmpty || !model.upNext.isEmpty {
            ContinueRow(entries: history.continueEntries, upNext: model.upNext)
        }
        if let t = themeRow(0) { ThemeCarousel(row: t) }
        ForEach(visible(model.suggested)) { CatalogRowView(row: $0) }
        if let t = themeRow(1) { ThemeCarousel(row: t) }
        ForEach(model.lists) { CatalogRowView(row: $0) }
        if let t = themeRow(2) { ThemeCarousel(row: t) }
        // The rest of the themes are spread through the add-on rows: one after every second row.
        let addonRows = visible(model.rows)
        ForEach(Array(addonRows.enumerated()), id: \.element.id) { i, row in
            CatalogRowView(row: row)
            if i % 2 == 1, let t = themeRow(3 + i / 2) { ThemeCarousel(row: t) }
        }
        // Themes that found no slot between add-on rows (few or no add-on rows) close the feed.
        ForEach(trailingThemes(addonRowCount: addonRows.count)) { ThemeCarousel(row: $0) }
    }

    /// The i-th themed row of today, or nil when themes are switched off or fewer than that loaded.
    private func themeRow(_ i: Int) -> ThemeRow? {
        guard !themesHidden, model.themes.indices.contains(i) else { return nil }
        return model.themes[i]
    }

    private func trailingThemes(addonRowCount: Int) -> [ThemeRow] {
        guard !themesHidden else { return [] }
        let first = 3 + addonRowCount / 2
        guard model.themes.count > first else { return [] }
        return Array(model.themes[first...])
    }

    @ViewBuilder private var emptyState: some View {
        if hidesEverything {
            ContentUnavailableView {
                Label("Nothing to show", systemImage: "eye.slash")
            } description: {
                Text("Your content settings are hiding everything here. Change them in Settings → Content & catalogues.")
            }
        } else if model.rows.isEmpty && model.suggested.isEmpty {
            ProgressView()
        }
    }

    @ViewBuilder private var ambient: some View {
        let t = tint ?? theme.accent
        LinearGradient(colors: [t.opacity(0.7), t.opacity(0.25), .clear], startPoint: .top, endPoint: .bottom)
            .frame(height: 1100)
            .allowsHitTesting(false)
    }

    private func refresh() async {
        let rules = contentPrefs.rules
        async let a: () = model.load(addons: store.enabledAddons, rules: rules, pickers: store.pickerIDs, key: addonTaskID.joined(separator: "|"), force: true)
        async let b: () = model.loadSuggestions(last: history.lastWatched, rules: rules, key: suggestionsTaskID, force: true)
        async let c: () = model.loadLists(selected: selectedLists, rules: rules, key: listsTaskID, force: true)
        async let d: () = model.loadUpNext(history.finishedEntries, key: history.finishedSeries.sorted().joined(separator: ","), force: true)
        async let e: () = model.loadThemes(rules: rules, enrichWith: store.enrichmentAddon, key: themesTaskID, force: true)
        _ = await (a, b, c, d, e)
    }
}

// MARK: - Hero

struct HeroCarousel: View {
    let items: [MetaPreview]
    @Binding var tint: Color?
    @Environment(\.horizontalSizeClass) private var hSize
    @Environment(\.pageActive) private var pageActive
    @Environment(\.scenePhase) private var scenePhase
    @State private var page: String?
    @State private var visible = true
    /// True while a finger is on the carousel, so the auto-advance never fights a swipe in progress.
    @State private var dragging = false
    @State private var swipeTick = 0

    private static let interval = 7.0
    private var wide: Bool { hSize == .regular }
    /// On screen, in the foreground, and not a hidden page: auto-advance, the zoom and the progress bar all follow it.
    private var running: Bool { visible && pageActive && scenePhase == .active && !LayoutState.shared.pagesCovered }
    private var height: CGFloat { wide ? 640 : 600 }
    private var currentID: String { page ?? items.first?.id ?? "" }
    private var index: Int { items.firstIndex(where: { $0.id == currentID }) ?? 0 }

    private struct AutoKey: Hashable { let page: String; let visible: Bool; let dragging: Bool }

    var body: some View {
        ScrollView(.horizontal) {
            LazyHStack(spacing: 0) {
                ForEach(items) { item in
                    HeroPage(item: item, active: item.id == currentID && running, wide: wide, height: height)
                        .containerRelativeFrame(.horizontal)
                }
            }
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.paging)
        .scrollPosition(id: $page)
        .scrollIndicators(.hidden)
        .frame(height: height)
        .overlay(alignment: .bottom) {
            if items.count > 1 {
                HeroIndicator(count: items.count, index: index, duration: Self.interval, running: running && !dragging)
                    .padding(.bottom, 12)
            }
        }
        // Haptic only when the user's own swipe settles on a page, not on every automatic advance.
        .onScrollPhaseChange { old, new in
            dragging = new == .interacting
            if old == .decelerating, new == .idle { swipeTick += 1 }
        }
        .sensoryFeedback(.selection, trigger: swipeTick)
        .onAppear { visible = true }
        .onDisappear { visible = false }
        .onChange(of: items.map(\.id)) { _, ids in
            if let p = page, !ids.contains(p) { page = ids.first }
        }
        // Auto-advance. The task restarts on every page change (manual swipes included) and pauses off-screen.
        .task(id: AutoKey(page: currentID, visible: running, dragging: dragging)) {
            guard running, !dragging, items.count > 1 else { return }
            try? await Task.sleep(for: .seconds(Self.interval))
            guard !Task.isCancelled else { return }
            let next = (index + 1) % items.count
            if next == 0 {
                var t = Transaction(); t.disablesAnimations = true     // rewind without streaking through every page
                withTransaction(t) { page = items[0].id }
            } else {
                withAnimation(.easeInOut(duration: 0.9)) { page = items[next].id }
            }
        }
        .task(id: currentID) { await updateTint() }
    }

    @MainActor private func updateTint() async {
        guard let item = items.first(where: { $0.id == currentID }),
              let url = ArtworkRotation.shared.hero(for: item, wide: wide).url,
              let c = await ImagePipeline.shared.averageColor(for: url), !Task.isCancelled else { return }
        withAnimation(.easeInOut(duration: 0.9)) { tint = Color(uiColor: c) }
    }
}

private struct HeroPage: View {
    let item: MetaPreview
    let active: Bool
    let wide: Bool
    let height: CGFloat

    var body: some View {
        NavigationLink(value: item) {
            ZStack(alignment: .bottomLeading) {
                // Slow Ken Burns zoom while this page is showing. The darkening scrim sits on the artwork and both
                // are faded out together along one eased curve, so the art melts into the page background with no
                // visible start line and no hard edge where the hero ends. One static mask, nothing animated.
                ZStack {
                    KenBurns(active: active) {
                        RotatingArtwork(item: item, kind: .hero(wide: wide), size: wide ? 1200 : 800)
                    }
                    LinearGradient.easedFade(start: 0.4, from: 0, to: 0.6)
                }
                .mask { LinearGradient.easedFade(start: 0.42, from: 1, to: 0) }
                info
            }
            .frame(height: height)
            .clipped()
        }
        .buttonStyle(.plain)
    }

    private var info: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Label(item.typeLabel.uppercased(), systemImage: item.type == "series" ? "tv" : "film")
                    .font(.caption2.weight(.heavy)).tracking(1.2)
                    .padding(.horizontal, 9).padding(.vertical, 4)
                    .background(.white.opacity(0.18), in: Capsule())
                if let y = item.year { Text(String(y)).font(.subheadline.weight(.semibold)).opacity(0.9) }
            }
            // Logo when we have one, title text otherwise (text shows first, then swaps once the logo has loaded).
            TitleArt(item: item, maxWidth: 270, maxHeight: 86, font: .system(size: 38, weight: .heavy, design: .rounded))
            InlineRatings(item: item)
            if let d = item.description, !d.isEmpty {
                Text(d).font(.subheadline).lineLimit(2).opacity(0.85)
            }
            // Flat on purpose: live glass over artwork that is moving would be re-sampled every frame.
            Text("Details")
                .font(.subheadline.weight(.semibold)).padding(.horizontal, 18).padding(.vertical, 10)
                .background(.white.opacity(0.2), in: Capsule())
                .overlay(Capsule().strokeBorder(.white.opacity(0.28), lineWidth: 0.5))
                .padding(.top, 2)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 20).padding(.bottom, 46)
        .frame(maxWidth: .infinity, alignment: .leading)
        // Text slides slightly faster than the artwork while paging, and fades out as it leaves.
        .scrollTransition(axis: .horizontal) { content, phase in
            content.opacity(1 - min(abs(phase.value) * 1.6, 1)).offset(x: phase.value * 70)
        }
    }
}

private extension LinearGradient {
    /// Top-to-bottom gradient that holds `from` opacity down to `start` (0...1 of the height), then eases to `to`
    /// at the bottom along a smoothstep curve. A plain two-stop ramp has a visible kink where it begins; the
    /// eased curve starts and ends with zero slope, which is what makes a fade read as seamless.
    static func easedFade(_ color: Color = .black, start: CGFloat, from a: Double, to b: Double, steps: Int = 10) -> LinearGradient {
        var stops: [Gradient.Stop] = [.init(color: color.opacity(a), location: 0)]
        for i in 0...steps {
            let u = Double(i) / Double(steps)
            let eased = u * u * (3 - 2 * u)
            stops.append(.init(color: color.opacity(a + (b - a) * eased), location: start + (1 - start) * CGFloat(u)))
        }
        return LinearGradient(stops: stops, startPoint: .top, endPoint: .bottom)
    }
}

/// Slow zoom on the hero artwork while its page is showing. One long linear animation handed to Core Animation, so
/// the zoom runs on the render server at the display's own rate: no per-frame SwiftUI work (the old 24 Hz timeline
/// re-evaluated the view and re-rasterised the masked artwork on every tick, and stepped visibly). It stops under
/// Reduce Motion and in Low Power Mode. When the page stops being active the zoom is left alone while the page is
/// still sliding out, and only reset once it is off screen, so nothing snaps back mid-swipe.
private struct KenBurns<Content: View>: View {
    let active: Bool
    let content: Content
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var zoomed = false

    init(active: Bool, @ViewBuilder content: () -> Content) {
        self.active = active
        self.content = content()
    }

    private var moving: Bool { active && !reduceMotion && !PowerMode.shared.saving }

    var body: some View {
        content
            .scaleEffect(zoomed ? 1.08 : 1)
            .task(id: moving) {
                if moving {
                    reset()
                    try? await Task.sleep(for: .milliseconds(40))
                    guard !Task.isCancelled else { return }
                    withAnimation(.linear(duration: 9)) { zoomed = true }
                } else {
                    try? await Task.sleep(for: .seconds(1.2))
                    guard !Task.isCancelled else { return }
                    reset()
                }
            }
    }

    private func reset() {
        var t = Transaction(); t.disablesAnimations = true
        withTransaction(t) { zoomed = false }
    }
}

private struct HeroIndicator: View {
    let count: Int
    let index: Int
    let duration: Double
    /// False while the carousel is off screen or being dragged: the fill rests empty instead of lying about progress.
    let running: Bool

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<count, id: \.self) { i in
                let on = i == index
                Capsule().fill(.white.opacity(0.35))
                    .frame(width: on ? 28 : 6, height: 5)
                    .overlay(alignment: .leading) { if on { AutoFill(duration: duration, running: running) } }
                    .animation(.spring(response: 0.4, dampingFraction: 0.8), value: index)
            }
        }
    }
}

/// White fill that sweeps across the active indicator over one auto-advance interval. It restarts from empty every
/// time `running` flips on (returning from a title, finishing a drag), in step with the carousel's own timer.
private struct AutoFill: View {
    let duration: Double
    let running: Bool
    @State private var on = false

    var body: some View {
        Capsule().fill(.white)
            .frame(width: on ? 28 : 0, height: 5)
            .task(id: running) {
                var t = Transaction(); t.disablesAnimations = true
                withTransaction(t) { on = false }
                guard running else { return }
                try? await Task.sleep(for: .milliseconds(30))
                guard !Task.isCancelled else { return }
                withAnimation(.linear(duration: duration)) { on = true }
            }
    }
}

/// Rating pills with brand icons. Uses MDBList (IMDb / Rotten Tomatoes / Metacritic...) when a key is set,
/// and otherwise the rating that came with the title (IMDb from add-ons, TMDB from TMDB).
struct InlineRatings: View {
    let item: MetaPreview
    @State private var extra: [MDBListClient.Rating] = []

    private var chips: [MDBListClient.Rating] {
        if !extra.isEmpty {
            let order = ["IMDb", "Rotten Tomatoes", "RT Audience", "Metacritic", "Letterboxd", "Trakt"]
            return extra.sorted { (order.firstIndex(of: $0.label) ?? 99) < (order.firstIndex(of: $1.label) ?? 99) }
        }
        if let r = item.rating {
            return [MDBListClient.Rating(label: item.ratingLabel, text: String(format: "%.1f", r), score: r)]
        }
        return []
    }

    var body: some View {
        HStack(spacing: 8) {
            ForEach(chips.prefix(3)) { RatingPill(rating: $0) }
        }
        .task(id: item.id) {
            extra = []
            guard MDBListClient.shared.hasKey else { return }
            var imdb: String? = item.id.hasPrefix("tt") ? item.id : nil
            if imdb == nil, item.id.hasPrefix("tmdb:"), let n = Int(item.id.dropFirst(5)), TMDBClient.shared.hasKey {
                imdb = await TMDBClient.shared.imdbID(tmdb: n, type: item.type)
            }
            guard let imdb else { return }
            extra = await MDBListClient.shared.ratings(imdb: imdb, type: item.type)
        }
    }
}

// MARK: - Continue Watching

/// One carousel holds both in-progress titles and the next episode of finished ones, most recent first.
struct ContinueRow: View {
    let entries: [WatchHistory.Entry]
    let upNext: [UpNextItem]
    @Environment(ThemeStore.self) private var theme

    private enum Card: Identifiable {
        case resume(WatchHistory.Entry)
        case next(UpNextItem)
        var id: String {
            switch self {
            case .resume(let e): return "r-\(e.id)"
            case .next(let n): return "n-\(n.id)"
            }
        }
        var date: Date {
            switch self {
            case .resume(let e): return e.updated
            case .next(let n): return n.updated
            }
        }
    }

    private var cards: [Card] {
        (entries.map(Card.resume) + upNext.map(Card.next)).sorted { $0.date > $1.date }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "play.circle.fill").font(.system(size: 15, weight: .bold)).foregroundStyle(theme.accent2)
                Text("Continue Watching").font(.title3.bold())
            }
            .padding(.horizontal, 16)
            ScrollView(.horizontal) {
                LazyHStack(spacing: 14) {
                    ForEach(cards) { card in
                        switch card {
                        case .resume(let e): ContinueCard(entry: e)
                        case .next(let n): UpNextCard(entry: n)
                        }
                    }
                }
                .scrollTargetLayout()
            }
            .contentMargins(.horizontal, 16, for: .scrollContent)
            .scrollTargetBehavior(.viewAligned)
            .scrollIndicators(.hidden)
        }
    }
}

/// 16:9 card: episode still (or movie backdrop), where you stopped, and how much is left.
private struct ContinueCard: View {
    let entry: WatchHistory.Entry
    @Environment(WatchHistory.self) private var history
    @Environment(ThemeStore.self) private var theme
    private let width: CGFloat = 270

    private var thumb: URL? {
        entry.thumb.flatMap(URL.init(string:)) ?? entry.item.backdropURL ?? entry.item.posterURL
    }

    private var subtitle: String {
        let left = Fmt.remaining(entry.duration - entry.position)
        if let se = entry.seasonEpisode { return "S\(se.season) · E\(se.episode) · \(left)" }
        return left
    }

    var body: some View {
        NavigationLink(value: ResumeTarget(item: entry.item, season: entry.seasonEpisode?.season, episode: entry.seasonEpisode?.episode)) {
            VStack(alignment: .leading, spacing: 8) {
                Color.clear
                    .aspectRatio(16.0 / 9.0, contentMode: .fit)
                    .frame(width: width)
                    .overlay { StillImage(url: thumb, size: width) }
                    .overlay { LinearGradient(colors: [.clear, .black.opacity(0.5)], startPoint: .center, endPoint: .bottom) }
                    .overlay(alignment: .topTrailing) {
                        Text(Fmt.clock(entry.position)).font(.system(size: 11, weight: .bold)).monospacedDigit()
                            .foregroundStyle(.white).padding(.horizontal, 7).padding(.vertical, 3)
                            .background(.black.opacity(0.62), in: Capsule()).padding(8)
                    }
                    .overlay(alignment: .bottom) { progressBar }
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.item.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                .frame(width: width, alignment: .leading)
            }
        }
        .buttonStyle(PressableStyle())
        .contextMenu {
            Button("Remove from Continue Watching", systemImage: "xmark.circle", role: .destructive) {
                withAnimation { history.remove(entry.id) }
            }
            Divider()
            PosterContextMenu(item: entry.item, artwork: false)
        }
    }

    private var progressBar: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Rectangle().fill(.white.opacity(0.3))
                Rectangle().fill(theme.gradient).frame(width: g.size.width * entry.progress)
            }
        }
        .frame(height: 4)
    }
}

// MARK: - Up Next

private struct UpNextCard: View {
    let entry: UpNextItem
    @Environment(WatchHistory.self) private var history
    @Environment(ThemeStore.self) private var theme
    private let width: CGFloat = 270

    var body: some View {
        NavigationLink(value: ResumeTarget(item: entry.item, season: entry.season, episode: entry.episode)) {
            VStack(alignment: .leading, spacing: 8) {
                Color.clear
                    .aspectRatio(16.0 / 9.0, contentMode: .fit)
                    .frame(width: width)
                    .overlay { StillImage(url: entry.thumb, size: width) }
                    .overlay { LinearGradient(colors: [.clear, .black.opacity(0.5)], startPoint: .center, endPoint: .bottom) }
                    .overlay(alignment: .topLeading) {
                        Text("UP NEXT").font(.system(size: 10, weight: .heavy)).tracking(0.8).foregroundStyle(theme.onAccent)
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(theme.accent, in: Capsule()).padding(8)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.item.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                    Text("S\(entry.season) · E\(entry.episode) · \(entry.title)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                .frame(width: width, alignment: .leading)
            }
        }
        .buttonStyle(PressableStyle())
        .contextMenu {
            Button("Remove from Continue Watching", systemImage: "xmark.circle", role: .destructive) {
                withAnimation { history.dismissUpNext(entry.item.id) }
            }
            Divider()
            PosterContextMenu(item: entry.item, artwork: false)
        }
    }
}

// MARK: - Rows + posters

struct CatalogRowView: View {
    let row: CatalogRow
    @Environment(ThemeStore.self) private var theme
    @Environment(\.wideLayout) private var wide
    /// Bigger posters in the sidebar layout.
    private var posterWidth: CGFloat { wide ? 140 : 102 }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Tapping the title opens the full list for this row.
            NavigationLink(value: row) {
                HStack(spacing: 8) {
                    if let s = row.symbol {
                        Image(systemName: s).font(.system(size: 15, weight: .bold)).foregroundStyle(row.accent(theme))
                    }
                    Text(row.title).font(.title3.bold())
                    Image(systemName: "chevron.right").font(.footnote.weight(.bold)).foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain).padding(.horizontal, 16)
            .modifier(HideRowMenu(key: row.prefKey))
            ScrollView(.horizontal) {
                LazyHStack(spacing: 12) {
                    ForEach(row.items) { item in
                        PosterCard(item: item, width: posterWidth)
                    }
                    NavigationLink(value: row) {
                        VStack(spacing: 8) {
                            Image(systemName: "arrow.right.circle").font(.title)
                            Text("See all").font(.footnote.weight(.semibold))
                        }
                        .foregroundStyle(.secondary).frame(width: 78, height: posterWidth * 1.5)   // matches the poster height
                    }
                    .buttonStyle(.plain)
                }
                .scrollTargetLayout()
            }
            .contentMargins(.horizontal, 16, for: .scrollContent)
            .scrollTargetBehavior(.viewAligned)
            .scrollIndicators(.hidden)
        }
    }
}

/// Long-press a row title: "Hide this row" (or "Remove from Home" for a catalogue the user added from AIOMetadata).
/// Only rows that have a stable key (add-on catalogues, trending...) offer it; Settings -> Content & catalogues
/// brings them back.
private struct HideRowMenu: ViewModifier {
    let key: String?
    @Environment(ContentPrefs.self) private var prefs

    @ViewBuilder func body(content: Content) -> some View {
        if let key {
            let added = prefs.rules.isRowAdded(key)
            content.contextMenu {
                Button(added ? "Remove from Home" : "Hide this row", systemImage: added ? "minus.circle" : "eye.slash") {
                    withAnimation { prefs.setRowHidden(key, true) }
                }
            }
        } else {
            content
        }
    }
}

/// Springy press feedback for tappable cards.
struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

/// Poster with a rating chip and an optional network icon (shows only). `width: nil` fills its grid column.
/// `showsTitle` adds the title and year underneath (grids and search).
/// Tap opens the detail page; long tap shows the actions dropdown (watched / library / details).
struct PosterCard: View {
    let item: MetaPreview
    var width: CGFloat? = 102         // was 87; the original 130 was too big, 87 a bit too small
    var showsTitle = false
    @Environment(WatchHistory.self) private var history
    @Environment(ThemeStore.self) private var theme
    @AppStorage("ui.networkBadges") private var showNetwork = true
    @State private var network: TMDBClient.NetworkBadge?

    /// Small row posters get slightly smaller badges so they don't cover the artwork.
    private var compact: Bool { (width ?? 130) < 115 }

    private var caption: String {
        [item.year.map(String.init), item.typeLabel].compactMap { $0 }.joined(separator: " · ")
    }

    var body: some View {
        poster
            .frame(width: width, alignment: .topLeading)
            // Visible cards only (LazyHStack/LazyVGrid); cancelled when scrolled away, cached afterwards.
            .task(id: item.id) {
                network = nil
                guard showNetwork, item.type == "series", TMDBClient.shared.hasKey else { return }
                network = await TMDBClient.shared.network(for: item.id, type: item.type)
            }
            // Long tap: dropdown with mark as watched / add to library / details.
            .posterContextMenu(item)
    }

    /// Checkmark shown over posters of titles marked as watched.
    @ViewBuilder private var watchedBadge: some View {
        if history.entry(for: item.id)?.isTitleWatched == true {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: compact ? 14 : 17, weight: .bold))
                .foregroundStyle(theme.onAccent, theme.accent)
                .padding(compact ? 4 : 6)
                .accessibilityLabel("Watched")
        }
    }

    private var poster: some View {
        NavigationLink(value: item) {
            VStack(alignment: .leading, spacing: 7) {
                RotatingArtwork(item: item, kind: .poster, size: (width ?? 120) * 1.5)
                    .aspectRatio(2.0 / 3.0, contentMode: .fit)
                    .frame(width: width)
                    .clipShape(RoundedRectangle(cornerRadius: compact ? 9 : 12, style: .continuous))
                    .overlay(alignment: .topLeading) { watchedBadge }
                    .overlay(alignment: .topLeading) {
                        if let logo = network?.logo {
                            LogoImage(url: logo)
                                .frame(maxWidth: compact ? 24 : 34, maxHeight: compact ? 10 : 14)
                                .padding(.horizontal, compact ? 4 : 6).padding(.vertical, compact ? 3 : 5)
                                .background(.white.opacity(0.92), in: RoundedRectangle(cornerRadius: compact ? 6 : 8, style: .continuous))
                                .padding(compact ? 4 : 6)
                                .accessibilityLabel(network?.name ?? "")
                        }
                    }
                if showsTitle {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.name).font(.footnote.weight(.semibold))
                            .lineLimit(2, reservesSpace: true).multilineTextAlignment(.leading)
                        Text(caption).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .buttonStyle(PressableStyle())
    }
}
