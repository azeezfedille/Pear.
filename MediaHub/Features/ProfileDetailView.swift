import SwiftUI

/// The profile page: connected services, library counts, total watch time and a read on your taste.
/// Everything comes from the active profile's own data (history, library, manual "watched" marks, playback log).
struct ProfileDetailView: View {
    @Environment(ProfileStore.self) private var profiles
    @Environment(WatchHistory.self) private var history
    @Environment(LocalLibrary.self) private var library
    @Environment(SimklStore.self) private var simkl
    @Environment(LibraryPrefs.self) private var libraryPrefs
    @Environment(WatchLog.self) private var log
    @Environment(ThemeStore.self) private var theme
    @Environment(AddonStore.self) private var addons
    @Environment(DownloadManager.self) private var downloads
    @AppStorage("tmdb.key") private var tmdbKey = ""
    @AppStorage("tvdb.key") private var tvdbKey = ""
    @AppStorage("mdblist.key") private var mdbKey = ""
    @AppStorage("skip.enabled") private var skipEnabled = true
    @AppStorage("subs.online") private var subsOnline = true
    @State private var model = ProfileStatsModel()
    @State private var kind: StatKind = .all

    private var stats: ProfileStats { model.stats }

    /// Changes whenever something the statistics read changes, so the page refreshes itself.
    private var signature: String {
        let last = history.entries.first?.updated.timeIntervalSince1970 ?? 0
        let sk = simkl.library.map { "\($0.id)\($0.items.count)" }.joined()
        return "\(libraryPrefs.source(simkl).rawValue)|\(profiles.activeID)|\(last)|\(history.entries.count)|\(history.archive.count)|\(library.entries.count)|\(sk)|\(tmdbKey.isEmpty)"
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                header
                if model.loading && model.total > 0 { analysing }
                integrationsCard
                libraryCard
                downloadsCard
                tiles
                watchTimeCard
                if tmdbKey.isEmpty && !TMDBClient.hasProxy { tmdbNote }
                tasteSection
                whenCard
            }
            .padding(16)
        }
        .scrollIndicators(.hidden)
        .navigationTitle("Profile")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: signature) {
            await model.refresh(history: history, library: library, simkl: simkl, log: log,
                                includeSimkl: libraryPrefs.usesSimkl(simkl))
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(spacing: 10) {
            ProfileAvatar(profile: profiles.active, size: 96)
            Text(simkl.name(for: profiles.active)).font(.title2.bold())
            Text(headerSubtitle).font(.footnote).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 4)
    }

    private var headerSubtitle: String {
        let n = stats.titles.filter { $0.status != .planned }.count
        if !model.loaded { return "Crunching your numbers…" }
        return n == 0 ? "Nothing watched yet" : "\(n) title\(n == 1 ? "" : "s") watched or in progress"
    }

    private var analysing: some View {
        HStack(spacing: 10) {
            ProgressView()
            Text("Analysing your library… \(model.done)/\(model.total)").font(.footnote).foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 4)
    }

    // MARK: Cards

    private func card<C: View>(_ title: String, symbol: String, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(title, systemImage: symbol).font(.headline).foregroundStyle(.primary)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    // MARK: Integrations

    private struct Integration: Identifiable {
        let name: String; let symbol: String; let on: Bool
        var id: String { name }
    }

    private var integrations: [Integration] {
        [Integration(name: "TMDB", symbol: "film.stack", on: !tmdbKey.isEmpty || TMDBClient.hasProxy),
         Integration(name: "TheTVDB", symbol: "tv", on: !tvdbKey.isEmpty),
         Integration(name: "MDBList", symbol: "list.bullet", on: !mdbKey.isEmpty),
         Integration(name: "Simkl", symbol: "arrow.triangle.2.circlepath", on: simkl.isConnected),
         Integration(name: "TheIntroDB", symbol: "forward.end.fill", on: skipEnabled),
         Integration(name: "OpenSubtitles", symbol: "captions.bubble", on: subsOnline)]
    }

    private var libraryCard: some View {
        card("Library", symbol: "books.vertical.fill") { LibrarySourceControls() }
    }

    private var downloadsCard: some View {
        card("Downloads", symbol: "arrow.down.circle.fill") {
            HStack {
                Text(downloads.records.isEmpty ? "Nothing downloaded yet"
                     : "\(downloads.records.count) saved · \(DownloadFiles.sizeString(downloads.usedBytes)) used")
                    .font(.footnote).foregroundStyle(.secondary)
                Spacer()
                NavigationLink { DownloadsView() } label: { Text("Open").font(.footnote.weight(.semibold)) }
            }
        }
    }

    private var integrationsCard: some View {
        let list = integrations
        let on = list.filter(\.on).count
        return card("Integrations", symbol: "puzzlepiece.extension.fill") {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                ForEach(list) { i in
                    HStack(spacing: 8) {
                        Image(systemName: i.symbol).font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(i.on ? theme.accent : .secondary).frame(width: 18)
                        Text(i.name).font(.footnote.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.8)
                        Spacer(minLength: 0)
                        Image(systemName: i.on ? "checkmark.circle.fill" : "circle.dashed")
                            .font(.system(size: 14)).foregroundStyle(i.on ? Color.green : Color.secondary.opacity(0.6))
                    }
                    .padding(.horizontal, 12).padding(.vertical, 10)
                    .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(i.name), \(i.on ? "connected" : "not set up")")
                }
            }
            HStack {
                Text("\(on) of \(list.count) active · \(addons.enabledInstalledAddons.count) add-on\(addons.enabledInstalledAddons.count == 1 ? "" : "s")")
                    .font(.footnote).foregroundStyle(.secondary)
                Spacer()
                NavigationLink { IntegrationsView() } label: { Text("Manage").font(.footnote.weight(.semibold)) }
            }
        }
    }

    // MARK: Counts

    private var tiles: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
            tile("Watching", "eye.fill", stats.count(.watching), split(.watching))
            tile("Saved", "bookmark.fill", stats.count(.planned), split(.planned))
            tile("Completed", "checkmark.circle.fill", stats.count(.completed), split(.completed))
            tile("Episodes seen", "play.rectangle.fill", stats.episodesSeen, episodeCaption)
        }
    }

    private func split(_ s: StatTitle.Status) -> String {
        "\(stats.count(s, .shows)) shows · \(stats.count(s, .movies)) movies"
    }

    private var episodeCaption: String {
        let shows = stats.titles.filter { $0.isSeries && $0.episodes > 0 }.count
        return "across \(shows) show\(shows == 1 ? "" : "s")"
    }

    private func tile(_ title: String, _ symbol: String, _ value: Int, _ caption: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: symbol).font(.system(size: 15, weight: .bold)).foregroundStyle(theme.accent)
            Text(value.formatted()).font(.system(size: 34, weight: .bold, design: .rounded)).monospacedDigit()
                .contentTransition(.numericText())
            Text(title).font(.subheadline.weight(.semibold))
            Text(caption).font(.caption).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .animation(.smooth, value: value)
        .accessibilityElement(children: .combine)
    }

    // MARK: Watch time

    private func duration(_ minutes: Double) -> String {
        let m = Int(minutes.rounded())
        if m < 60 { return "\(m)m" }
        let h = m / 60, r = m % 60
        if h < 24 { return r == 0 ? "\(h)h" : "\(h)h \(r)m" }
        let d = h / 24, hh = h % 24
        return hh == 0 ? "\(d)d" : "\(d)d \(hh)h"
    }

    private var watchTimeCard: some View {
        let minutes = stats.totalMinutes
        let days = minutes / 1440
        let number = days >= 10 ? String(format: "%.0f", days) : days >= 1 ? String(format: "%.1f", days) : String(format: "%.2f", days)
        return VStack(alignment: .leading, spacing: 14) {
            Label("Total watch time", systemImage: "clock.fill").font(.headline)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(number).font(.system(size: 56, weight: .heavy, design: .rounded)).monospacedDigit()
                Text(abs(days - 1) < 0.005 ? "day" : "days").font(.title3.weight(.semibold)).foregroundStyle(.white.opacity(0.8))
            }
            Text("\(Int((minutes / 60).rounded()).formatted()) hours · \(Int(minutes.rounded()).formatted()) minutes")
                .font(.subheadline).foregroundStyle(.white.opacity(0.75))
            Divider().overlay(.white.opacity(0.25))
            HStack(alignment: .top) {
                miniStat("Shows", duration(stats.minutes(.shows)))
                Spacer()
                miniStat("Movies", duration(stats.minutes(.movies)))
                Spacer()
                miniStat(stats.averageDaily?.tracked == false ? "Avg / day (est.)" : "Avg / day",
                         stats.averageDaily.map { duration($0.minutes) } ?? "–")
            }
            if let a = stats.averageDaily {
                Text(a.tracked ? "Average per day over the last 30 days of playback."
                               : "Estimated from your library. Exact daily averages build up as you watch in the app.")
                    .font(.caption).foregroundStyle(.white.opacity(0.65))
            }
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background { RoundedRectangle(cornerRadius: 26, style: .continuous).fill(theme.gradient).opacity(0.85) }
    }

    private func miniStat(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.title3.weight(.bold)).monospacedDigit()
            Text(title).font(.caption).foregroundStyle(.white.opacity(0.7))
        }
    }

    private var tmdbNote: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "info.circle.fill").foregroundStyle(.secondary)
            Text("Add a TMDB key under Integrations to unlock genre insights and exact episode counts and runtimes. Until then, runtimes are estimated.")
                .font(.footnote).foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    // MARK: Taste

    private var tasteSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Your taste").font(.title3.bold())
                Spacer()
            }
            Picker("Show", selection: $kind) {
                ForEach(StatKind.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            genresCard
            eraCard
        }
        .padding(.top, 6)
    }

    private func bars(_ shares: [ProfileStats.Share]) -> some View {
        VStack(spacing: 12) {
            ForEach(shares) { s in
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text(s.id).font(.subheadline.weight(.medium))
                        Spacer()
                        Text("\(Int(s.percent.rounded()))%").font(.subheadline.weight(.semibold)).monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    GeometryReader { g in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.white.opacity(0.08))
                            if s.id == "Other" { Capsule().fill(Color.white.opacity(0.3)).frame(width: max(6, g.size.width * s.percent / 100)) }
                            else { Capsule().fill(theme.gradient).frame(width: max(6, g.size.width * s.percent / 100)) }
                        }
                    }
                    .frame(height: 8)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(s.id), \(Int(s.percent.rounded())) percent")
            }
        }
    }

    private var genresCard: some View {
        let shares = stats.genreShares(kind)
        return card("Favourite genres", symbol: "theatermasks.fill") {
            if shares.isEmpty {
                Text(tmdbKey.isEmpty && !TMDBClient.hasProxy ? "Needs a TMDB key." : model.loading ? "Working it out…" : "Not enough watched yet.")
                    .font(.footnote).foregroundStyle(.secondary)
            } else {
                bars(shares)
                Text("Weighted by time spent, so a long series counts for more than a short film.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var eraCard: some View {
        let era = stats.era(kind)
        return card("Older or newer?", symbol: "calendar") {
            if let era {
                bars(era.buckets)
                Divider()
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verdict(era)).font(.subheadline.weight(.semibold))
                        Text("\(Int((era.recentShare * 100).rounded()))% of your watching is from the last 5 years")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if let m = era.medianYear {
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(String(m)).font(.title3.bold()).monospacedDigit()
                            Text("median year").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            } else {
                Text("Not enough watched yet.").font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    private func verdict(_ era: ProfileStats.Era) -> String {
        guard let m = era.medianYear else { return "" }
        let age = Calendar.current.component(.year, from: .now) - m
        if age <= 4 { return "You watch what's new" }
        if age <= 10 { return "Mostly recent releases" }
        if age <= 20 { return "A mix of modern and older" }
        return "Drawn to older classics"
    }

    // MARK: Time of day

    private func hourLabel(_ h: Int) -> String {
        let h12 = h % 12 == 0 ? 12 : h % 12
        return "\(h12) \(h < 12 ? "AM" : "PM")"
    }

    private var whenCard: some View {
        card("When you watch", symbol: "clock.badge.fill") {
            let weights = stats.hourSeconds
            let peakValue = weights.max() ?? 0
            if stats.hoursSource == .none || peakValue <= 0 {
                Text("Watch something and your favourite times of day will show up here.")
                    .font(.footnote).foregroundStyle(.secondary)
            } else {
                let peak = stats.peakHour
                HStack(alignment: .bottom, spacing: 3) {
                    ForEach(0..<24, id: \.self) { h in
                        Capsule()
                            .fill(h == peak ? AnyShapeStyle(theme.gradient) : AnyShapeStyle(theme.accent.opacity(0.35)))
                            .frame(height: max(4, CGFloat(weights[h] / peakValue) * 90))
                    }
                }
                .frame(height: 90, alignment: .bottom)
                HStack {
                    Text("12a"); Spacer(); Text("6a"); Spacer(); Text("12p"); Spacer(); Text("6p"); Spacer(); Text("11p")
                }
                .font(.caption2).foregroundStyle(.secondary)

                if let peak {
                    Text("Peak hour: \(hourLabel(peak)) – \(hourLabel((peak + 1) % 24))").font(.subheadline.weight(.semibold))
                }
                let parts = stats.dayParts
                let best = parts.max { $0.percent < $1.percent }
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                    ForEach(parts) { p in
                        HStack(spacing: 10) {
                            Image(systemName: p.symbol).font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(p.id == best?.id ? theme.accent : .secondary).frame(width: 22)
                            VStack(alignment: .leading, spacing: 1) {
                                Text("\(p.id) · \(Int(p.percent.rounded()))%").font(.footnote.weight(.semibold))
                                Text(p.range).font(.caption2).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(10)
                        .background(p.id == best?.id ? theme.accent.opacity(0.18) : Color.white.opacity(0.06),
                                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                }
                Text(stats.hoursSource == .tracked ? "Based on the time you've actually spent playing in the app."
                                                   : "Based on when you last watched each title. Gets more precise as you watch.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
