import SwiftUI

// MARK: - When is the wide layout used?

/// Shared flag: the player owns the screen. While it is up the layout mode is frozen, so rotating into the
/// player's landscape can't swap the app's structure out from under the page that presented it.
@MainActor @Observable
final class LayoutState {
    static let shared = LayoutState()
    var playerOpen = false

    /// How many sheets are up over the pages (see `coversPages()`).
    private(set) var coverDepth = 0
    /// True while a sheet sits over the pages. Nothing behind it needs to move: the hero auto-advance, its zoom and
    /// progress bar, and the shimmer sweeps all rest until it is dismissed, like they do for a page that is off screen.
    var pagesCovered: Bool { coverDepth > 0 }
    func cover() { coverDepth += 1 }
    func uncover() { coverDepth = max(coverDepth - 1, 0) }
}

private struct CoversPages: ViewModifier {
    @State private var counted = false
    func body(content: Content) -> some View {
        content
            .onAppear { if !counted { counted = true; LayoutState.shared.cover() } }
            .onDisappear { if counted { counted = false; LayoutState.shared.uncover() } }
    }
}

extension View {
    /// Put on the root of a sheet that covers the browsing pages. While it is presented, animation behind it rests.
    /// Apply it outside any NavigationStack inside the sheet: pushing a page there must not count as the sheet leaving.
    func coversPages() -> some View { modifier(CoversPages()) }
}

enum WideLayout {
    /// iPhone opt-in (Settings → Appearance). Off by default.
    static let phoneKey = "ui.landscapeLayout"
    static var isPad: Bool { UIDevice.current.userInterfaceIdiom == .pad }

    /// iPad: whenever there is room for it (full screen, or a wide split view; Slide Over falls back to tabs).
    /// iPhone: only when the toggle is on and the phone is in landscape.
    static func isWide(size: CGSize, hSize: UserInterfaceSizeClass?, phoneOptIn: Bool) -> Bool {
        if isPad { return hSize == .regular }
        return phoneOptIn && size.width > size.height
    }
}

private struct PageActiveKey: EnvironmentKey { static let defaultValue = true }
extension EnvironmentValues {
    /// False while a page is kept alive but is not the one on screen. The sidebar layout hides visited pages with
    /// opacity instead of removing them, so `onAppear` / `onDisappear` never fire for them. Anything that loops or
    /// animates on its own (hero auto-advance, Ken Burns) reads this and rests while it is false.
    var pageActive: Bool {
        get { self[PageActiveKey.self] }
        set { self[PageActiveKey.self] = newValue }
    }
}

private struct WideLayoutKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    /// True inside the sidebar layout. Views use it to pick bigger posters, skip the avatar button, and so on.
    var wideLayout: Bool {
        get { self[WideLayoutKey.self] }
        set { self[WideLayoutKey.self] = newValue }
    }
}

// MARK: - Tabs

enum AppTab: Hashable, CaseIterable, Identifiable {
    case search, home, explore, settings, library
    var id: Self { self }

    /// Sidebar order.
    static let sidebarOrder: [AppTab] = [.search, .home, .explore, .settings, .library]

    var title: String {
        switch self {
        case .search: "Search"
        case .home: "Home"
        case .explore: "Explore"
        case .settings: "Settings"
        case .library: "Library"
        }
    }
    var symbol: String {
        switch self {
        case .search: "magnifyingglass"
        case .home: "house.fill"
        case .explore: "safari"
        case .settings: "gearshape.fill"
        case .library: "books.vertical.fill"
        }
    }
}

/// An add-on catalogue listed under "Catalogues" in the sidebar.
struct CatalogueRef: Identifiable {
    let addon: Addon
    let def: AddonManifest.CatalogDef
    var id: String { "\(addon.id)/\(def.type)/\(def.id)" }
    var title: String {
        let kind = def.type == "movie" ? "Movies" : def.type == "series" ? "Series" : def.type.capitalized
        return "\(def.name ?? def.id) \(kind)"
    }
}

// MARK: - Sidebar shell

/// iPad (and opt-in iPhone landscape) container: profile + clock, the five destinations and the add-on catalogues
/// down the left; the selected page on the right. Pages that were opened stay alive while hidden, so each keeps
/// its own navigation stack and scroll position, like the tabs do.
struct SidebarShell: View {
    @Binding var tab: AppTab
    /// Full width of the window, used to pick between the full and the icon-only sidebar.
    let totalWidth: CGFloat

    @Environment(ThemeStore.self) private var theme
    @Environment(ProfileStore.self) private var profiles
    @Environment(SimklStore.self) private var simkl
    @Environment(AddonStore.self) private var store
    @Environment(ContentPrefs.self) private var contentPrefs
    @State private var visited: Set<AppTab> = [.home]
    @State private var catalogueID: String?
    @State private var showProfile = false

    private var sidebarWidth: CGFloat { totalWidth >= 1000 ? 250 : (totalWidth >= 780 ? 212 : 76) }
    private var compact: Bool { sidebarWidth < 100 }

    private var catalogues: [CatalogueRef] {
        HomeModel.homeJobs(addons: store.enabledAddons, rules: contentPrefs.rules, pickers: store.pickerIDs)
            .map { CatalogueRef(addon: $0.0, def: $0.1) }
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            pages.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color(.systemBackground).ignoresSafeArea())
        .environment(\.wideLayout, true)
        .sheet(isPresented: $showProfile) { ProfileSheet() }
        .onChange(of: tab, initial: true) { _, t in visited.insert(t) }
    }

    // MARK: Pages

    private func shown(_ t: AppTab) -> Bool { catalogueID == nil && tab == t }

    private var pages: some View {
        ZStack {
            ForEach(AppTab.allCases) { t in
                if visited.contains(t) || tab == t {
                    page(t)
                        .environment(\.pageActive, shown(t))
                        .opacity(shown(t) ? 1 : 0)
                        .allowsHitTesting(shown(t))
                        .accessibilityHidden(!shown(t))
                }
            }
            if let id = catalogueID, let ref = catalogues.first(where: { $0.id == id }) {
                CataloguePage(ref: ref).id(ref.id)
            }
        }
    }

    @ViewBuilder private func page(_ t: AppTab) -> some View {
        switch t {
        case .home: HomeView()
        case .explore: ExploreView()
        case .library: LibraryView()
        case .settings: SettingsView()
        case .search: SearchView()
        }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            VStack(spacing: 6) { ForEach(AppTab.sidebarOrder) { navRow($0) } }
            if !compact && !catalogues.isEmpty { catalogueList }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, compact ? 8 : 14)
        .padding(.top, 14).padding(.bottom, 10)
        .frame(width: sidebarWidth)
        .frame(maxHeight: .infinity)
        .background {
            ZStack(alignment: .trailing) {
                Color(white: 0.07)
                Rectangle().fill(.white.opacity(0.07)).frame(width: 0.5)
            }
            .ignoresSafeArea()
        }
    }

    private var header: some View {
        Button { showProfile = true } label: {
            HStack(spacing: 10) {
                ProfileAvatar(profile: profiles.active, size: 34)
                if !compact {
                    Text(simkl.name(for: profiles.active)).font(.system(size: 16, weight: .semibold)).lineLimit(1)
                    Spacer(minLength: 4)
                    TimelineView(.everyMinute) { ctx in
                        Text(ctx.date.formatted(date: .omitted, time: .shortened))
                            .font(.footnote).foregroundStyle(.secondary).monospacedDigit()
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: compact ? .center : .leading)
            .padding(.horizontal, compact ? 0 : 6).padding(.bottom, 18)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Profile")
        .accessibilityValue(simkl.name(for: profiles.active))
    }

    private func navRow(_ t: AppTab) -> some View {
        let on = catalogueID == nil && tab == t
        return Button {
            catalogueID = nil
            tab = t
        } label: {
            HStack(spacing: 14) {
                Image(systemName: t.symbol).font(.system(size: 18, weight: .medium)).frame(width: 26)
                if !compact {
                    Text(t.title).font(.system(size: 16, weight: on ? .semibold : .regular))
                    Spacer(minLength: 0)
                }
            }
            .foregroundStyle(on ? theme.onAccent : Color.primary.opacity(0.85))
            .padding(.horizontal, 14).padding(.vertical, 11)
            .frame(maxWidth: .infinity, alignment: compact ? .center : .leading)
            .background(on ? theme.accent : Color.clear, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(t.title)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    private var catalogueList: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Catalogues").font(.system(size: 15, weight: .medium)).foregroundStyle(.secondary)
                .padding(.horizontal, 14).padding(.top, 24)
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(catalogues) { ref in
                        let on = catalogueID == ref.id
                        Button { catalogueID = ref.id } label: {
                            Text(ref.title).font(.system(size: 14, weight: on ? .semibold : .regular)).lineLimit(1)
                                .foregroundStyle(on ? theme.onAccent : Color.primary.opacity(0.85))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 12).padding(.vertical, 9)
                                .background(on ? theme.accent : Color.clear, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(4)
            }
            .scrollIndicators(.hidden)
            .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }
}

/// One add-on catalogue as a full page (the sidebar entry), with the usual endless poster grid.
private struct CataloguePage: View {
    let ref: CatalogueRef
    @Environment(ContentPrefs.self) private var contentPrefs
    @State private var row: CatalogRow?
    @State private var failed = false

    var body: some View {
        NavigationStack {
            Group {
                if let row { CatalogGridView(row: row) }
                else if failed { ContentUnavailableView("Couldn't load this catalogue", systemImage: "wifi.slash") }
                else { ProgressView() }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(.systemBackground))
            .navigationDestination(for: MetaPreview.self) { DetailView(item: $0) }
            .navigationDestination(for: CatalogRow.self) { CatalogGridView(row: $0) }
        }
        .task(id: ref.id) {
            let raw = (try? await AddonClient.shared.catalog(addon: ref.addon, catalog: ref.def)) ?? []
            guard !Task.isCancelled else { return }
            guard !raw.isEmpty else { failed = true; return }
            let items = await TitleClassifier.shared.filter(raw, rules: contentPrefs.rules)
            row = CatalogRow(id: ref.id, title: ref.title, items: items, source: .addon(ref.addon, ref.def),
                             symbol: "film.stack", prefKey: ContentRules.rowKey(ref.addon, ref.def), rawCount: raw.count)
        }
    }
}

// MARK: - Collapsing split (poster panel + items)

struct SplitContext {
    /// The items pane has covered the poster panel.
    var collapsed: Bool
    var topInset: CGFloat
    var bottomInset: CGFloat
}

/// Snaps the horizontal scroll to "poster shown" or "poster hidden", whichever is nearer where the flick lands.
private struct HeroSnap: ScrollTargetBehavior {
    let heroWidth: CGFloat
    func updateTarget(_ target: inout ScrollTarget, context: TargetContext) {
        target.rect.origin.x = target.rect.origin.x > heroWidth * 0.5 ? heroWidth : 0
    }
}

/// The wide layout's page: a poster panel on the left, the items on the right. Drag the items left and they slide
/// over the poster (which drifts at half speed underneath), leaving the whole width for items; drag back, tap the
/// edge button, or pull the edge handle to bring it back. It is the sideways version of the phone's collapsing hero.
///
/// How the drag works: the panel and the pane sit side by side in one horizontal `ScrollView`, so the system supplies
/// the physics. While the poster is showing, the horizontal carousels inside the pane are switched off, so a swipe
/// on a carousel moves the pane instead of fighting it; once collapsed they scroll normally again.
struct CollapsingSplit<Hero: View, Pane: View>: View {
    var showsHero = true
    var heroFraction: CGFloat = 0.42
    @ViewBuilder var hero: () -> Hero
    @ViewBuilder var pane: (SplitContext) -> Pane

    @Environment(\.pageActive) private var pageActive
    @State private var collapsed = false
    @State private var position = ScrollPosition(edge: .leading)

    var body: some View {
        GeometryReader { geo in
            let full = geo.size.width
            let heroW = min(max(full * heroFraction, 290), 500)
            let inset = SplitContext(collapsed: collapsed || !showsHero, topInset: geo.safeAreaInsets.top,
                                     bottomInset: geo.safeAreaInsets.bottom)
            if showsHero {
                ScrollView(.horizontal) {
                    HStack(spacing: 0) {
                        hero()
                            .frame(width: heroW, height: geo.size.height)
                            .visualEffect { content, proxy in
                                // 0 at rest, -scrolled distance once the pane slides over it.
                                let x = proxy.frame(in: .scrollView).minX
                                let p = min(max(-x / heroW, 0), 1)
                                return content.offset(x: -x * 0.5).opacity(1 - 0.5 * p)
                            }
                            // Covered by the pane: nothing on the poster panel needs to keep moving.
                            .environment(\.pageActive, pageActive && !collapsed)
                            .zIndex(0)
                        pane(inset)
                            .frame(width: full, height: geo.size.height)
                            .background(Color(.systemBackground))
                            .overlay(alignment: .leading) { grip }
                            .zIndex(1)
                    }
                }
                .scrollTargetBehavior(HeroSnap(heroWidth: heroW))
                .scrollPosition($position)
                .scrollIndicators(.hidden)
                .onScrollGeometryChange(for: Bool.self) { $0.contentOffset.x >= heroW - 2 } action: { _, now in
                    if now != collapsed { collapsed = now }
                }
                .overlay(alignment: .leading) { if collapsed { showHeroButton } }
                .sensoryFeedback(.selection, trigger: collapsed)
            } else {
                pane(inset)
            }
        }
    }

    /// Thin drag handle on the pane's leading edge. It has no scroll view of its own, so a drag that starts here
    /// always reaches the horizontal scroll, even when a carousel sits under it.
    private var grip: some View {
        Color.clear.frame(width: 22).contentShape(Rectangle())
            .overlay {
                if collapsed { Capsule().fill(.white.opacity(0.25)).frame(width: 4, height: 44) }
            }
            .accessibilityHidden(true)
    }

    private var showHeroButton: some View {
        Button {
            withAnimation(.smooth(duration: 0.45)) { position.scrollTo(x: 0) }
        } label: {
            Image(systemName: "chevron.right").font(.system(size: 14, weight: .bold))
                .frame(width: 34, height: 34)
                .glassEffect(.regular.interactive(), in: .circle)
        }
        .buttonStyle(.plain)
        .padding(.leading, 8)
        .accessibilityLabel("Show poster")
        .transition(.opacity)
    }
}

/// The pane's vertical scroll. Horizontal scrolling inside the content is off while the poster is showing
/// (see `CollapsingSplit`); the vertical scroll itself is always on.
struct PaneScroll<Content: View>: View {
    let ctx: SplitContext
    var refresh: (() async -> Void)? = nil
    @ViewBuilder let content: () -> Content

    var body: some View {
        let scroll = ScrollView {
            content()
                .scrollDisabled(!ctx.collapsed)
                .padding(.top, ctx.topInset + 12)
                .padding(.bottom, ctx.bottomInset + 40)
        }
        .scrollIndicators(.hidden)
        if let refresh { scroll.refreshable { await refresh() } } else { scroll }
    }
}

// MARK: - Home poster panel

/// Home's big panel: the day's featured titles as tall poster art with the logo, rating, synopsis and a Details
/// button. Rotates by itself (like the phone hero); tap a dot to jump.
struct WideHeroPanel: View {
    let items: [MetaPreview]
    @Binding var tint: Color?
    @Environment(\.pageActive) private var pageActive
    @Environment(\.scenePhase) private var scenePhase
    @State private var page: String?
    @State private var visible = true

    private static let interval = 7.0
    private var currentID: String { page ?? items.first?.id ?? "" }
    private var index: Int { items.firstIndex(where: { $0.id == currentID }) ?? 0 }
    private var current: MetaPreview? { items.first(where: { $0.id == currentID }) ?? items.first }
    /// On screen, in the foreground, and not hidden behind another page or the sliding pane.
    private var running: Bool { visible && pageActive && scenePhase == .active && !LayoutState.shared.pagesCovered }
    private struct AutoKey: Hashable { let page: String; let visible: Bool }

    var body: some View {
        GeometryReader { geo in
            let compact = geo.size.height < 560
            ZStack(alignment: .bottom) {
                if let item = current {
                    NavigationLink(value: item) {
                        ZStack(alignment: .bottomLeading) {
                            RotatingArtwork(item: item, kind: .poster, size: 1000)
                                .frame(width: geo.size.width, height: geo.size.height)
                                .clipped()
                                .id(item.id)
                                .transition(.opacity)
                            LinearGradient(stops: [.init(color: .clear, location: 0.38),
                                                   .init(color: .black.opacity(0.55), location: 0.68),
                                                   .init(color: .black.opacity(0.9), location: 1)],
                                           startPoint: .top, endPoint: .bottom)
                            info(item, compact: compact)
                                .padding(.horizontal, 22)
                                .padding(.bottom, compact ? 30 : 46)
                        }
                        .frame(width: geo.size.width, height: geo.size.height)
                    }
                    .buttonStyle(.plain)
                }
                if items.count > 1 { dots.padding(.bottom, compact ? 8 : 16) }
            }
            .animation(.easeInOut(duration: 0.8), value: currentID)
        }
        .onAppear { visible = true }
        .onDisappear { visible = false }
        .onChange(of: items.map(\.id)) { _, ids in
            if let p = page, !ids.contains(p) { page = ids.first }
        }
        .task(id: AutoKey(page: currentID, visible: running)) {
            guard running, items.count > 1 else { return }
            try? await Task.sleep(for: .seconds(Self.interval))
            guard !Task.isCancelled else { return }
            page = items[(index + 1) % items.count].id
        }
        .task(id: currentID) { await updateTint() }
    }

    private func info(_ item: MetaPreview, compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: compact ? 7 : 10) {
            HStack(spacing: 8) {
                Label(item.typeLabel.uppercased(), systemImage: item.type == "series" ? "tv" : "film")
                    .font(.caption2.weight(.heavy)).tracking(1.2)
                    .padding(.horizontal, 9).padding(.vertical, 4)
                    .background(.white.opacity(0.18), in: Capsule())
                if let y = item.year { Text(String(y)).font(.subheadline.weight(.semibold)).opacity(0.9) }
            }
            TitleArt(item: item, maxWidth: 300, maxHeight: compact ? 56 : 92,
                     font: .system(size: compact ? 28 : 38, weight: .heavy, design: .rounded))
            InlineRatings(item: item)
            if let d = item.description, !d.isEmpty {
                Text(d).font(.subheadline).lineLimit(compact ? 2 : 3).opacity(0.85)
            }
            Text("Details")
                .font(.subheadline.weight(.semibold)).padding(.horizontal, 18).padding(.vertical, 10)
                .background(.white.opacity(0.2), in: Capsule())
                .overlay(Capsule().strokeBorder(.white.opacity(0.28), lineWidth: 0.5))
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var dots: some View {
        HStack(spacing: 8) {
            ForEach(Array(items.enumerated()), id: \.element.id) { i, it in
                Button { withAnimation { page = it.id } } label: {
                    Circle().fill(.white.opacity(i == index ? 0.95 : 0.35))
                        .frame(width: 7, height: 7)
                        .padding(5).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Featured \(i + 1) of \(items.count)")
            }
        }
    }

    @MainActor private func updateTint() async {
        guard let item = current,
              let url = ArtworkRotation.shared.poster(for: item, longestEdgePixels: 1000).url,
              let c = await ImagePipeline.shared.averageColor(for: url), !Task.isCancelled else { return }
        withAnimation(.easeInOut(duration: 0.9)) { tint = Color(uiColor: c) }
    }
}
