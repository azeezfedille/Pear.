import SwiftUI

/// First-launch setup: sign in with Simkl or pick a name, choose an accent colour, decide what shows up, add API keys.
/// Every step can be skipped, and everything chosen here lives in Settings afterwards.
struct OnboardingView: View {
    let finish: () -> Void

    @Environment(SimklStore.self) private var simkl
    @Environment(ProfileStore.self) private var profiles
    @Environment(ThemeStore.self) private var theme
    @Environment(ContentPrefs.self) private var prefs
    @Environment(AddonStore.self) private var store
    @AppStorage("tmdb.key") private var tmdbKey = ""
    @AppStorage("tvdb.key") private var tvdbKey = ""
    @AppStorage("tvdb.pin") private var tvdbPin = ""
    @AppStorage("mdblist.key") private var mdbKey = ""

    private enum Step: Int, CaseIterable { case welcome, profile, look, content, home, keys, done }

    @State private var step = Step.welcome
    @State private var name = ""
    @State private var useSimkl = true
    @State private var urlText = ""
    @State private var addError: String?
    @State private var adding = false
    @State private var ownTMDB = false

    private var rules: ContentRules { prefs.rules }

    var body: some View {
        ZStack {
            background
            VStack(spacing: 0) {
                topBar
                page
                    .id(step)
                    .transition(.opacity)
                    .frame(maxHeight: .infinity)
                bottomBar
            }
        }
        .tint(theme.accent)
        .preferredColorScheme(Theme.forceDark ? .dark : nil)
        .interactiveDismissDisabled()
        .animation(.easeInOut(duration: 0.25), value: step)
        .onChange(of: simkl.account) { _, a in if a != nil { useSimkl = true } }
        // Right after sign-in, pull the library so Home and Library are filled when setup ends.
        .onChange(of: simkl.isConnected) { _, on in if on { Task { await simkl.sync(force: true) } } }
    }

    // MARK: Frame

    private var background: some View {
        ZStack {
            Color.black
            RadialGradient(colors: [theme.accent.opacity(0.32), .clear], center: .top, startRadius: 10, endRadius: 520)
                .animation(.easeInOut(duration: 0.3), value: theme.hex)
        }
        .ignoresSafeArea()
    }

    private var topBar: some View {
        HStack {
            Spacer()
            if step != .done {
                Button("Skip setup") { complete() }
                    .font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 20).frame(height: 44)
    }

    private var bottomBar: some View {
        VStack(spacing: 14) {
            HStack(spacing: 6) {
                ForEach(Step.allCases, id: \.rawValue) { s in
                    Capsule().fill(s == step ? theme.accent : Color.white.opacity(0.22))
                        .frame(width: s == step ? 22 : 7, height: 7)
                }
            }
            .animation(.snappy, value: step)
            HStack(spacing: 12) {
                if step != .welcome && step != .done {
                    Button { move(-1) } label: { Text("Back").frame(maxWidth: 110) }
                        .buttonStyle(.glass).controlSize(.large)
                }
                Button { next() } label: { Text(primaryTitle).font(.headline).frame(maxWidth: .infinity) }
                    .buttonStyle(.glassProminent).controlSize(.large)
                    .disabled(step == .profile && !canContinueProfile)
            }
        }
        .padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 12)
    }

    private var primaryTitle: String {
        switch step {
        case .welcome: return "Get Started"
        case .done: return "Start Watching"
        case .keys: return tmdbKey.isEmpty && !TMDBClient.hasProxy && tvdbKey.isEmpty && mdbKey.isEmpty ? "Skip for now" : "Continue"
        default: return "Continue"
        }
    }

    private func move(_ d: Int) {
        guard let s = Step(rawValue: step.rawValue + d) else { return }
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        step = s
    }

    private func next() {
        if step == .done { complete() } else { move(1) }
    }

    private func complete() {
        commit()
        Onboarding.finish()
        finish()
    }

    /// Writes the choices to the first profile. Everything else (accent, content, keys, add-ons) is saved as it is changed.
    private func commit() {
        var p = profiles.active
        let typed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !typed.isEmpty { p.name = typed }
        else if simklActive, let n = simkl.account?.name { p.name = n }
        p.simklIdentity = simklActive ? true : nil
        if !theme.isSystem { p.colorHex = theme.hex }
        profiles.update(p)
    }

    // MARK: Pages

    @ViewBuilder private var page: some View {
        switch step {
        case .welcome: welcome
        case .profile: profilePage
        case .look: lookPage
        case .content: contentPage
        case .home: homePage
        case .keys: keysPage
        case .done: donePage
        }
    }

    private func scroller<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) { content() }
                .padding(.horizontal, 20).padding(.vertical, 8)
                .frame(maxWidth: 560, alignment: .leading)
                .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.hidden)
        .scrollDismissesKeyboard(.interactively)
    }

    private func header(_ title: String, _ subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 30, weight: .bold, design: .rounded))
            Text(subtitle).font(.callout).foregroundStyle(.secondary)
        }
        .padding(.bottom, 4)
    }

    private func card<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 12) { content() }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    // MARK: 1 · Welcome

    private var welcome: some View {
        VStack(spacing: 22) {
            Spacer(minLength: 0)
            PearWordmark(height: 64)
            Text("Everything you watch, in one place.\nA minute of setup makes it yours.")
                .font(.title3).multilineTextAlignment(.center).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 14) {
                welcomeRow("person.crop.circle.fill", "Sign in or pick a name")
                welcomeRow("paintpalette.fill", "Choose your colour")
                welcomeRow("square.grid.2x2.fill", "Decide what shows on Home")
                welcomeRow("key.fill", "Add your API keys")
            }
            .padding(.top, 6)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 28)
        .frame(maxWidth: .infinity)
    }

    private func welcomeRow(_ symbol: String, _ text: String) -> some View {
        Label { Text(text).font(.body.weight(.medium)) } icon: {
            Image(systemName: symbol).foregroundStyle(theme.accent).frame(width: 28)
        }
    }

    // MARK: 2 · Profile (Simkl or a name)

    private var simklActive: Bool { simkl.isConnected && simkl.account != nil && useSimkl }

    private var canContinueProfile: Bool {
        simklActive || !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var draftProfile: Profile {
        let typed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return Profile(id: "preview", name: typed.isEmpty ? (simkl.account?.name ?? "?") : typed,
                       colorHex: theme.isSystem ? Theme.defaultHex : theme.hex, symbol: "",
                       simklIdentity: simklActive ? true : nil)
    }

    /// The name the profile will carry: the Simkl account's when that is in use, else the typed one.
    private var shownName: String {
        if simklActive, let n = simkl.account?.name { return n }
        let n = draftProfile.name
        return n == "?" ? "friend" : n
    }

    private var profilePage: some View {
        scroller {
            header("Who's watching?", "Sign in with Simkl to bring your name, picture and library, or just pick a name.")
            HStack { Spacer(); ProfileAvatar(profile: draftProfile, size: 88); Spacer() }
                .padding(.vertical, 4)

            card {
                Label("Sign in with Simkl", systemImage: "arrow.triangle.2.circlepath").font(.headline)
                if simkl.isConnected {
                    Label("Connected", systemImage: "checkmark.circle.fill").font(.subheadline.weight(.semibold)).foregroundStyle(.green)
                    if let a = simkl.account {
                        Toggle(isOn: $useSimkl) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Use my Simkl name and picture")
                                Text(a.name).font(.footnote).foregroundStyle(.secondary)
                            }
                        }
                    }
                } else {
                    Text("Syncs your library and watch history, and uses your Simkl name and picture. You enter a code on simkl.com/pin; no account setup needed.")
                        .font(.footnote).foregroundStyle(.secondary)
                    SimklConnectControls(compact: true)
                }
            }

            card {
                Label("Pick a name", systemImage: "person.fill").font(.headline)
                TextField("Name", text: $name)
                    .textInputAutocapitalization(.words).submitLabel(.done)
                    .padding(12)
                    .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .onChange(of: name) { _, v in if v.count > 20 { name = String(v.prefix(20)) } }
                Text(simklActive ? "Optional while your Simkl name is in use. It is kept as a fallback." : "This is how your profile is shown. You can add more profiles later.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: 3 · Accent colour

    private var lookPage: some View {
        scroller {
            header("Pick your colour", "It tints buttons, progress bars and highlights across the app. Change it any time in Settings.")
            card {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 52), spacing: 14)], spacing: 14) {
                    Button { theme.setAccent(hex: Theme.systemHex) } label: {
                        Circle().fill(.white).frame(width: 46, height: 46)
                            .overlay { Circle().fill(.black).mask(HStack(spacing: 0) { Color.clear; Rectangle() }) }
                            .overlay(Circle().strokeBorder(.white.opacity(0.25), lineWidth: 1))
                            .overlay { if theme.isSystem { Image(systemName: "checkmark").font(.footnote.weight(.black)).foregroundStyle(Color(white: 0.5)) } }
                    }
                    .buttonStyle(.plain).accessibilityLabel("System (no accent)")
                    ForEach(Theme.presets, id: \.hex) { p in
                        Button { theme.setAccent(hex: p.hex) } label: {
                            Circle().fill(Color(hex: p.hex) ?? .gray).frame(width: 46, height: 46)
                                .overlay(Circle().strokeBorder(.white.opacity(0.18), lineWidth: 1))
                                .overlay {
                                    if theme.hex.uppercased() == p.hex.uppercased() {
                                        Image(systemName: "checkmark").font(.footnote.weight(.black))
                                            .foregroundStyle((Color(hex: p.hex) ?? .gray).contrastingForeground)
                                    }
                                }
                        }
                        .buttonStyle(.plain).accessibilityLabel(p.name)
                    }
                }
                ColorPicker("Custom colour", selection: Binding(get: { theme.accent }, set: { theme.setAccent(hex: $0.hexString) }),
                            supportsOpacity: false)
            }
            card {
                Text("Preview").font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
                HStack(spacing: 12) {
                    Label("Play", systemImage: "play.fill").font(.subheadline.weight(.bold)).foregroundStyle(theme.onAccent)
                        .padding(.horizontal, 18).padding(.vertical, 10).background(theme.accent, in: Capsule())
                    Text("UP NEXT").font(.system(size: 10, weight: .heavy)).tracking(0.8).foregroundStyle(theme.onAccent)
                        .padding(.horizontal, 8).padding(.vertical, 4).background(theme.accent, in: Capsule())
                }
                Capsule().fill(.white.opacity(0.25)).frame(height: 5)
                    .overlay(alignment: .leading) { GeometryReader { g in Capsule().fill(theme.gradient).frame(width: g.size.width * 0.62) } }
            }
        }
    }

    // MARK: 4 · What to see

    private var contentPage: some View {
        scroller {
            header("What do you want to see?", "Switch off anything you don't want suggested. It is hidden from Home, Explore and recommendations.")
            card {
                Text("Where it's from").font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
                ForEach(ContentCategory.regions) { categoryToggle($0) }
            }
            card {
                Text("Kinds of titles").font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
                ForEach(ContentCategory.kinds) { categoryToggle($0) }
            }
            Text("Chosen per profile. Find it again in Settings → Content & catalogues.")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }

    private func categoryToggle(_ c: ContentCategory) -> some View {
        Toggle(isOn: Binding(get: { !rules.hiddenCategories.contains(c) }, set: { prefs.setHidden(c, !$0) })) {
            Label(c.title, systemImage: c.symbol)
        }
    }

    // MARK: 5 · Home + catalogues

    private var pickerAddons: [Addon] { store.addons.filter { store.usesCatalogPicker($0) } }

    private var homePage: some View {
        scroller {
            header("Build your Home", "Choose the rows you want, and add Stremio add-ons for more catalogues.")
            card {
                Text("Home rows").font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
                rowToggle("Trending Movies", ContentRules.Builtin.trendingMovies, "flame.fill")
                rowToggle("Trending Shows", ContentRules.Builtin.trendingShows, "flame.fill")
                rowToggle("Because you watched", ContentRules.Builtin.because, "sparkles")
                rowToggle("Themed collections", ContentRules.Builtin.themes, "square.stack.fill")
            }
            card {
                Label("Add-ons", systemImage: "puzzlepiece.extension.fill").font(.headline)
                if store.addons.isEmpty {
                    Text("Loading…").font(.footnote).foregroundStyle(.secondary)
                }
                ForEach(store.addons) { a in
                    Label(a.manifest.name, systemImage: "checkmark.circle.fill").font(.subheadline).foregroundStyle(.green)
                }
                TextField("Add-on link (https:// or stremio://)", text: $urlText)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL).submitLabel(.go)
                    .onSubmit { addAddon() }
                    .padding(12)
                    .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                Button(adding ? "Adding…" : "Add add-on") { addAddon() }
                    .buttonStyle(.bordered).disabled(urlText.isEmpty || adding)
                if let addError { Text(addError).font(.footnote).foregroundStyle(.red) }
                else {
                    Text("Paste an add-on's manifest link, for example your AIOMetadata. Catalogues from AIOMetadata only show on Home once you pick them below.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            ForEach(pickerAddons) { a in catalogueCard(a) }
        }
    }

    private func catalogueCard(_ a: Addon) -> some View {
        let all = a.homeCatalogs
        let keys = all.map { ContentRules.rowKey(a, $0) }
        return card {
            HStack {
                Text("\(a.manifest.name) catalogues").font(.headline)
                Spacer()
                Button("All") { prefs.setRowsAdded(keys, true) }.font(.subheadline)
                Button("None") { prefs.setRowsAdded(keys, false) }.font(.subheadline)
            }
            ForEach(Array(all.prefix(60)), id: \.self) { cat in
                let key = ContentRules.rowKey(a, cat)
                Toggle(isOn: Binding(get: { rules.isRowAdded(key) }, set: { prefs.setRowAdded(key, $0) })) {
                    Text("\(cat.name ?? cat.id) · \(cat.type == "movie" ? "Movies" : cat.type == "series" ? "Series" : cat.type.capitalized)")
                        .font(.subheadline)
                }
            }
            if all.count > 60 {
                Text("\(all.count - 60) more in Settings → Content & catalogues.").font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    private func rowToggle(_ title: String, _ key: String, _ symbol: String) -> some View {
        Toggle(isOn: Binding(get: { !rules.isRowHidden(key) }, set: { prefs.setRowHidden(key, !$0) })) {
            Label(title, systemImage: symbol)
        }
    }

    private func addAddon() {
        guard !urlText.isEmpty, !adding else { return }
        Task {
            adding = true; defer { adding = false }
            do {
                try await store.add(urlText)
                urlText = ""; addError = nil
            } catch {
                addError = "Couldn't load that manifest. Check the link and try again."
            }
        }
    }

    // MARK: 6 · API keys

    private var keysPage: some View {
        scroller {
            header("Connect your services", TMDBClient.hasProxy
                   ? "TMDB is already built in. MDBList and TheTVDB use your own free API keys, which stay on this device. You can add or change any of them later in Settings → Integrations."
                   : "Pear uses your own free API keys. They stay on this device, and you can add or change them later in Settings → Integrations.")
            if TMDBClient.hasProxy {
                tmdbBuiltInCard
            } else {
                keyCard(title: "TMDB", badge: "Recommended", symbol: "film.stack",
                        text: "Trending, Explore, recommendations, episode thumbnails, title logos and skip-intro matching. Without it, most of the app stays empty.",
                        placeholder: "TMDB API key", binding: $tmdbKey, link: "https://www.themoviedb.org/settings/api", linkTitle: "Get a free key")
            }
            keyCard(title: "MDBList", badge: nil, symbol: "list.bullet",
                    text: "IMDb, Rotten Tomatoes, Metacritic and Letterboxd ratings, plus your lists on Home.",
                    placeholder: "MDBList API key", binding: $mdbKey, link: "https://mdblist.com/preferences", linkTitle: "Get a key")
            keyCardWith(title: "TheTVDB", badge: nil, symbol: "tv",
                    text: "Fills in missing episode thumbnails and title logos.",
                    placeholder: "TVDB API key", binding: $tvdbKey, link: "https://thetvdb.com/api-information", linkTitle: "Get a key") {
                SecureField("PIN (subscriber keys only)", text: $tvdbPin)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().submitLabel(.done)
                    .padding(12).background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
    }

    /// Own-key switch for the TMDB card. Off by default; on whenever a key is already saved. Switching it off
    /// clears the key so the built-in one is what actually gets used.
    private var ownTMDBBinding: Binding<Bool> {
        Binding(get: { ownTMDB || !tmdbKey.isEmpty },
                set: { on in ownTMDB = on; if !on { tmdbKey = "" } })
    }

    private var tmdbBuiltInCard: some View {
        card {
            HStack(spacing: 8) {
                Label("TMDB", systemImage: "film.stack").font(.headline)
                Text("Built in").font(.system(size: 10, weight: .heavy)).foregroundStyle(theme.onAccent)
                    .padding(.horizontal, 8).padding(.vertical, 3).background(theme.accent, in: Capsule())
                Spacer()
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            }
            Text("You don't need to provide a key. Pear. already includes one, so trending, Explore, recommendations, episode thumbnails, title logos and skip-intro matching work out of the box. If something doesn't load, turn on the switch below and add your own free key.")
                .font(.footnote).foregroundStyle(.secondary)
            Toggle("Use my own TMDB key", isOn: ownTMDBBinding)
                .font(.subheadline.weight(.semibold))
            if ownTMDBBinding.wrappedValue {
                SecureField("TMDB API key", text: $tmdbKey)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().submitLabel(.done)
                    .padding(12).background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                if let u = URL(string: "https://www.themoviedb.org/settings/api") {
                    Link("Get a free key", destination: u).font(.subheadline.weight(.semibold))
                }
            }
        }
    }

    private func keyCard(title: String, badge: String?, symbol: String, text: String, placeholder: String,
                         binding: Binding<String>, link: String, linkTitle: String) -> some View {
        keyCardWith(title: title, badge: badge, symbol: symbol, text: text, placeholder: placeholder,
                    binding: binding, link: link, linkTitle: linkTitle) { EmptyView() }
    }

    private func keyCardWith<Extra: View>(title: String, badge: String?, symbol: String, text: String, placeholder: String,
                                          binding: Binding<String>, link: String, linkTitle: String,
                                          @ViewBuilder extra: () -> Extra) -> some View {
        card {
            HStack(spacing: 8) {
                Label(title, systemImage: symbol).font(.headline)
                if let badge {
                    Text(badge).font(.system(size: 10, weight: .heavy)).foregroundStyle(theme.onAccent)
                        .padding(.horizontal, 8).padding(.vertical, 3).background(theme.accent, in: Capsule())
                }
                Spacer()
                if !binding.wrappedValue.isEmpty { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) }
            }
            Text(text).font(.footnote).foregroundStyle(.secondary)
            SecureField(placeholder, text: binding)
                .textInputAutocapitalization(.never).autocorrectionDisabled().submitLabel(.done)
                .padding(12).background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            extra()
            if let u = URL(string: link) { Link(linkTitle, destination: u).font(.subheadline.weight(.semibold)) }
        }
    }

    // MARK: 7 · Done

    private var donePage: some View {
        VStack(spacing: 18) {
            Spacer(minLength: 0)
            ProfileAvatar(profile: draftProfile, size: 96)
            Text("You're all set, \(shownName)")
                .font(.system(size: 28, weight: .bold, design: .rounded)).multilineTextAlignment(.center)
            VStack(alignment: .leading, spacing: 10) {
                summary("Simkl", simkl.isConnected ? "Connected" : "Not connected", simkl.isConnected)
                summary("TMDB key", tmdbKey.isEmpty ? (TMDBClient.hasProxy ? "Built in" : "Not added") : "Added", !tmdbKey.isEmpty || TMDBClient.hasProxy)
                summary("MDBList key", mdbKey.isEmpty ? "Not added" : "Added", !mdbKey.isEmpty)
                summary("TheTVDB key", tvdbKey.isEmpty ? "Not added" : "Added", !tvdbKey.isEmpty)
            }
            .padding(16).frame(maxWidth: 420)
            .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            Text("Everything here can be changed in Settings.").font(.footnote).foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 24).frame(maxWidth: .infinity)
    }

    private func summary(_ title: String, _ value: String, _ on: Bool) -> some View {
        HStack {
            Image(systemName: on ? "checkmark.circle.fill" : "circle.dashed").foregroundStyle(on ? Color.green : Color.secondary)
            Text(title).font(.subheadline.weight(.semibold))
            Spacer()
            Text(value).font(.subheadline).foregroundStyle(.secondary)
        }
    }
}
