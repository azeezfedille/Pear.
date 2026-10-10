import SwiftUI

extension DownloadFiles {
    static func sizeString(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    /// "3.2 MB/s"
    static func speedString(_ bytesPerSecond: Double) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytesPerSecond), countStyle: .file) + "/s"
    }
}

/// Live transfer rate of one download. Shows nothing until the first reading arrives, and re-checks every couple of
/// seconds so a transfer that stops sending data reads "Stalled" instead of freezing on its last number.
struct DownloadSpeedText: View {
    @Environment(DownloadManager.self) private var downloads
    let id: String
    /// Text placed in front of the speed (e.g. " · ") so nothing dangles while there is no reading yet.
    var prefix = ""

    var body: some View {
        if let s = downloads.speeds[id] {
            TimelineView(.periodic(from: .now, by: 2)) { ctx in
                let stalled = ctx.date.timeIntervalSince(s.at) > 5 || s.bytesPerSecond < 1
                Text(prefix + (stalled ? "Stalled" : DownloadFiles.speedString(s.bytesPerSecond)))
                    .monospacedDigit()
            }
        }
    }
}

/// Everything saved on this device, grouped by show / movie (and by season inside a show), with the storage it uses.
/// A plain view (no NavigationStack of its own): it is pushed from Library and from the profile sheet / page.
struct DownloadsView: View {
    @Environment(DownloadManager.self) private var downloads
    @Environment(Connectivity.self) private var connectivity
    @Environment(ThemeStore.self) private var theme
    @State private var playRequest: PlayRequest?
    @State private var pending: Pending?

    private struct Pending {
        let title: String, button: String, message: String
        let run: () -> Void
    }

    private struct SeasonGroup: Identifiable {
        let number: Int
        let records: [DownloadRecord]
        var id: Int { number }
        var bytes: Int64 { records.reduce(0) { $0 + $1.bytes } }
    }

    private struct Show: Identifiable {
        let id: String                      // imdb id
        let item: MetaPreview
        let records: [DownloadRecord]
        var bytes: Int64 { records.reduce(0) { $0 + $1.bytes } }
        var isSeries: Bool { records.contains(where: \.isEpisode) }
        var seasons: [SeasonGroup] {
            Dictionary(grouping: records.filter(\.isEpisode), by: { $0.season ?? 0 })
                .map { SeasonGroup(number: $0.key, records: $0.value.sorted { ($0.episode ?? 0) < ($1.episode ?? 0) }) }
                .sorted { $0.number < $1.number }
        }
    }

    private var shows: [Show] {
        Dictionary(grouping: downloads.records, by: \.imdb)
            .map { Show(id: $0.key, item: $0.value[0].item, records: $0.value) }
            .sorted { $0.item.name.localizedCaseInsensitiveCompare($1.item.name) == .orderedAscending }
    }

    // MARK: Body

    var body: some View {
        let list = shows
        List {
            if !list.isEmpty { storageSection }
            ForEach(list) { show in
                Section {
                    if show.isSeries {
                        ForEach(show.seasons) { sn in
                            if sn.records.count > 1 { seasonRow(show, sn) }
                            ForEach(sn.records) { row($0) }
                        }
                    } else {
                        ForEach(show.records) { row($0) }
                    }
                } header: { showHeader(show) }
            }
        }
        .listStyle(.insetGrouped)
        .overlay {
            if list.isEmpty {
                ContentUnavailableView("No downloads", systemImage: "arrow.down.circle",
                    description: Text("Long-press an episode, a season or a movie's Play button and choose Download."))
            }
        }
        .navigationTitle("Downloads")
        .navigationBarTitleDisplayMode(.large)
        .confirmationDialog(pending?.title ?? "", isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }),
                            titleVisibility: .visible, presenting: pending) { p in
            Button(p.button, role: .destructive) { p.run() }
        } message: { p in Text(p.message) }
        .fullScreenCover(item: $playRequest) { r in
            PlayerScreen(request: r, provider: downloads.provider(for: r.imdb), onClose: { playRequest = nil })
        }
    }

    // MARK: Storage

    private var storageSection: some View {
        let used = downloads.usedBytes
        let free = DownloadFiles.freeBytes
        let count = downloads.records.count
        return Section {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(DownloadFiles.sizeString(used)).font(.title.bold())
                    Text("used").foregroundStyle(.secondary)
                    Spacer()
                    Text("\(count) item\(count == 1 ? "" : "s")").font(.footnote).foregroundStyle(.secondary)
                }
                if let free {
                    ProgressView(value: Double(used), total: Double(max(used + free, 1))).tint(theme.accent)
                    Text("\(DownloadFiles.sizeString(free)) free on this device").font(.footnote).foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)
            if downloads.hasPausable {
                Button("Pause All", systemImage: "pause.circle") { downloads.pauseAll() }
            }
            if downloads.hasPaused {
                Button("Resume All", systemImage: "play.circle") { downloads.resumeAll() }
            }
            Button("Delete All Downloads", systemImage: "trash", role: .destructive) {
                pending = Pending(title: "Delete all downloads?", button: "Delete \(count) item\(count == 1 ? "" : "s")",
                                  message: "Frees \(DownloadFiles.sizeString(used)). Anything still downloading is cancelled.",
                                  run: { downloads.deleteAll() })
            }
        }
    }

    // MARK: Headers

    private func showHeader(_ show: Show) -> some View {
        let n = show.records.count
        let sub = show.isSeries ? "\(n) episode\(n == 1 ? "" : "s") · \(DownloadFiles.sizeString(show.bytes))"
                                : DownloadFiles.sizeString(show.bytes)
        return HStack(spacing: 12) {
            RemoteImage(url: show.item.posterURL, size: 60).frame(width: 40, height: 60)
                .background(Color.white.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(show.item.name).font(.headline).foregroundStyle(.primary).lineLimit(2)
                Text(sub).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Menu {
                Button("Delete All Downloads", systemImage: "trash", role: .destructive) { confirm(show) }
            } label: {
                Image(systemName: "ellipsis.circle").font(.title3).foregroundStyle(.secondary).frame(width: 36, height: 36)
            }
        }
        .textCase(nil)
        .padding(.vertical, 4)
    }

    private func seasonRow(_ show: Show, _ sn: SeasonGroup) -> some View {
        let n = sn.records.count
        return HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(sn.number == 0 ? "Specials" : "Season \(sn.number)").font(.headline)
                Text("\(n) episode\(n == 1 ? "" : "s") · \(DownloadFiles.sizeString(sn.bytes))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Menu {
                Button("Delete \(n) Episodes", systemImage: "trash", role: .destructive) { confirm(show, sn) }
            } label: {
                Image(systemName: "ellipsis.circle").font(.title3).foregroundStyle(.secondary).frame(width: 36, height: 36)
            }
        }
        .swipeActions(edge: .trailing) {
            Button("Delete \(n) Episodes", systemImage: "trash", role: .destructive) { confirm(show, sn) }
        }
        .contextMenu {
            Button("Delete \(n) Episodes", systemImage: "trash", role: .destructive) { confirm(show, sn) }
        }
    }

    // MARK: Rows (episodes and movies)

    private func title(_ r: DownloadRecord) -> String {
        guard r.isEpisode else { return r.item.name }
        return "E\(r.episode ?? 0) · \(r.episodeTitle ?? "Episode \(r.episode ?? 0)")"
    }

    private func row(_ r: DownloadRecord) -> some View {
        HStack(spacing: 4) {
            Button {
                switch r.state {
                case .done: play(r)
                case .failed: downloads.retry(r.id)
                case .paused: downloads.resume(r.id)
                case .queued, .downloading: break
                }
            } label: {
                rowLabel(r)
            }
            .buttonStyle(.plain)
            transferControl(r)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(r.state == .done ? "Delete" : "Remove", systemImage: "trash", role: .destructive) { downloads.delete(r.id) }
        }
        .contextMenu {
            if r.state == .done { Button("Play", systemImage: "play.fill") { play(r) } }
            if r.state == .failed { Button("Retry", systemImage: "arrow.clockwise") { downloads.retry(r.id) } }
            if r.state == .queued || r.state == .downloading { Button("Pause", systemImage: "pause.fill") { downloads.pause(r.id) } }
            if r.state == .paused { Button("Resume", systemImage: "play.fill") { downloads.resume(r.id) } }
            Button(r.state == .done ? "Delete Download" : "Cancel Download",
                   systemImage: r.state == .done ? "trash" : "xmark.circle", role: .destructive) { downloads.delete(r.id) }
        }
    }

    /// Pause / resume button at the end of a row that is still transferring (or waiting, or paused).
    @ViewBuilder private func transferControl(_ r: DownloadRecord) -> some View {
        switch r.state {
        case .queued, .downloading:
            Button { downloads.pause(r.id) } label: { controlIcon("pause.circle.fill") }
                .buttonStyle(.plain).accessibilityLabel("Pause download")
        case .paused:
            Button { downloads.resume(r.id) } label: { controlIcon("play.circle.fill") }
                .buttonStyle(.plain).accessibilityLabel("Resume download")
        case .done, .failed:
            EmptyView()
        }
    }

    private func controlIcon(_ name: String) -> some View {
        Image(systemName: name).font(.title2).symbolRenderingMode(.hierarchical)
            .foregroundStyle(theme.accent).frame(width: 44, height: 44).contentShape(Rectangle())
    }

    private func rowLabel(_ r: DownloadRecord) -> some View {
        HStack(spacing: 12) {
            RemoteImage(url: r.thumb ?? r.item.backdropURL, size: 120).frame(width: 96, height: 54)
                .background(Color.white.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay {
                    if r.state == .done {
                        Image(systemName: "play.fill").font(.caption).foregroundStyle(.white.opacity(0.9)).shadow(radius: 3)
                    }
                }
            VStack(alignment: .leading, spacing: 4) {
                Text(title(r)).font(.subheadline.weight(.semibold)).lineLimit(2).multilineTextAlignment(.leading)
                status(r)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    @ViewBuilder private func status(_ r: DownloadRecord) -> some View {
        switch r.state {
        case .done:
            Label(DownloadFiles.sizeString(r.bytes), systemImage: "arrow.down.circle.fill")
                .font(.caption).foregroundStyle(.secondary)
        case .downloading:
            VStack(alignment: .leading, spacing: 4) {
                ProgressView(value: r.progress).tint(theme.accent)
                HStack(spacing: 8) {
                    Text(r.expectedBytes > 0
                         ? "\(Int(r.progress * 100))% · \(DownloadFiles.sizeString(r.bytes)) of \(DownloadFiles.sizeString(r.expectedBytes))"
                         : DownloadFiles.sizeString(r.bytes))
                    Spacer(minLength: 0)
                    DownloadSpeedText(id: r.id)
                }
                .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                .lineLimit(1).minimumScaleFactor(0.8)
            }
        case .paused:
            VStack(alignment: .leading, spacing: 4) {
                if r.progress > 0 { ProgressView(value: r.progress).tint(Color.secondary) }
                Text(r.progress > 0 && r.expectedBytes > 0
                     ? "Paused · \(Int(r.progress * 100))% · \(DownloadFiles.sizeString(r.bytes)) of \(DownloadFiles.sizeString(r.expectedBytes))"
                     : "Paused · tap to resume")
                    .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    .lineLimit(1).minimumScaleFactor(0.8)
            }
        case .queued:
            Text(connectivity.isOnline == false ? "Waiting for connection" : "Waiting…")
                .font(.caption).foregroundStyle(.secondary)
        case .failed:
            Text("\(r.error ?? "Failed") · tap to retry").font(.caption).foregroundStyle(.red)
        }
    }

    // MARK: Actions

    private func play(_ r: DownloadRecord) {
        if let req = r.playRequest() { playRequest = req }
    }

    private func confirm(_ show: Show) {
        let n = show.records.count
        pending = Pending(title: "Delete \(show.item.name)?", button: "Delete \(n) download\(n == 1 ? "" : "s")",
                          message: "Frees \(DownloadFiles.sizeString(show.bytes)).",
                          run: { downloads.delete(imdb: show.id) })
    }

    private func confirm(_ show: Show, _ sn: SeasonGroup) {
        let n = sn.records.count
        let name = sn.number == 0 ? "Specials" : "Season \(sn.number)"
        pending = Pending(title: n == 1 ? "Delete episode?" : "Delete \(name)?", button: "Delete \(n) episode\(n == 1 ? "" : "s")",
                          message: "Frees \(DownloadFiles.sizeString(sn.bytes)).",
                          run: { downloads.delete(imdb: show.id, season: sn.number) })
    }
}

// MARK: - Offline episode browsing for the player

extension DownloadManager {
    private func doneEpisodes(_ imdb: String) -> [DownloadRecord] {
        records(imdb: imdb).filter { $0.state == .done && $0.isEpisode }
            .sorted { ($0.season ?? 0, $0.episode ?? 0) < ($1.season ?? 0, $1.episode ?? 0) }
    }

    private static func episodeItem(_ r: DownloadRecord) -> EpisodeItem {
        EpisodeItem(id: r.episode ?? 0, name: r.episodeTitle ?? "Episode \(r.episode ?? 0)", image: r.thumb, runtime: r.runtime)
    }

    /// Lets the player's episode panel and "next episode" work from downloaded files only.
    func provider(for imdb: String) -> EpisodeProvider? {
        let eps = doneEpisodes(imdb)
        guard !eps.isEmpty else { return nil }
        let seasons = Set(eps.compactMap(\.season)).sorted().map {
            SeasonOption(id: $0, title: $0 == 0 ? "Specials" : "Season \($0)")
        }
        return EpisodeProvider(
            seasons: seasons,
            episodes: { [weak self] s in
                (self?.doneEpisodes(imdb) ?? []).filter { $0.season == s }.map(Self.episodeItem)
            },
            resolve: { [weak self] s, ep, _ in
                self?.record(imdb: imdb, season: s, episode: ep.id)?.playRequest()
            },
            next: { [weak self] current in
                guard let self, let s = current.season, let e = current.episode,
                      let n = self.doneEpisodes(imdb).first(where: { ($0.season ?? 0, $0.episode ?? 0) > (s, e) }),
                      let ns = n.season else { return nil }
                return NextEpisode(season: ns, episode: Self.episodeItem(n))
            })
    }
}
