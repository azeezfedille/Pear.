import SwiftUI

/// Library sections (Watching, Completed, Plan to Watch), each ordered by most recent activity.
/// Simkl's library when Simkl is connected, otherwise the active profile's local library.
///
/// Layout: a row of glass filter chips, then the sections as plain headers over poster grids. Nothing is pinned and
/// no header has its own background, so there is no second bar to meet the navigation bar (that join was the seam).
/// The nav bar uses the system's soft scroll edge, so posters melt under it instead of being cut off.
struct LibraryView: View {
    @Environment(SimklStore.self) private var simkl
    @Environment(LibraryPrefs.self) private var prefs
    @Environment(LocalLibrary.self) private var local
    @Environment(WatchHistory.self) private var history
    @Environment(ProfileStore.self) private var profiles
    @Environment(ThemeStore.self) private var theme
    /// Which section the chips show: "all" or a section id.
    @State private var filter = "all"
    /// Comma-separated ids of the collapsed sections; remembered between launches.
    @AppStorage("library.collapsed") private var collapsedRaw = ""
    private let columns = [GridItem(.adaptive(minimum: 104, maximum: 160), spacing: 12, alignment: .top)]

    private struct LibSection: Identifiable {
        let id: String; let title: String; let symbol: String; let items: [MetaPreview]
    }

    private var collapsed: Set<String> { Set(collapsedRaw.split(separator: ",").map(String.init)) }

    private func toggle(_ id: String) {
        var s = collapsed
        if s.contains(id) { s.remove(id) } else { s.insert(id) }
        withAnimation(.snappy(duration: 0.3)) { collapsedRaw = s.sorted().joined(separator: ",") }
    }

    // MARK: Data

    private var sections: [LibSection] {
        prefs.usesSimkl(simkl) ? simklSections : localSections
    }

    /// Simkl returns each list already newest-activity-first (see SimklStore.sync).
    private var simklSections: [LibSection] {
        func items(_ key: String) -> [MetaPreview] { simkl.library.first { $0.id == "simkl-\(key)" }?.items ?? [] }
        return make([("watching", "Watching", "eye.fill", items("watching")),
                     ("completed", "Completed", "checkmark.circle.fill", items("completed")),
                     ("plan", "Plan to Watch", "bookmark.fill", items("plantowatch"))])
    }

    private var localSections: [LibSection] {
        let progress = Dictionary(history.entries.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var seen = Set<String>()

        // Completed: saved titles marked watched, plus movies whose history says they finished.
        var done: [(MetaPreview, Date)] = []
        for e in local.entries where e.status == .watched {
            let played = progress[e.item.id]?.updated ?? e.alias.flatMap { progress[$0]?.updated } ?? .distantPast
            done.append((e.item, max(played, e.added)))
            seen.insert(e.item.id); if let a = e.alias { seen.insert(a) }
        }
        for h in history.entries where h.isFinished && h.item.type != "series" && !seen.contains(h.id) {
            done.append((h.item, h.updated)); seen.insert(h.id)
        }

        // Watching: started and not finished (series count while there is progress), not already completed.
        let watching = history.entries
            .filter { $0.position > 30 && ($0.item.type == "series" || !$0.isFinished) && !seen.contains($0.id) }
            .sorted { $0.updated > $1.updated }
            .map(\.item)

        let plan = local.entries.filter { $0.status == .planToWatch }.sorted { $0.added > $1.added }.map(\.item)
        return make([("watching", "Watching", "eye.fill", watching),
                     ("completed", "Completed", "checkmark.circle.fill", done.sorted { $0.1 > $1.1 }.map(\.0)),
                     ("plan", "Plan to Watch", "bookmark.fill", plan)])
    }

    private func make(_ raw: [(String, String, String, [MetaPreview])]) -> [LibSection] {
        raw.compactMap { id, title, symbol, items in
            items.isEmpty ? nil : LibSection(id: id, title: title, symbol: symbol, items: items)
        }
    }

    private var subtitle: String {
        prefs.usesSimkl(simkl) ? "Synced with Simkl" : "\(simkl.name(for: profiles.active)) · On this device"
    }

    // MARK: View

    var body: some View {
        let secs = sections
        let active = secs.contains { $0.id == filter } ? filter : "all"
        let shown = active == "all" ? secs : secs.filter { $0.id == active }
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if secs.count > 1 { chips(secs, active: active) }
                    ForEach(shown) { sec in
                        let open = active != "all" || !collapsed.contains(sec.id)
                        VStack(alignment: .leading, spacing: 12) {
                            header(sec, open: open, collapsible: active == "all")
                            if open {
                                LazyVGrid(columns: columns, spacing: 18) {
                                    ForEach(sec.items) { PosterCard(item: $0, width: nil, showsTitle: true) }
                                }
                                .padding(.horizontal, 16)
                                .transition(.opacity)
                            }
                        }
                        .padding(.top, 20)
                    }
                }
                .padding(.bottom, 32)
                .animation(.snappy(duration: 0.3), value: active)
            }
            .scrollIndicators(.hidden)
            .overlay {
                if secs.isEmpty {
                    if prefs.usesSimkl(simkl) {
                        if simkl.isSyncing { ProgressView() }
                        else { ContentUnavailableView("Nothing here yet", systemImage: "books.vertical",
                            description: Text("Titles you add on Simkl show up here.")) }
                    } else {
                        ContentUnavailableView("Your library is empty", systemImage: "books.vertical",
                            description: Text("Tap Add to Watchlist on any title to save it to \(simkl.name(for: profiles.active))'s library. Connect Simkl in Settings to sync across devices."))
                    }
                }
            }
            .refreshable {
                if prefs.autoSync && simkl.isConnected {
                    await prefs.sync(simkl: simkl, library: local, history: history, force: true)
                } else if prefs.usesSimkl(simkl) {
                    await simkl.sync(force: true)
                }
            }
            .navigationDestination(for: MetaPreview.self) { DetailView(item: $0) }
            .navigationDestination(for: CatalogRow.self) { CatalogGridView(row: $0) }
            .navigationTitle("Library")
            .navigationSubtitle(subtitle)
            .navigationBarTitleDisplayMode(.large)
            .profileToolbar()
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    NavigationLink { DownloadsView() } label: { Image(systemName: "arrow.down.circle") }
                        .accessibilityLabel("Downloads")
                }
            }
        }
    }

    /// Filter chips: All, then one per section with its count. The selected one is tinted glass.
    private func chips(_ secs: [LibSection], active: String) -> some View {
        let total = secs.reduce(0) { $0 + $1.items.count }
        return ScrollView(.horizontal) {
            GlassEffectContainer(spacing: 8) {
                HStack(spacing: 8) {
                    chip(id: "all", title: "All", symbol: "square.grid.2x2.fill", count: total, active: active)
                    ForEach(secs) { chip(id: $0.id, title: $0.title, symbol: $0.symbol, count: $0.items.count, active: active) }
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 4)
        }
        .scrollIndicators(.hidden)
        .sensoryFeedback(.selection, trigger: active)
    }

    private func chip(id: String, title: String, symbol: String, count: Int, active: String) -> some View {
        let on = id == active
        return Button { withAnimation(.snappy(duration: 0.3)) { filter = id } } label: {
            HStack(spacing: 6) {
                Image(systemName: symbol).font(.system(size: 13, weight: .bold))
                Text(title).font(.subheadline.weight(.semibold))
                Text("\(count)").font(.subheadline.weight(.medium)).opacity(0.65)
            }
            .foregroundStyle(on ? theme.onAccent : Color.primary)
            .padding(.horizontal, 14).padding(.vertical, 9)
            .glassEffect(on ? .regular.tint(theme.accent).interactive() : .regular.interactive(), in: .capsule)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title), \(count) titles")
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    /// Plain section header: no background, not pinned. Tap to collapse (only while showing All).
    private func header(_ sec: LibSection, open: Bool, collapsible: Bool) -> some View {
        Button { toggle(sec.id) } label: {
            HStack(spacing: 8) {
                Image(systemName: sec.symbol).font(.system(size: 15, weight: .bold)).foregroundStyle(theme.accent)
                Text(sec.title).font(.title3.bold())
                Text("\(sec.items.count)").font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
                Spacer()
                if collapsible {
                    Image(systemName: "chevron.down").font(.footnote.weight(.bold)).foregroundStyle(.secondary)
                        .rotationEffect(.degrees(open ? 0 : -90))
                }
            }
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!collapsible)
        .accessibilityLabel("\(sec.title), \(sec.items.count) titles")
        .accessibilityValue(collapsible ? (open ? "Expanded" : "Collapsed") : "")
        .accessibilityHint(collapsible ? "Double tap to \(open ? "collapse" : "expand")" : "")
    }
}
