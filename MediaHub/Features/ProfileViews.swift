import SwiftUI

// MARK: - Avatar

/// Round profile picture: the profile's colour with its icon (or first letter) on top.
struct ProfileAvatar: View {
    let profile: Profile
    var size: CGFloat = 30
    @Environment(SimklStore.self) private var simkl

    var body: some View {
        let base = Color(hex: profile.colorHex) ?? .purple
        ZStack {
            Circle().fill(LinearGradient(colors: [base, base.opacity(0.62)], startPoint: .topLeading, endPoint: .bottomTrailing))
            if profile.symbol.isEmpty {
                Text(profile.initial)
                    .font(.system(size: size * 0.46, weight: .bold, design: .rounded))
                    .foregroundStyle(base.contrastingForeground)
            } else {
                Image(systemName: profile.symbol)
                    .font(.system(size: size * 0.44, weight: .bold))
                    .foregroundStyle(base.contrastingForeground)
            }
            if let url = simkl.avatarURL(for: profile) { AvatarPhoto(url: url, size: size) }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// A profile picture from the web (the Simkl account's). Transparent until it loads, so the icon underneath shows meanwhile.
private struct AvatarPhoto: View {
    let url: URL
    let size: CGFloat
    @Environment(\.displayScale) private var scale
    @State private var image: UIImage?

    var body: some View {
        let shown = ImageMemory.get(url, maxPixel: size * scale) ?? image
        ZStack {
            if let shown { Image(uiImage: shown).resizable().scaledToFill() }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .task(id: url) {
            if ImageMemory.get(url, maxPixel: size * scale) != nil { return }
            image = await ImagePipeline.shared.image(for: url, maxPixel: size * scale)
        }
    }
}

// MARK: - Top-right button

/// Profile avatar at the top-right of every tab, like the Apple TV app.
/// - Most screens: a normal toolbar item. The system draws the Liquid Glass circle and keeps it steady while you scroll.
/// - Home (`logo: true`): the nav bar is hidden and the header is drawn here instead, the "pear." wordmark on the left and
///   a glass avatar button on the right. Both fade with the scroll position itself (no on/off switch and no timed
///   animation), so they follow your finger and nothing pops, lags or drops down.
struct ProfileToolbar: ViewModifier {
    var logo = false
    @Environment(ProfileStore.self) private var profiles
    @Environment(SimklStore.self) private var simkl
    @State private var showing = false
    /// 0 at the top of the page, 1 once scrolled `fadeDistance` points. Drives the Home header directly.
    @State private var progress: CGFloat = 0
    @State private var onScreen = true
    /// In the sidebar layout the profile lives in the sidebar, so no avatar button here.
    @Environment(\.wideLayout) private var wide

    @ViewBuilder
    func body(content: Content) -> some View {
        if wide {
            if logo { content.toolbar(.hidden, for: .navigationBar) } else { content }
        } else if logo { home(content) } else { standard(content) }
    }

    // MARK: Standard tabs

    private func standard(_ content: Content) -> some View {
        content
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showing = true } label: { ProfileAvatar(profile: profiles.active, size: 30) }
                        .accessibilityLabel("Profile")
                        .accessibilityValue(simkl.name(for: profiles.active))
                }
            }
            .sheet(isPresented: $showing) { ProfileSheet() }
    }

    // MARK: Home

    private func home(_ content: Content) -> some View {
        content
            // Continuous 0...1 value, rounded so SwiftUI only re-renders when it visibly changes.
            .onScrollGeometryChange(for: CGFloat.self) { g in
                let raw = (g.contentOffset.y + g.contentInsets.top) / Self.fadeDistance
                return (min(max(raw, 0), 1) * 100).rounded() / 100
            } action: { _, new in progress = new }
            .onAppear { onScreen = true }
            .onDisappear { onScreen = false }
            .toolbar(.hidden, for: .navigationBar)
            .overlay(alignment: .top) { homeHeader }
            .sheet(isPresented: $showing) { ProfileSheet() }
    }

    private var homeHeader: some View {
        HStack(alignment: .center, spacing: 0) {
            PearWordmark(height: Self.logoHeight)
                .shadow(color: .black.opacity(0.35), radius: 6)
                .padding(.leading, 20)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            Spacer(minLength: 0)
            Button { showing = true } label: {
                ProfileAvatar(profile: profiles.active, size: 32)
                    .frame(width: 46, height: 46)
                    .glassEffect(.regular.interactive(), in: .circle)
            }
            .buttonStyle(.plain)
            .padding(.trailing, 16)
            .allowsHitTesting(onScreen && progress < 0.5)
            .accessibilityLabel("Profile")
            .accessibilityValue(simkl.name(for: profiles.active))
        }
        .frame(height: Self.barHeight)
        .padding(.top, Self.statusBar)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .ignoresSafeArea()
        .opacity(onScreen ? 1 - progress : 0)
        .offset(y: -progress * 8)                       // drifts up with the content instead of dropping
        .animation(.easeOut(duration: 0.2), value: onScreen)
    }

    /// Scroll distance over which the Home header fades out.
    private static let fadeDistance: CGFloat = 60

    /// Height of the "pear." wordmark on Home (about 93 pt wide).
    private static let logoHeight: CGFloat = 32

    private static let barHeight: CGFloat = 44

    /// Status bar / Dynamic Island height only (not the nav bar).
    private static var statusBar: CGFloat {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        return scene?.keyWindow?.safeAreaInsets.top ?? 47
    }
}

extension View {
    /// Put this on the root content of each tab's NavigationStack.
    func profileToolbar(logo: Bool = false) -> some View { modifier(ProfileToolbar(logo: logo)) }
}

// MARK: - Picker sheet

enum ProfileTarget: Identifiable {
    case new
    case edit(Profile)
    var id: String {
        switch self {
        case .new: return "new"
        case .edit(let p): return p.id
        }
    }
}

/// "Who's watching?": tap a profile to switch, or enter Manage mode to edit, add and delete.
struct ProfileSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(ProfileStore.self) private var profiles
    @Environment(SimklStore.self) private var simkl
    @Environment(LibraryPrefs.self) private var libraryPrefs
    @Environment(ThemeStore.self) private var theme
    @State private var managing = false
    @State private var target: ProfileTarget?
    @State private var showProfile = false
    @State private var showDownloads = false
    @State private var showSimkl = false
    @Environment(DownloadManager.self) private var downloads
    @State private var detent: PresentationDetent = .medium

    private let columns = [GridItem(.adaptive(minimum: 96, maximum: 120), spacing: 16, alignment: .top)]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 28) {
                    if !managing { profileLink; simklLink; downloadsLink }
                    LazyVGrid(columns: columns, spacing: 22) {
                        ForEach(profiles.profiles) { tile($0) }
                        if profiles.canAdd { addTile }
                    }
                    Text(footnote)
                        .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    Button(managing ? "Done Editing" : "Manage Profiles") {
                        withAnimation(.snappy) { managing.toggle() }
                    }
                    .buttonStyle(.glass)
                }
                .padding(20)
            }
            .navigationTitle("Who's watching?")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } }
            }
            .navigationDestination(isPresented: $showProfile) { ProfileDetailView() }
            .navigationDestination(isPresented: $showDownloads) { DownloadsView() }
            .navigationDestination(isPresented: $showSimkl) { SimklLoginPage() }
        }
        .coversPages()
        .presentationDetents([.medium, .large], selection: $detent)
        .sheet(item: $target) { ProfileEditor(target: $0) }
    }

    /// Opens the active profile's page (stats, integrations, taste). The sheet grows to full height for it.
    private var profileLink: some View {
        Button { detent = .large; showProfile = true } label: {
            HStack(spacing: 12) {
                ProfileAvatar(profile: profiles.active, size: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text("View \(simkl.name(for: profiles.active))'s profile").font(.headline)
                    Text("Stats, integrations and taste").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.footnote.weight(.bold)).foregroundStyle(.secondary)
            }
            .padding(14)
            .frame(maxWidth: .infinity)
            .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
        .buttonStyle(PressableStyle())
        .accessibilityHint("Shows watch statistics for this profile")
    }

    /// Opens the Simkl login page: its own page, right under "View profile", not a card inside the profile.
    private var simklLink: some View {
        Button { detent = .large; showSimkl = true } label: {
            HStack(spacing: 12) {
                Image(systemName: "arrow.triangle.2.circlepath").font(.title3.weight(.semibold))
                    .foregroundStyle(theme.accent).frame(width: 44, height: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Simkl").font(.headline)
                    Text(simkl.isConnected ? "Connected" : "Log in to sync your library")
                        .font(.caption).foregroundStyle(simkl.isConnected ? Color.green : Color.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.footnote.weight(.bold)).foregroundStyle(.secondary)
            }
            .padding(14)
            .frame(maxWidth: .infinity)
            .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
        .buttonStyle(PressableStyle())
        .accessibilityHint("Log in to or manage your Simkl account")
    }

    /// Opens the Downloads page (offline files and the storage they use).
    private var downloadsLink: some View {
        Button { detent = .large; showDownloads = true } label: {
            HStack(spacing: 12) {
                Image(systemName: "arrow.down.circle.fill").font(.title2).foregroundStyle(theme.accent).frame(width: 44, height: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Downloads").font(.headline)
                    Text(downloads.records.isEmpty ? "Watch offline" : "\(downloads.records.count) saved · \(DownloadFiles.sizeString(downloads.usedBytes))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.footnote.weight(.bold)).foregroundStyle(.secondary)
            }
            .padding(14)
            .frame(maxWidth: .infinity)
            .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
        .buttonStyle(PressableStyle())
    }

    private var footnote: String {
        libraryPrefs.usesSimkl(simkl)
            ? "Watch history and Continue Watching are kept separately for each profile. This profile's library comes from Simkl, so profiles set to Simkl share it. Switch a profile to its own library in Settings."
            : "Each profile keeps its own watch history and library on this device. Connect Simkl in Settings to sync a library across devices."
    }

    private func tile(_ p: Profile) -> some View {
        let active = p.id == profiles.activeID
        return Button {
            if managing { target = .edit(p) }
            else { profiles.select(p.id); dismiss() }
        } label: {
            VStack(spacing: 9) {
                ProfileAvatar(profile: p, size: 76)
                    .overlay {
                        if managing {
                            ZStack {
                                Circle().fill(.black.opacity(0.5))
                                Image(systemName: "pencil").font(.title3.weight(.bold)).foregroundStyle(.white)
                            }
                        }
                    }
                    .padding(4)
                    .overlay { if active && !managing { Circle().strokeBorder(theme.accent, lineWidth: 3) } }
                Text(simkl.name(for: p)).font(.subheadline.weight(.semibold)).lineLimit(1)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(PressableStyle())
        .accessibilityLabel(simkl.name(for: p))
        .accessibilityHint(managing ? "Edit profile" : "Switch to this profile")
        .accessibilityAddTraits(active ? .isSelected : [])
    }

    private var addTile: some View {
        Button { target = .new } label: {
            VStack(spacing: 9) {
                Image(systemName: "plus").font(.title.weight(.semibold))
                    .frame(width: 76, height: 76)
                    .glassEffect(.regular.interactive(), in: .circle)
                    .padding(4)
                Text("Add Profile").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(PressableStyle())
    }
}

// MARK: - Editor

struct ProfileEditor: View {
    @Environment(SimklStore.self) private var simkl
    @State private var useSimkl = false
    let target: ProfileTarget
    @Environment(\.dismiss) private var dismiss
    @Environment(ProfileStore.self) private var profiles
    @State private var name: String
    @State private var colorHex: String
    @State private var symbol: String
    @State private var confirmDelete = false

    /// "" = the first letter of the name.
    private static let symbols = ["", "person.fill", "face.smiling.fill", "star.fill", "heart.fill", "bolt.fill",
                                  "flame.fill", "moon.fill", "sparkles", "gamecontroller.fill", "pawprint.fill",
                                  "leaf.fill", "film.fill", "tv.fill", "music.note"]

    init(target: ProfileTarget) {
        self.target = target
        switch target {
        case .new:
            _name = State(initialValue: "")
            _colorHex = State(initialValue: Theme.presets.randomElement()?.hex ?? Theme.defaultHex)
            _symbol = State(initialValue: "")
        case .edit(let p):
            _name = State(initialValue: p.name)
            _colorHex = State(initialValue: p.colorHex)
            _symbol = State(initialValue: p.symbol)
            _useSimkl = State(initialValue: p.simklIdentity == true)
        }
    }

    private var existing: Profile? {
        if case .edit(let p) = target { return p }
        return nil
    }
    private var trimmed: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var draft: Profile {
        Profile(id: "preview", name: trimmed.isEmpty ? "?" : trimmed, colorHex: colorHex, symbol: symbol,
                simklIdentity: useSimkl && simkl.account != nil ? true : nil)
    }
    private let grid = [GridItem(.adaptive(minimum: 44), spacing: 12)]

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ProfileAvatar(profile: draft, size: 96)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .listRowBackground(Color.clear)
                }
                if simkl.isConnected, let a = simkl.account {
                    Section {
                        Toggle(isOn: $useSimkl) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Use my Simkl name and picture")
                                Text(a.name).font(.footnote).foregroundStyle(.secondary)
                            }
                        }
                    } footer: {
                        Text("Shows your Simkl account's name and photo for this profile. Disconnecting Simkl brings back the name and icon below.")
                    }
                }
                Section("Name") {
                    TextField("Name", text: $name)
                        .textInputAutocapitalization(.words)
                        .submitLabel(.done)
                }
                Section("Colour") {
                    LazyVGrid(columns: grid, spacing: 12) {
                        ForEach(Theme.presets, id: \.hex) { p in
                            Button { colorHex = p.hex } label: {
                                Circle().fill(Color(hex: p.hex) ?? .gray).frame(width: 36, height: 36)
                                    .overlay(Circle().strokeBorder(.white.opacity(0.18), lineWidth: 1))
                                    .overlay {
                                        if colorHex.uppercased() == p.hex.uppercased() {
                                            Image(systemName: "checkmark").font(.footnote.weight(.black))
                                                .foregroundStyle((Color(hex: p.hex) ?? .gray).contrastingForeground)
                                        }
                                    }
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(p.name)
                        }
                    }
                    .padding(.vertical, 4)
                }
                Section("Icon") {
                    LazyVGrid(columns: grid, spacing: 12) {
                        ForEach(Self.symbols, id: \.self) { s in iconButton(s) }
                    }
                    .padding(.vertical, 4)
                }
                if existing != nil, profiles.profiles.count > 1 {
                    Section {
                        Button("Delete Profile", role: .destructive) { confirmDelete = true }
                    } footer: {
                        Text("Deletes this profile's watch history and local library.")
                    }
                }
            }
            .navigationTitle(existing == nil ? "New Profile" : "Edit Profile")
            .navigationBarTitleDisplayMode(.inline)
            .scrollDismissesKeyboard(.interactively)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save") { save() }.disabled(trimmed.isEmpty) }
            }
            .onChange(of: name) { _, v in if v.count > 20 { name = String(v.prefix(20)) } }
            .confirmationDialog("Delete \(existing?.name ?? "this profile")?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete Profile", role: .destructive) {
                    if let p = existing { profiles.delete(p.id) }
                    dismiss()
                }
            } message: {
                Text("Its watch history and local library will be removed. This can't be undone.")
            }
        }
        .presentationDetents([.large])
    }

    private func iconButton(_ s: String) -> some View {
        let on = symbol == s
        let fill: Color = on ? (Color(hex: colorHex) ?? .accentColor) : Color.primary.opacity(0.12)
        return Button { symbol = s } label: {
            ZStack {
                Circle().fill(fill)
                if s.isEmpty {
                    Text(draft.initial).font(.system(size: 17, weight: .bold, design: .rounded))
                } else {
                    Image(systemName: s).font(.system(size: 17, weight: .bold))
                }
            }
            .foregroundStyle(on ? (Color(hex: colorHex) ?? .accentColor).contrastingForeground : Color.primary)
            .frame(width: 40, height: 40)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(s.isEmpty ? "Initial" : s.replacingOccurrences(of: ".fill", with: ""))
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    private func save() {
        if var p = existing {
            p.name = name; p.colorHex = colorHex; p.symbol = symbol
            p.simklIdentity = useSimkl ? true : nil
            profiles.update(p)
        } else if var p = profiles.add(name: name, colorHex: colorHex, symbol: symbol), useSimkl {
            p.simklIdentity = true
            profiles.update(p)
        }
        dismiss()
    }
}
