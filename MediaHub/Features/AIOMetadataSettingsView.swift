import SwiftUI

/// Settings -> Content & catalogues -> AIOMetadata: choose which of the add-on's catalogues get a row on Home.
///
/// An AIOMetadata add-on can offer dozens of catalogues (TMDB, TVDB, MDBList, MAL, streaming services...), so unlike
/// other add-ons nothing is shown until it is added here. The choice is saved per profile (`ContentRules.addedRows`).
struct AIOMetadataSettingsView: View {
    @Environment(AddonStore.self) private var store
    @Environment(ContentPrefs.self) private var prefs
    @Environment(ProfileStore.self) private var profiles
    @Environment(SimklStore.self) private var simkl
    @Environment(\.openURL) private var openURL
    @State private var query = ""
    @State private var urlText = ""
    @State private var busy = false
    @State private var error: String?
    @State private var note: String?
    @State private var addNote: String?
    @State private var reloading = Set<String>()

    private var rules: ContentRules { prefs.rules }
    private var pickerAddons: [Addon] { store.addons.filter { store.usesCatalogPicker($0) } }
    /// Installed add-ons that aren't recognised as AIOMetadata but could be treated like it (a self-hosted copy).
    private var otherAddons: [Addon] { store.addons.filter { !$0.homeCatalogs.isEmpty && !$0.isAIOMetadata } }

    var body: some View {
        List {
            if pickerAddons.isEmpty { setup }
            ForEach(pickerAddons) { addon in manage(addon) }
            if !pickerAddons.isEmpty { catalogSections }
            if !otherAddons.isEmpty { manualSection }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("AIOMetadata")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .automatic), prompt: "Search catalogues")
        .scrollDismissesKeyboard(.interactively)
    }

    // MARK: No add-on yet

    private var setup: some View {
        Section {
            TextField("AIOMetadata add-on URL", text: $urlText)
                .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
            Button(busy ? "Adding…" : "Add AIOMetadata") { add() }
                .disabled(urlText.isEmpty || busy)
        } header: {
            Text("Add AIOMetadata")
        } footer: {
            if let error { Text(error).foregroundStyle(.red) }
            else if let addNote { Text(addNote) }
            else {
                Text("Open your AIOMetadata page, choose the catalogues you want it to offer, then paste the add-on link it gives you (https:// or stremio://). You then pick which of them appear on Home.")
            }
        }
    }

    // MARK: Per add-on

    /// Reload / configure, and a way to take everything off Home at once.
    private func manage(_ addon: Addon) -> some View {
        let keys = addon.homeCatalogs.map { ContentRules.rowKey(addon, $0) }
        let on = keys.filter { rules.isRowAdded($0) }.count
        return Section {
            Button { reload(addon) } label: {
                HStack {
                    Label("Reload catalogues", systemImage: "arrow.clockwise")
                    if reloading.contains(addon.id) { Spacer(); ProgressView() }
                }
            }
            .disabled(reloading.contains(addon.id))
            Button { openURL(addon.configureURL) } label: {
                Label("Open setup page", systemImage: "gearshape")
            }
            Button("Remove all from Home", role: .destructive) { prefs.setRowsAdded(keys, false) }
                .disabled(on == 0)
        } header: {
            Text(header(for: addon, on: on))
        } footer: {
            if let note { Text(note) }
            else if addon.homeCatalogs.isEmpty {
                Text("This add-on offers no catalogues that can sit on Home. Add some on its setup page, then reload.")
            } else {
                Text("Catalogues are set up on the add-on's own page. After changing them there, copy the new add-on link, add it in Settings → Add-ons and remove the old one, or just reload if the link didn't change.")
            }
        }
    }

    private func header(for addon: Addon, on: Int) -> String {
        var s = addon.manifest.name
        if !store.isEnabled(addon) { s += " (add-on is off)" }
        return s + " · \(on) on Home · \(simkl.name(for: profiles.active))"
    }

    // MARK: Catalogues

    private struct CatalogGroup: Identifiable {
        let addon: Addon
        let type: String
        let catalogs: [AddonManifest.CatalogDef]
        var id: String { addon.id + "|" + type }
    }

    /// One section per add-on and content type (Movies, Series...), filtered by the search text.
    private var groups: [CatalogGroup] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var out: [CatalogGroup] = []
        for addon in pickerAddons {
            let matching = addon.homeCatalogs.filter {
                q.isEmpty || ($0.name ?? $0.id).lowercased().contains(q) || $0.id.lowercased().contains(q)
            }
            var types: [String] = []
            for c in matching where !types.contains(c.type) { types.append(c.type) }
            for t in types { out.append(CatalogGroup(addon: addon, type: t, catalogs: matching.filter { $0.type == t })) }
        }
        return out
    }

    @ViewBuilder private var catalogSections: some View {
        let shown = groups
        ForEach(shown) { g in
            Section {
                ForEach(g.catalogs, id: \.self) { cat in
                    let key = ContentRules.rowKey(g.addon, cat)
                    Toggle(isOn: Binding(get: { rules.isRowAdded(key) }, set: { prefs.setRowAdded(key, $0) })) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(cat.name ?? cat.id)
                            Text(cat.id).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                        }
                    }
                }
            } header: {
                Text("\(g.addon.manifest.name) · \(Self.kind(g.type))")
            }
        }
        if shown.isEmpty && !query.isEmpty {
            ContentUnavailableView.search(text: query)
        }
    }

    // MARK: Treat another add-on like AIOMetadata

    private var manualSection: some View {
        Section {
            ForEach(otherAddons) { addon in
                Toggle(addon.manifest.name, isOn: Binding(
                    get: { store.usesCatalogPicker(addon) }, set: { store.setCatalogPicker(addon, $0) }))
            }
        } header: {
            Text("Other add-ons")
        } footer: {
            Text("Is your AIOMetadata add-on missing above? A copy hosted under another name isn't recognised automatically. Switch it on here to pick its catalogues too. Switching an add-on on removes its catalogues from Home until you add them.")
        }
    }

    // MARK: Actions

    private static func kind(_ type: String) -> String {
        type == "movie" ? "Movies" : type == "series" ? "Series" : type.capitalized
    }

    private func reload(_ addon: Addon) {
        reloading.insert(addon.id)
        Task {
            defer { reloading.remove(addon.id) }
            do { try await store.reload(addon); note = "\(addon.manifest.name) reloaded." }
            catch { note = "Couldn't reach \(addon.manifest.name)." }
        }
    }

    private func add() {
        Task {
            busy = true; defer { busy = false }
            do {
                try await store.add(urlText)
                urlText = ""; error = nil; addNote = nil
                // Added, but under a name we don't recognise: it behaves like any other add-on until switched on below.
                if let last = store.addons.last, !store.usesCatalogPicker(last) {
                    addNote = "Added \(last.manifest.name), but it doesn't identify itself as AIOMetadata. Switch it on under Other add-ons."
                }
            } catch {
                self.error = "Couldn't load that manifest. Check the URL and try again."
            }
        }
    }
}
