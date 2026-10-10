import SwiftUI

@MainActor @Observable
final class ExploreModel {
    private(set) var kind = "movie"            // TMDB kind: "movie" | "tv"
    private(set) var genre: Int?
    private(set) var year: Int?
    private(set) var sort: DiscoverSort = .popular
    private(set) var items: [MetaPreview] = []
    private(set) var genres: [TMDBClient.Genre] = []
    private(set) var isLoading = false
    private(set) var hasMore = true
    private(set) var themes: [ThemeRow] = []
    private(set) var rules = ContentRules.none
    private var page = 0
    private var generation = 0
    /// What the last theme load finished with, so coming back to the tab doesn't refetch and rebuild the rows.
    @ObservationIgnored private var themesLoaded: (key: String, at: Date)?
    @ObservationIgnored private var pendingThemes: [ThemeRow]?

    /// No filters: show what's trending this week.
    var isTrending: Bool { genre == nil && year == nil && sort == .popular }
    var hasFilters: Bool { genre != nil || year != nil || sort != .popular }

    func setKind(_ k: String) async {
        guard k != kind else { return }
        kind = k; genre = nil                  // genre ids differ between movies and shows
        genres = []
        async let g: () = loadGenres()
        await reload()
        await g
    }
    func setGenre(_ g: Int?) async { guard g != genre else { return }; genre = g; await reload() }
    func setYear(_ y: Int?) async { guard y != year else { return }; year = y; await reload() }
    func setSort(_ s: DiscoverSort) async { guard s != sort else { return }; sort = s; await reload() }
    func clearFilters() async { genre = nil; year = nil; sort = .popular; await reload() }

    /// Genre chips, minus the ones that could only lead to hidden titles.
    var visibleGenres: [TMDBClient.Genre] { genres.filter { !rules.hidesGenre($0.id) } }

    /// Applies the user's content rules. Reloads when the hidden categories changed, or when nothing has loaded yet.
    func use(_ new: ContentRules) async {
        let changed = new.categoryKey != rules.categoryKey
        rules = new
        if let g = genre, new.hidesGenre(g) { genre = nil }
        if changed || items.isEmpty { await reload() }
    }

    /// Themed rows (the ones after Home's candidates), shown above the grid while no filter is active. One more theme
    /// than shown is loaded, because the Movies / Shows tabs each drop a theme that is mostly the other kind.
    ///
    /// The tab's loading task restarts every time the tab comes back on screen. Rows that are already showing and recent
    /// are left alone, and a refresh swaps the finished set in once, so the rows never shrink and re-grow under the
    /// user's finger as each theme lands. Pull-to-refresh forces a reload.
    func loadThemes(rules: ContentRules, enrichWith addon: Addon?, key: String = "", force: Bool = false) async {
        if !force, !themes.isEmpty, let l = themesLoaded, l.key == key,
           Date().timeIntervalSince(l.at) < 15 * 60 { return }
        let progressive = themes.isEmpty
        pendingThemes = nil
        await ThemeCatalog.load(count: ThemeCatalog.exploreCandidates, offset: ThemeCatalog.homeCandidates, limit: 16,
                                rules: rules, enrichWith: addon) { [weak self] rows in
            guard let self else { return }
            self.pendingThemes = rows
            if progressive { self.themes = rows }
        }
        guard !Task.isCancelled, let latest = pendingThemes else { return }
        themes = latest
        if !latest.isEmpty { themesLoaded = (key, Date()) }
    }
    /// Movies tab shows movie rows, Shows tab shows series rows.
    var themeRows: [ThemeRow] {
        let type = kind == "tv" ? "series" : "movie"
        return Array(themes.compactMap { $0.filtered(type: type) }.prefix(ThemeCatalog.exploreRows))
    }

    func loadGenres() async {
        let k = kind
        let list = await TMDBClient.shared.genres(k)
        if k == kind { genres = list }
    }

    func reload() async {
        generation += 1
        items = []; page = 0; hasMore = true; isLoading = false
        await loadMore()
    }

    func loadMore() async {
        guard hasMore, !isLoading, TMDBClient.shared.hasKey else { return }
        let gen = generation
        isLoading = true
        defer { if gen == generation { isLoading = false } }
        // A page the content filter empties would add nothing, and the scroll trigger only fires when the item count
        // changes, so keep fetching (a few pages at most) until something is added.
        var added = 0, attempts = 0
        while added < 12, attempts < 4, hasMore {
            attempts += 1
            let next = page + 1
            let raw: [MetaPreview]
            if isTrending { raw = (try? await TMDBClient.shared.trending(kind, page: next)) ?? [] }
            else { raw = (try? await TMDBClient.shared.discover(kind: kind, genre: genre, year: year, sort: sort, page: next, rules: rules)) ?? [] }
            guard gen == generation else { return }          // filters changed while this page was loading
            page = next
            hasMore = !raw.isEmpty && page < 40
            let kept = await TitleClassifier.shared.filter(raw, rules: rules)
            guard gen == generation else { return }
            let known = Set(items.map(\.id))
            let fresh = kept.filter { !known.contains($0.id) }
            items += fresh
            added += fresh.count
        }
    }
}

struct ExploreView: View {
    @Environment(ThemeStore.self) private var theme
    @Environment(ContentPrefs.self) private var contentPrefs
    @Environment(AddonStore.self) private var store
    @State private var model = ExploreModel()
    @AppStorage("tmdb.key") private var tmdbKey = ""
    private let columns = [GridItem(.adaptive(minimum: 104, maximum: 160), spacing: 12, alignment: .top)]
    private let years: [Int] = {
        let now = Calendar.current.component(.year, from: .now)
        return Array((1950...(now + 1)).reversed())
    }()

    var body: some View {
        NavigationStack {
            Group {
                if tmdbKey.isEmpty && !TMDBClient.hasProxy {
                    ContentUnavailableView("Explore needs TMDB", systemImage: "safari",
                        description: Text("Add a free TMDB API key in Settings → Integrations to browse trending titles and filter by genre and year."))
                } else { content }
            }
            .navigationTitle("Explore")
            .profileToolbar()
            .navigationDestination(for: MetaPreview.self) { DetailView(item: $0) }
            .navigationDestination(for: CatalogRow.self) { CatalogGridView(row: $0) }
        }
        .task(id: themesTaskID) {
            guard !tmdbKey.isEmpty || TMDBClient.hasProxy else { return }
            let rules = contentPrefs.rules
            async let g: () = model.loadGenres()
            async let t: () = model.loadThemes(rules: rules, enrichWith: store.enrichmentAddon, key: themesTaskID)
            await model.use(rules)
            _ = await (g, t)
        }
    }

    /// Reloads when the key, the content filter, the themes switch or the enrichment add-on changes. Built as typed
    /// Strings: a long `+` chain in the modifier list can make the compiler give up.
    private var themesTaskID: String {
        let off: String = contentPrefs.rules.isRowHidden(ContentRules.Builtin.themes) ? "|off" : ""
        let aio: String = store.enrichmentAddon?.id ?? ""
        return tmdbKey + "|" + contentPrefs.rules.categoryKey + off + "|" + aio
    }

    private var content: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                filters
                if !model.hasFilters && !model.themeRows.isEmpty {
                    VStack(alignment: .leading, spacing: 26) {
                        ForEach(model.themeRows) { ThemeCarousel(row: $0) }
                    }
                    .padding(.bottom, 10)
                }
                HStack(spacing: 8) {
                    Image(systemName: model.isTrending ? "flame.fill" : "line.3.horizontal.decrease.circle.fill")
                        .foregroundStyle(model.isTrending ? .orange : Color.accentColor)
                    Text(heading).font(.title3.bold())
                }
                .padding(.horizontal, 16)

                LazyVGrid(columns: columns, spacing: 18) {
                    ForEach(model.items) { PosterCard(item: $0, width: nil, showsTitle: true) }
                }
                .padding(.horizontal, 16)
                .animation(.smooth(duration: 0.3), value: model.items.count)

                Color.clear.frame(height: 1).task(id: model.items.count) { await model.loadMore() }
                if model.isLoading { ProgressView().frame(maxWidth: .infinity).padding(24) }
                else if model.items.isEmpty && !model.hasMore {
                    ContentUnavailableView("Nothing found", systemImage: "film.stack",
                        description: Text("Try a different genre or year."))
                }
            }
            .padding(.vertical, 8)
        }
        .scrollIndicators(.hidden)
        .refreshable {
            async let t: () = model.loadThemes(rules: contentPrefs.rules, enrichWith: store.enrichmentAddon,
                                               key: themesTaskID, force: true)
            await model.reload()
            await t
        }
    }

    private var heading: String {
        let noun = model.kind == "tv" ? "Shows" : "Movies"
        if model.isTrending { return "Trending \(noun)" }
        var parts: [String] = []
        if let g = model.genres.first(where: { $0.id == model.genre }) { parts.append(g.name) }
        if let y = model.year { parts.append(String(y)) }
        parts.append(noun)
        return parts.joined(separator: " · ")
    }

    // MARK: Filters

    private var filters: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Type", selection: Binding(get: { model.kind }, set: { k in Task { await model.setKind(k) } })) {
                Text("Movies").tag("movie"); Text("Shows").tag("tv")
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)

            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    chip("All genres", on: model.genre == nil) { Task { await model.setGenre(nil) } }
                    ForEach(model.visibleGenres) { g in
                        chip(g.name, on: model.genre == g.id) { Task { await model.setGenre(g.id) } }
                    }
                }
                .padding(.horizontal, 16)
            }
            .scrollIndicators(.hidden)

            HStack(spacing: 10) {
                Menu {
                    Picker("Year", selection: Binding(get: { model.year ?? 0 }, set: { y in Task { await model.setYear(y == 0 ? nil : y) } })) {
                        Text("Any year").tag(0)
                        ForEach(years, id: \.self) { Text(String($0)).tag($0) }
                    }
                } label: {
                    menuLabel(model.year.map(String.init) ?? "Any year", symbol: "calendar", on: model.year != nil)
                }
                Menu {
                    Picker("Sort", selection: Binding(get: { model.sort }, set: { s in Task { await model.setSort(s) } })) {
                        ForEach(DiscoverSort.allCases) { Text($0.rawValue).tag($0) }
                    }
                } label: {
                    menuLabel(model.sort.rawValue, symbol: "arrow.up.arrow.down", on: model.sort != .popular)
                }
                if model.hasFilters {
                    Button { Task { await model.clearFilters() } } label: {
                        Label("Reset", systemImage: "xmark.circle.fill").font(.footnote.weight(.semibold))
                    }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 16)
        }
    }

    private func chip(_ title: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.footnote.weight(.semibold))
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(on ? Color.accentColor : Color.white.opacity(0.1), in: Capsule())
                .foregroundStyle(on ? theme.onAccent : Color.primary)
        }
        .buttonStyle(PressableStyle())
        .animation(.snappy(duration: 0.2), value: on)
    }

    private func menuLabel(_ title: String, symbol: String, on: Bool) -> some View {
        Label(title, systemImage: symbol)
            .font(.footnote.weight(.semibold))
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(on ? Color.accentColor.opacity(0.25) : Color.white.opacity(0.1), in: Capsule())
            .foregroundStyle(on ? Color.accentColor : Color.primary)
    }
}
