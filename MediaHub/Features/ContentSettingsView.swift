import SwiftUI

/// Settings -> Content & catalogues: what shows up on Home, Explore and in recommendations.
/// Saved per profile, so a kids' profile can hide what an adult's doesn't.
struct ContentSettingsView: View {
    @Environment(ContentPrefs.self) private var prefs
    @Environment(AddonStore.self) private var store
    @Environment(ProfileStore.self) private var profiles
    @Environment(SimklStore.self) private var simkl
    @AppStorage("tmdb.key") private var tmdbKey = ""

    private var rules: ContentRules { prefs.rules }
    private var hidesAnimation: Bool { rules.hiddenCategories.contains(.anime) || rules.hiddenCategories.contains(.cartoons) }
    /// Add-ons whose catalogues all show on Home unless switched off. Add-ons with a catalogue picker (AIOMetadata)
    /// have their own screen, because their catalogue list is long and starts empty.
    private var catalogAddons: [Addon] { store.addons.filter { !$0.homeCatalogs.isEmpty && !store.usesCatalogPicker($0) } }
    private var pickerAddons: [Addon] { store.addons.filter { store.usesCatalogPicker($0) } }
    private var addedCount: Int {
        pickerAddons.reduce(0) { total, a in
            total + a.homeCatalogs.filter { rules.isRowAdded(ContentRules.rowKey(a, $0)) }.count
        }
    }

    var body: some View {
        Form {
            Section {
                ForEach(ContentCategory.regions) { categoryToggle($0) }
            } header: {
                Text("Where it's from · \(simkl.name(for: profiles.active))")
            } footer: {
                Text(regionFooter)
            }

            Section {
                ForEach(ContentCategory.kinds) { categoryToggle($0) }
            } header: {
                Text("Kinds of titles")
            } footer: {
                Text(categoryFooter)
            }

            Section {
                rowToggle("Trending Movies", key: ContentRules.Builtin.trendingMovies, symbol: "flame.fill")
                rowToggle("Trending Shows", key: ContentRules.Builtin.trendingShows, symbol: "flame.fill")
                rowToggle("Because you watched", key: ContentRules.Builtin.because, symbol: "sparkles")
                rowToggle("Themed collections", key: ContentRules.Builtin.themes, symbol: "square.stack.fill")
            } header: {
                Text("Home rows")
            } footer: {
                Text("You can also touch and hold a row's title on Home and choose Hide this row.")
            }

            Section {
                NavigationLink { AIOMetadataSettingsView() } label: {
                    HStack {
                        Label("AIOMetadata catalogues", systemImage: "square.grid.2x2.fill")
                        Spacer()
                        Text(pickerSummary).font(.footnote).foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("AIOMetadata")
            } footer: {
                Text("Pick which AIOMetadata catalogues get a row on Home. None show until you add them.")
            }

            ForEach(catalogAddons) { addon in
                Section {
                    ForEach(addon.homeCatalogs, id: \.self) { cat in
                        rowToggle(catalogTitle(cat), key: ContentRules.rowKey(addon, cat), symbol: "film.stack")
                    }
                } header: {
                    Text(store.isEnabled(addon) ? addon.manifest.name : "\(addon.manifest.name) (add-on is off)")
                } footer: {
                    if addon.id == catalogAddons.last?.id {
                        Text("Catalogues come from your add-ons. Switching one off here hides its row; the add-on itself stays installed.")
                    }
                }
            }

            Section {
                Toggle("Also filter search results", isOn: Binding(
                    get: { rules.filterSearch }, set: { prefs.setFilterSearch($0) }))
            } header: {
                Text("Search")
            } footer: {
                Text("Off by default: a search names exactly what you're after. Turn it on to apply the categories above to search too. Titles you added yourself (Continue Watching, your library) are never hidden.")
            }

            Section {
                Button("Show everything again", role: .destructive) { prefs.reset() }
                    .disabled(!rules.hidesAnything)
            }
        }
        .navigationTitle("Content & catalogues")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: Pieces

    private var pickerSummary: String {
        if pickerAddons.isEmpty { return "Not set up" }
        return addedCount == 0 ? "None on Home" : "\(addedCount) on Home"
    }

    private var categoryFooter: String {
        var text = "Hidden titles are removed from Home, Explore, recommendations and themed collections."
        if hidesAnimation && tmdbKey.isEmpty && !TMDBClient.hasProxy {
            text += " Without a TMDB key (Settings → Integrations) anime and cartoons can't be told apart, so all animation is hidden while either is off."
        }
        return text
    }

    private func categoryToggle(_ c: ContentCategory) -> some View {
        Toggle(isOn: shown(c)) {
            VStack(alignment: .leading, spacing: 3) {
                Label(c.title, systemImage: c.symbol)
                Text(c.detail).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var regionFooter: String {
        var text = "Switch off the regions you don't want suggested. They only affect live-action: anime and cartoons are handled below. English-language titles are never hidden by these."
        if rules.hidesRegions && tmdbKey.isEmpty && !TMDBClient.hasProxy {
            text += " Add a TMDB key (Settings → Integrations): without one, titles from add-on catalogues can't be placed, so only TMDB-sourced rows are filtered."
        }
        return text
    }

    private func shown(_ c: ContentCategory) -> Binding<Bool> {
        Binding(get: { !rules.hiddenCategories.contains(c) }, set: { prefs.setHidden(c, !$0) })
    }

    private func rowToggle(_ title: String, key: String, symbol: String) -> some View {
        Toggle(isOn: Binding(get: { !rules.isRowHidden(key) }, set: { prefs.setRowHidden(key, !$0) })) {
            Label(title, systemImage: symbol)
        }
    }

    private func catalogTitle(_ cat: AddonManifest.CatalogDef) -> String {
        let kind = cat.type == "movie" ? "Movies" : cat.type == "series" ? "Series" : cat.type.capitalized
        return "\(cat.name ?? cat.id) · \(kind)"
    }
}
