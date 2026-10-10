import SwiftUI

@MainActor @Observable
final class SearchModel {
    private(set) var results: [MetaPreview] = []
    private(set) var isSearching = false
    private(set) var hasSearched = false

    var movies: [MetaPreview] { results.filter { $0.type == "movie" } }
    var shows: [MetaPreview] { results.filter { $0.type == "series" } }

    func reset() { results = []; isSearching = false; hasSearched = false }

    /// Add-ons that declare `search` come first (they carry IMDb ids), then TMDB fills the gaps.
    func run(_ raw: String, addons: [Addon], rules: ContentRules = .none) async {
        let q = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard q.count >= 2 else { reset(); return }
        isSearching = true

        var jobs: [(Addon, AddonManifest.CatalogDef)] = []
        for a in addons { for c in a.manifest.catalogs ?? [] where c.isSearchable { jobs.append((a, c)) } }
        jobs = Array(jobs.prefix(6))
        // TMDB doesn't wait for the add-ons: it starts now and the two finish in parallel.
        async let tmdbResults = TMDBClient.shared.search(q)
        var byIndex: [Int: [MetaPreview]] = [:]
        await withTaskGroup(of: (Int, [MetaPreview]).self) { group in
            for (i, job) in jobs.enumerated() {
                group.addTask {
                    let items = (try? await AddonClient.shared.catalog(addon: job.0, catalog: job.1, search: q)) ?? []
                    return (i, items)
                }
            }
            for await (i, items) in group { byIndex[i] = items }
        }
        let tmdb = await tmdbResults
        guard !Task.isCancelled else { return }

        var out: [MetaPreview] = []
        var ids = Set<String>()
        var byName: [String: Int] = [:]
        func add(_ m: MetaPreview) {
            guard m.type == "movie" || m.type == "series" else { return }
            let nameKey = m.name.lowercased() + "|" + (m.year.map(String.init) ?? "")
            if let i = byName[nameKey] {
                // Same title from another source: keep the first, but borrow its rating if ours is missing.
                if out[i].rating == nil, let r = m.rating { out[i] = out[i].with(rating: r) }
                return
            }
            guard ids.insert(m.id).inserted else { return }
            byName[nameKey] = out.count
            out.append(m)
        }
        for i in jobs.indices { (byIndex[i] ?? []).forEach(add) }
        tmdb.forEach(add)
        // Only when the user asked for it: a search names exactly what they want, so it is unfiltered by default.
        if rules.filterSearch { out = await TitleClassifier.shared.filter(out, rules: rules) }
        guard !Task.isCancelled else { return }
        results = out
        hasSearched = true
        isSearching = false
    }
}

struct SearchView: View {
    @Environment(AddonStore.self) private var store
    @Environment(ContentPrefs.self) private var contentPrefs
    @State private var query = ""
    @State private var scope: Scope = .all
    @State private var model = SearchModel()
    private let columns = [GridItem(.adaptive(minimum: 104, maximum: 160), spacing: 12, alignment: .top)]

    enum Scope: String, CaseIterable, Identifiable {
        case all = "All", movies = "Movies", shows = "Shows"
        var id: String { rawValue }
    }

    private var showMovies: Bool { scope != .shows && !model.movies.isEmpty }
    private var showShows: Bool { scope != .movies && !model.shows.isEmpty }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 26) {
                    if showMovies { section("Movies", symbol: "film", items: model.movies) }
                    if showShows { section("Shows", symbol: "tv", items: model.shows) }
                }
                .padding(.top, 8).padding(.bottom, 30)
                .animation(.smooth(duration: 0.3), value: model.results.count)
            }
            .scrollDismissesKeyboard(.interactively)
            .overlay {
                if query.trimmingCharacters(in: .whitespaces).count < 2 {
                    ContentUnavailableView("Search", systemImage: "magnifyingglass",
                        description: Text("Find movies and shows across your add-ons and TMDB."))
                } else if !showMovies && !showShows {
                    if model.hasSearched && !model.isSearching { ContentUnavailableView.search(text: query) }
                    else { ProgressView() }
                }
            }
            .navigationTitle("Search")
            .profileToolbar()
            .navigationDestination(for: MetaPreview.self) { DetailView(item: $0) }
            .navigationDestination(for: CatalogRow.self) { CatalogGridView(row: $0) }
        }
        .searchable(text: $query, prompt: "Movies and shows")
        .searchScopes($scope) {
            ForEach(Scope.allCases) { Text($0.rawValue).tag($0) }
        }
        .task(id: query + "|" + (contentPrefs.rules.filterSearch ? contentPrefs.rules.categoryKey : "")) {
            // Debounce: only the last keystroke in a 350 ms window hits the network.
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            await model.run(query, addons: store.enabledAddons, rules: contentPrefs.rules)
        }
    }

    private func section(_ title: String, symbol: String, items: [MetaPreview]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: symbol).font(.system(size: 15, weight: .bold)).foregroundStyle(.tint)
                Text(title).font(.title3.bold())
                Text("\(items.count)").font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            LazyVGrid(columns: columns, spacing: 18) {
                ForEach(items) { PosterCard(item: $0, width: nil, showsTitle: true) }
            }
            .padding(.horizontal, 16)
        }
    }
}
