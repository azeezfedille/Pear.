import Foundation
import Observation

// MARK: - Model

struct DownloadRecord: Codable, Identifiable, Hashable {
    enum State: String, Codable { case queued, downloading, paused, failed, done }

    /// "<imdb>|movie" or "<imdb>|<season>:<episode>"
    let id: String
    let item: MetaPreview
    let imdb: String
    let season: Int?
    let episode: Int?
    var episodeTitle: String?
    var thumb: URL?
    var logo: URL?
    var runtime: Int?
    /// Which add-on / release this came from (later episodes of a season reuse it).
    var sourceAddonID: String?
    var sourceSignature: String?
    /// Nil until resolved: season downloads resolve each episode right before it starts, so links never go stale in the queue.
    var remoteURL: URL?
    var headers: [String: String] = [:]
    /// File name inside the Downloads folder (never an absolute path: the app container path can change).
    var fileName: String?
    var bytes: Int64 = 0
    var expectedBytes: Int64 = 0
    var progress: Double = 0
    var state: State = .queued
    var error: String?
    var added: Date = .now

    var isEpisode: Bool { season != nil }

    static func key(imdb: String, season: Int?, episode: Int?) -> String {
        guard let season, let episode else { return "\(imdb)|movie" }
        return "\(imdb)|\(season):\(episode)"
    }

    /// Ready-to-play request for the offline file. Same key format as online playback, so watch history stays consistent.
    func playRequest() -> PlayRequest? {
        guard state == .done, let f = fileName else { return nil }
        return PlayRequest(url: DownloadFiles.url(for: f), headers: [:], item: item,
                           key: isEpisode ? "\(season ?? 0):\(episode ?? 0)" : "movie", imdb: imdb,
                           season: season, episode: episode, episodeTitle: episodeTitle,
                           logo: logo, thumb: thumb ?? item.backdropURL,
                           sourceAddonID: sourceAddonID, sourceSignature: sourceSignature, p2p: nil)
    }
}

/// Live transfer rate of an in-flight download. Kept out of `DownloadRecord` on purpose: it is meaningless after a
/// relaunch and must not change the saved index format.
struct DownloadSpeed: Equatable {
    var bytesPerSecond: Double
    var at: Date
}

// MARK: - HTTPS-only gate

extension StreamItem {
    /// Only plain HTTPS add-on links can be saved. Torrents (P2P) never can, and HLS playlists aren't a single file.
    var downloadURL: URL? {
        guard let s = url, let u = URL(string: s), u.scheme?.lowercased() == "https",
              u.pathExtension.lowercased() != "m3u8" else { return nil }
        return u
    }
    var isDownloadable: Bool { downloadURL != nil }
}

// MARK: - Files

enum DownloadFiles {
    static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Downloads", isDirectory: true)
    }
    static var index: URL { directory.appendingPathComponent("index.json") }
    static func url(for fileName: String) -> URL { directory.appendingPathComponent(fileName) }
    /// Where a paused transfer's resume data is kept, next to the file it will become.
    static func resumeURL(for fileName: String) -> URL { directory.appendingPathComponent(fileName + ".resume") }

    static func prepare() {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    static func excludeFromBackup(_ url: URL) {
        var u = url
        var v = URLResourceValues(); v.isExcludedFromBackup = true
        try? u.setResourceValues(v)
    }

    /// Free space the system would let us use (includes purgeable space).
    static var freeBytes: Int64? {
        try? URL(fileURLWithPath: NSHomeDirectory())
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage
    }
}

// MARK: - Source resolving (HTTPS only)

enum DownloadResolver {
    /// Preferred add-on + release (same source as the rest of the season), then the pinned source, then the first
    /// HTTPS stream from any add-on. Never returns a torrent.
    @MainActor
    static func resolve(imdb: String, type: String, season: Int?, episode: Int?,
                        preferAddonID: String?, preferSignature: String?,
                        addons: [Addon], pins: PinnedSources?) async -> (addon: Addon, stream: StreamItem, url: URL)? {
        let sid = (season != nil && episode != nil) ? "\(imdb):\(season!):\(episode!)" : imdb
        let groups = await AddonClient.shared.streams(for: sid, type: type, addons: addons)
        let ordered = addons.compactMap { a in groups.first(where: { $0.0.id == a.id }) }

        func match(_ addonID: String, _ signature: String?) -> (Addon, StreamItem, URL)? {
            guard let g = ordered.first(where: { $0.0.id == addonID }) else { return nil }
            let ok = g.1.filter(\.isDownloadable)
            guard let s = ok.first(where: { $0.signature == signature }) ?? ok.first, let u = s.downloadURL else { return nil }
            return (g.0, s, u)
        }

        if let a = preferAddonID, let r = match(a, preferSignature) { return r }
        if let pin = pins?.pin(for: imdb), let r = match(pin.addonID, pin.signature) { return r }
        for g in ordered { if let s = g.1.first(where: \.isDownloadable), let u = s.downloadURL { return (g.0, s, u) } }
        return nil
    }
}

// MARK: - Manager

@MainActor @Observable
final class DownloadManager {
    static let shared = DownloadManager()

    private(set) var records: [DownloadRecord] = []
    /// Smoothed download speed per record id, only while that record is downloading.
    private(set) var speeds: [String: DownloadSpeed] = [:]
    /// Set by the app delegate when iOS relaunches us for finished background transfers.
    @ObservationIgnored var backgroundCompletion: (() -> Void)?
    @ObservationIgnored private var session: URLSession!
    @ObservationIgnored private var store: AddonStore?
    @ObservationIgnored private var pins: PinnedSources?
    @ObservationIgnored private var pumping = false
    /// Transfers that were started from saved resume data. If one of those fails, the saved bytes were no good
    /// (link expired, file changed on the server), so it starts over once instead of going straight to "failed".
    @ObservationIgnored private var resumedNames: Set<String> = []

    private init() {
        DownloadFiles.prepare()
        records = Self.loadIndex()
        let cfg = URLSessionConfiguration.background(withIdentifier: "com.mediahub.pear.downloads")
        cfg.sessionSendsLaunchEvents = true
        cfg.isDiscretionary = false
        cfg.httpMaximumConnectionsPerHost = 1
        session = URLSession(configuration: cfg, delegate: SessionDelegate(), delegateQueue: nil)
        reconcile()
    }

    func configure(store: AddonStore, pins: PinnedSources) {
        self.store = store; self.pins = pins
        pump()
    }

    // MARK: Lookup

    func record(imdb: String, season: Int?, episode: Int?) -> DownloadRecord? {
        let id = DownloadRecord.key(imdb: imdb, season: season, episode: episode)
        return records.first { $0.id == id }
    }

    func isDownloaded(imdb: String, season: Int?, episode: Int?) -> Bool {
        record(imdb: imdb, season: season, episode: episode)?.state == .done
    }

    /// Bytes on disk (finished files plus what in-progress ones have written so far).
    var usedBytes: Int64 { records.reduce(0) { $0 + $1.bytes } }
    var hasActive: Bool { records.contains { $0.state == .queued || $0.state == .downloading } }

    func records(imdb: String, season: Int? = nil) -> [DownloadRecord] {
        records.filter { $0.imdb == imdb && (season == nil || $0.season == season) }
    }

    // MARK: Adding

    /// Queues one title/episode. With a `stream` (picked in the sources sheet) it must be HTTPS; without one, the
    /// source is resolved automatically when its turn comes. Returns false when the stream can't be downloaded.
    @discardableResult
    func enqueue(item: MetaPreview, imdb: String, season: Int?, episode: Int?, episodeTitle: String?,
                 thumb: URL?, logo: URL?, runtime: Int?, addonID: String? = nil, stream: StreamItem? = nil,
                 persist: Bool = true) -> Bool {
        var url: URL?
        if let stream {
            guard let u = stream.downloadURL else { return false }   // torrents and non-HTTPS never download
            url = u
        }
        let id = DownloadRecord.key(imdb: imdb, season: season, episode: episode)
        if let i = records.firstIndex(where: { $0.id == id }) {
            guard records[i].state == .failed else { return true }  // already queued / downloading / done
            discardFile(records[i])
            records.remove(at: i)
        }
        records.append(DownloadRecord(id: id, item: item, imdb: imdb, season: season, episode: episode,
                                      episodeTitle: episodeTitle, thumb: thumb, logo: logo, runtime: runtime,
                                      sourceAddonID: stream == nil ? nil : addonID,
                                      sourceSignature: stream?.signature,
                                      remoteURL: url, headers: stream?.requestHeaders ?? [:]))
        // A whole season passes `persist: false` and saves once at the end instead of once per episode.
        if persist { save(); pump() }
        return true
    }

    /// Queues every aired episode of a season, in order. They download one at a time, episode by episode.
    func enqueueSeason(item: MetaPreview, imdb: String, season: Int, episodes: [EpisodeItem], logo: URL?) {
        let today = Self.isoDay.string(from: .now)
        for ep in episodes {
            if let d = ep.airDate, !d.isEmpty, d > today { continue }   // not aired yet
            enqueue(item: item, imdb: imdb, season: season, episode: ep.id, episodeTitle: ep.name,
                    thumb: ep.image ?? item.backdropURL, logo: logo, runtime: ep.runtime, persist: false)
        }
        save(); pump()
    }

    private static let isoDay: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"; return f
    }()

    func retry(_ id: String) {
        guard let i = records.firstIndex(where: { $0.id == id }), records[i].state == .failed else { return }
        records[i].state = .queued; records[i].error = nil; records[i].progress = 0; records[i].bytes = 0
        speeds[id] = nil
        save(); pump()
    }

    // MARK: Pause / resume

    /// Pauses one download (or holds a queued one). A running transfer is cancelled with resume data, so resuming
    /// continues from the bytes already on disk when the server allows it, and starts over when it doesn't.
    /// The rest of the queue carries on.
    func pause(_ id: String) {
        guard let i = records.firstIndex(where: { $0.id == id }), hold(i) else { return }
        save(); pump()
    }

    func resume(_ id: String) {
        guard let i = records.firstIndex(where: { $0.id == id }), records[i].state == .paused else { return }
        records[i].state = .queued; records[i].error = nil
        save(); pump()
    }

    /// Everything that is downloading or waiting stops; nothing new starts in between.
    func pauseAll() {
        // Waiting items first, so the queue can't hand a slot to one of them while the running one is stopping.
        var changed = false
        for i in records.indices where records[i].state == .queued { changed = hold(i) || changed }
        for i in records.indices where records[i].state == .downloading { changed = hold(i) || changed }
        if changed { save() }
    }

    func resumeAll() {
        var changed = false
        for i in records.indices where records[i].state == .paused {
            records[i].state = .queued; records[i].error = nil; changed = true
        }
        if changed { save(); pump() }
    }

    var hasPausable: Bool { records.contains { $0.state == .queued || $0.state == .downloading } }
    var hasPaused: Bool { records.contains { $0.state == .paused } }

    /// Marks one record paused and stops its transfer. Returns false when there was nothing to pause.
    @discardableResult
    private func hold(_ i: Int) -> Bool {
        let id = records[i].id
        switch records[i].state {
        case .queued:
            records[i].state = .paused
        case .downloading:
            let name = records[i].fileName
            records[i].state = .paused
            speeds[id] = nil
            session.getAllTasks { [weak self] tasks in
                let task = tasks.first { $0.taskDescription == name } as? URLSessionDownloadTask
                guard let task else { Task { @MainActor in self?.pauseSaved(id, nil) }; return }
                task.cancel(byProducingResumeData: { data in
                    Task { @MainActor in self?.pauseSaved(id, data) }
                })
            }
        default:
            return false
        }
        return true
    }

    /// The system hands back resume data once the cancel has landed. No data (the server can't resume) is fine: the
    /// download then simply starts over when resumed.
    private func pauseSaved(_ id: String, _ data: Data?) {
        guard let i = records.firstIndex(where: { $0.id == id }), records[i].state == .paused,
              let f = records[i].fileName else { return }
        if let data {
            try? data.write(to: DownloadFiles.resumeURL(for: f), options: .atomic)
        } else {
            // Nothing to continue from, so don't show progress that resuming would throw away.
            records[i].bytes = 0; records[i].progress = 0
            save()
        }
    }

    /// Called when the connection comes back: queued items were waiting for it.
    func networkReturned() { pump() }

    // MARK: Deleting (also cancels anything still in flight)

    func delete(_ id: String) { remove { $0.id == id } }
    func delete(imdb: String, season: Int) { remove { $0.imdb == imdb && $0.season == season } }
    func delete(imdb: String) { remove { $0.imdb == imdb } }
    func deleteAll() { remove { _ in true } }

    private func remove(where match: (DownloadRecord) -> Bool) {
        let gone = records.filter(match)
        guard !gone.isEmpty else { return }
        let names = Set(gone.compactMap(\.fileName))
        records.removeAll(where: match)
        for r in gone { discardFile(r); speeds[r.id] = nil }
        session.getAllTasks { tasks in
            tasks.filter { names.contains($0.taskDescription ?? "") }.forEach { $0.cancel() }
        }
        save(); pump()
    }

    private func discardFile(_ r: DownloadRecord) {
        guard let f = r.fileName else { return }
        try? FileManager.default.removeItem(at: DownloadFiles.url(for: f))
        try? FileManager.default.removeItem(at: DownloadFiles.resumeURL(for: f))
        resumedNames.remove(f)
    }

    // MARK: Queue (one transfer at a time)

    private func pump() {
        guard !pumping, Connectivity.shared.isOnline != false, store != nil,
              !records.contains(where: { $0.state == .downloading }),
              let next = records.first(where: { $0.state == .queued }) else { return }
        pumping = true
        let id = next.id
        Task {
            await start(id)
            pumping = false
            pump()      // moves on if that one failed; returns immediately while one is downloading
        }
    }

    private func start(_ id: String) async {
        guard let i = records.firstIndex(where: { $0.id == id }) else { return }
        var r = records[i]
        var ext = "mp4"

        // A paused transfer comes back from its saved resume data (when there is some); everything else is fresh.
        var resumeData: Data?
        if let f = r.fileName, let d = try? Data(contentsOf: DownloadFiles.resumeURL(for: f)) {
            resumeData = d
            try? FileManager.default.removeItem(at: DownloadFiles.resumeURL(for: f))
        }

        if resumeData == nil, r.remoteURL == nil {
            // Same source as the rest of this season when there is one.
            let sibling = records.first { $0.imdb == r.imdb && $0.season == r.season && $0.sourceAddonID != nil && $0.id != r.id }
            guard let found = await DownloadResolver.resolve(
                imdb: r.imdb, type: r.item.type, season: r.season, episode: r.episode,
                preferAddonID: r.sourceAddonID ?? sibling?.sourceAddonID,
                preferSignature: r.sourceSignature ?? sibling?.sourceSignature,
                addons: store?.enabledAddons ?? [], pins: pins) else {
                fail(id, "No HTTPS source found"); return
            }
            r.remoteURL = found.url
            r.headers = found.stream.requestHeaders
            r.sourceAddonID = found.addon.id
            r.sourceSignature = found.stream.signature
            let e = found.stream.fileExtension
            if !e.isEmpty { ext = e }
        } else if let u = r.remoteURL {
            let e = u.pathExtension.lowercased()
            if !e.isEmpty { ext = e }
        }
        ext = String(ext.filter { $0.isLetter || $0.isNumber }.prefix(4))
        if ext.isEmpty { ext = "mp4" }

        // The record may have been deleted, or paused, while the source was being resolved.
        guard let j = records.firstIndex(where: { $0.id == id }), records[j].state == .queued else { return }

        let task: URLSessionDownloadTask
        if let resumeData, let name = r.fileName {
            // Keeps its file name, bytes and progress: the bar carries on from where it stopped.
            task = session.downloadTask(withResumeData: resumeData)
            resumedNames.insert(name)
            r.state = .downloading; r.error = nil
        } else {
            guard let url = r.remoteURL else { fail(id, "No HTTPS source found"); return }
            r.fileName = "\(UUID().uuidString.lowercased()).\(ext)"
            r.state = .downloading; r.error = nil; r.progress = 0; r.bytes = 0
            var req = URLRequest(url: url)
            for (k, v) in r.headers { req.setValue(v, forHTTPHeaderField: k) }
            task = session.downloadTask(with: req)
        }
        records[j] = r
        speeds[id] = nil
        save()
        task.taskDescription = r.fileName
        task.resume()
    }

    // MARK: Session callbacks (hopped onto the main actor by SessionDelegate)

    /// The delegate already throttles (per 1% or once a second), so every call that reaches here is worth a redraw.
    /// `speed` is nil when the call was only a progress step and no new speed sample was taken.
    fileprivate func progress(_ name: String, written: Int64, expected: Int64, speed: Double?) {
        // A callback that was already in flight when the download was paused must not revive its speed reading.
        guard let i = records.firstIndex(where: { $0.fileName == name }), records[i].state == .downloading else { return }
        records[i].bytes = written
        records[i].expectedBytes = max(expected, 0)
        records[i].progress = expected > 0 ? Double(written) / Double(expected) : 0
        if let speed { speeds[records[i].id] = DownloadSpeed(bytesPerSecond: speed, at: .now) }
    }

    fileprivate func finished(_ name: String, bytes: Int64) {
        guard let i = records.firstIndex(where: { $0.fileName == name }) else {
            try? FileManager.default.removeItem(at: DownloadFiles.url(for: name)); return   // deleted mid-transfer
        }
        speeds[records[i].id] = nil
        resumedNames.remove(name)
        records[i].state = .done; records[i].progress = 1; records[i].bytes = bytes
        records[i].expectedBytes = bytes; records[i].error = nil
        save(); pump()
    }

    fileprivate func failed(_ name: String, _ message: String) {
        guard let i = records.firstIndex(where: { $0.fileName == name }) else { return }
        if resumedNames.contains(name) {
            // The saved partial download couldn't be picked up: throw it away and start over once, same source.
            discardFile(records[i])      // also forgets `name` in resumedNames
            speeds[records[i].id] = nil
            records[i].state = .queued; records[i].error = nil
            records[i].fileName = nil; records[i].bytes = 0; records[i].progress = 0
            save(); pump()
            return
        }
        fail(records[i].id, message)
    }

    private func fail(_ id: String, _ message: String) {
        guard let i = records.firstIndex(where: { $0.id == id }) else { return }
        discardFile(records[i])
        speeds[id] = nil
        records[i].state = .failed; records[i].error = message
        records[i].fileName = nil; records[i].bytes = 0; records[i].progress = 0
        save(); pump()
    }

    fileprivate func finishBackgroundEvents() {
        backgroundCompletion?(); backgroundCompletion = nil
    }

    /// After a relaunch: anything marked downloading without a live transfer goes back in the queue.
    private func reconcile() {
        session.getAllTasks { [weak self] tasks in
            let live = Set(tasks.compactMap(\.taskDescription))
            Task { @MainActor in
                guard let self else { return }
                for i in self.records.indices where self.records[i].state == .downloading {
                    if let n = self.records[i].fileName, live.contains(n) { continue }
                    self.records[i].state = .queued; self.records[i].progress = 0; self.records[i].bytes = 0
                    self.speeds[self.records[i].id] = nil
                }
                self.sweepOrphans()
                self.save(); self.pump()
            }
        }
    }

    /// Files nobody refers to (a crash mid-delete, an abandoned transfer).
    private func sweepOrphans() {
        let names = records.compactMap(\.fileName)
        let known = Set(names).union(names.map { $0 + ".resume" }).union(["index.json"])
        let files = (try? FileManager.default.contentsOfDirectory(atPath: DownloadFiles.directory.path)) ?? []
        for f in files where !known.contains(f) {
            try? FileManager.default.removeItem(at: DownloadFiles.url(for: f))
        }
    }

    // MARK: Persistence (a file, not UserDefaults: the list can grow)

    private func save() {
        guard let d = try? JSONEncoder().encode(records) else { return }
        try? d.write(to: DownloadFiles.index, options: .atomic)
        DownloadFiles.excludeFromBackup(DownloadFiles.index)
    }

    private static func loadIndex() -> [DownloadRecord] {
        guard let d = try? Data(contentsOf: DownloadFiles.index),
              let r = try? JSONDecoder().decode([DownloadRecord].self, from: d) else { return [] }
        return r
    }
}

// MARK: - URLSession delegate (runs off the main thread)

private final class SessionDelegate: NSObject, URLSessionDownloadDelegate {
    /// Per-task bookkeeping for throttling and speed. Delegate callbacks arrive on one serial queue, so no lock is needed.
    private struct Sample {
        var fraction = -1.0         // last progress fraction passed on (-1: nothing passed on yet)
        var windowStart: Date       // start of the current speed window
        var windowBytes: Int64      // total bytes written when that window started
        var speed: Double?          // exponentially smoothed bytes/second
    }
    private var samples: [Int: Sample] = [:]

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData chunk: Int64,
                    totalBytesWritten written: Int64, totalBytesExpectedToWrite expected: Int64) {
        guard let name = downloadTask.taskDescription else { return }
        // This fires for every chunk received, hundreds of times a second on a fast link. Only two things are worth
        // waking the main actor for: progress moving by 1%, or a fresh speed reading (at most once a second).
        let now = Date()
        let id = downloadTask.taskIdentifier
        var s = samples[id] ?? Sample(windowStart: now, windowBytes: written - chunk)

        var speedTaken = false
        let elapsed = now.timeIntervalSince(s.windowStart)
        if elapsed >= 1 {
            let instant = Double(max(written - s.windowBytes, 0)) / elapsed
            // Smoothing keeps the number from jumping around between windows.
            s.speed = s.speed.map { $0 * 0.7 + instant * 0.3 } ?? instant
            s.windowStart = now; s.windowBytes = written
            speedTaken = true
        }

        let fraction = expected > 0 ? Double(written) / Double(expected) : 0
        let stepped = abs(fraction - s.fraction) >= 0.01
        if stepped { s.fraction = fraction }
        samples[id] = s
        guard stepped || speedTaken else { return }

        let speed = speedTaken ? s.speed : nil
        Task { @MainActor in DownloadManager.shared.progress(name, written: written, expected: expected, speed: speed) }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let name = downloadTask.taskDescription else { return }
        // A 403 / 404 arrives here as a "successful" download of the error page.
        if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            Task { @MainActor in DownloadManager.shared.failed(name, "Server returned \(http.statusCode)") }
            return
        }
        // The temp file is deleted when this method returns, so the move has to happen here.
        let dest = DownloadFiles.url(for: name)
        do {
            DownloadFiles.prepare()
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.moveItem(at: location, to: dest)
            DownloadFiles.excludeFromBackup(dest)
            let size = Int64((try? dest.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
            Task { @MainActor in DownloadManager.shared.finished(name, bytes: size) }
        } catch {
            Task { @MainActor in DownloadManager.shared.failed(name, error.localizedDescription) }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        samples[task.taskIdentifier] = nil
        guard let error, let name = task.taskDescription else { return }
        if (error as NSError).code == NSURLErrorCancelled { return }
        Task { @MainActor in DownloadManager.shared.failed(name, error.localizedDescription) }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        Task { @MainActor in DownloadManager.shared.finishBackgroundEvents() }
    }
}
