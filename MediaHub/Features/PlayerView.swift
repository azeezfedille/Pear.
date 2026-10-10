import SwiftUI
import Combine
import AetherEngine

struct PlayRequest: Identifiable {
    let id = UUID()
    let url: URL
    let headers: [String: String]
    let item: MetaPreview
    let key: String
    let imdb: String
    let season: Int?
    let episode: Int?
    var episodeTitle: String? = nil
    var logo: URL? = nil
    /// Episode still (or movie backdrop): shown on the Continue Watching card.
    var thumb: URL? = nil
    /// Which add-on / release name this came from, so the next episode can prefer the same source.
    var sourceAddonID: String? = nil
    var sourceSignature: String? = nil
    /// Set for torrent sources: the real URL is resolved by P2PManager when playback starts.
    var p2p: P2PSource? = nil
}

/// Playback position lives in its own object: only views that read it (seek bar, skip button) redraw on the
/// clock, never the whole player.
@MainActor @Observable
final class Playhead {
    var position: Double = 0
    var duration: Double = 0
    /// Source-time position buffered ahead of the playhead (seek bar's lighter segment).
    var buffered: Double = 0
    @ObservationIgnored var scrubbing = false
}

/// Thin wrapper over AetherEngine (FFmpeg demux + VideoToolbox hardware decode): plays MKV, AVI, WebM and
/// DTS / TrueHD / Opus audio, while the heavy lifting stays in Apple's hardware decoder.
@MainActor @Observable
final class PlayerModel {
    var isPlaying = false
    var isPaused = false
    var isBuffering = true
    /// Debounced `isBuffering`: short stalls don't flash a spinner.
    var showSpinner = true
    var didEnd = false
    var error: String?
    var audioTracks: [TrackInfo] = []
    var subtitleTracks: [TrackInfo] = []
    var activeAudioID: Int?
    var activeSubtitleID: Int?
    var activeCues: [SubCue] = []
    /// OpenSubtitles files for the current title (see OpenSubtitlesClient).
    var onlineSubs: [OnlineSubtitle] = []
    var loadingOnline = false
    @ObservationIgnored private var onlineFor: UUID?
    @ObservationIgnored private var addedOnline: [String: Int] = [:]
    /// Playback speed, 0.5...2.0 in continuous steps. The engine clamps it again to what the active backend supports.
    private(set) var rate: Double = 1.0
    private(set) var engine: AetherEngine?
    /// Last request handed to start(), and whether P2PManager tore the engine down behind our back (idle, background, memory, network, call).
    @ObservationIgnored private var lastRequest: PlayRequest?
    @ObservationIgnored private var p2pDropped = false
    /// Position recorded the moment P2PManager dropped the engine. AetherEngine.stop() zeroes its clock and duration,
    /// so by the time the viewer presses play the live values are gone.
    @ObservationIgnored private var dropResume: Double?
    /// Set while a restart is loading: the clock reads 0 until the first frame, and must not move the seek bar.
    @ObservationIgnored private var holdPosition: Double?

    let playhead = Playhead()

    @ObservationIgnored private var bag = Set<AnyCancellable>()
    @ObservationIgnored private var allCues: [SubCue] = []
    @ObservationIgnored private var mappedCount = 0
    @ObservationIgnored private var mappedFirst: Double?
    @ObservationIgnored private var sourceTime: Double = 0
    /// Subtitle clock: subscribed only while a subtitle track is on, so a film without subtitles never wakes for it.
    @ObservationIgnored private var cueClock: AnyCancellable?
    /// Span of source time in which the visible cues can't change (no cue starts or ends inside it).
    @ObservationIgnored private var cueFrom: Double = 1
    @ObservationIgnored private var cueTo: Double = 0
    /// True while the controls are on screen: the seek bar then follows playback twice a second, otherwise once a second.
    @ObservationIgnored var controlsVisible = true
    @ObservationIgnored private var lastPublish: TimeInterval = 0
    @ObservationIgnored private var spinnerTask: Task<Void, Never>?
    @ObservationIgnored private var seekTask: Task<Void, Never>?
    @ObservationIgnored private var pendingTarget: Double?
    @ObservationIgnored private var seekInFlight = false
    @ObservationIgnored private var isShutDown = false
    @ObservationIgnored private var preferredSubtitleLanguage: String?
    @ObservationIgnored private var autoSelectSubtitle = false
    @ObservationIgnored private var rateTask: Task<Void, Never>?
    /// The engine may drop back to 1x on a (re)load, seek or pause; the chosen speed is pushed again on the next `.playing`.
    @ObservationIgnored private var rateStale = false

    /// The viewer's default subtitle language (nil = off). Applied when tracks become available.
    func configure(defaultSubtitleLanguage lang: String?) {
        if preferredSubtitleLanguage == nil { preferredSubtitleLanguage = lang }
    }

    /// `replacing`: the engine is already playing something else (episode switch).
    func start(_ r: PlayRequest, resume: Double?, replacing: Bool = false, exact: Bool = false) async {
        guard !isShutDown else { return }
        if engine == nil {
            do { engine = try AetherEngine() }
            catch {
                self.error = "Couldn't start the player engine: \(error.localizedDescription)"
                setBuffering(false)
                return
            }
        }
        guard let engine else { return }
        let wasDropped = p2pDropped || dropResume != nil
        let keptDuration = playhead.duration
        lastRequest = r; p2pDropped = false; dropResume = nil
        bind(engine)
        resetForNewItem()
        Task { await loadOnlineSubtitles(for: r, auto: true) }
        let startAt = exact ? (resume ?? 0) : ((resume ?? 0) > 30 ? (resume ?? 0) : 0)
        if wasDropped, keptDuration > 0 { playhead.duration = keptDuration }
        if startAt > 0 { playhead.position = startAt; holdPosition = startAt }      // seek bar holds the resume point while loading
        do {
            // An open PiP window survives a next-episode load only if the engine is not stopped in between: it hands the item over in place.
            if replacing, !engine.pictureInPictureActive { engine.stop() }
            var url = r.url
            if let src = r.p2p {
                // Spinner stays up while peers are found; initial buffering is the same state as for any slow source.
                url = try await P2PManager.shared.open(src)
                // The screen may have been closed while peers were being found.
                if isShutDown { P2PManager.shared.stop(); engine.stop(); return }
            } else {
                P2PManager.shared.stop() // switched from a torrent to a direct source: tear the engine down
            }
            var options = LoadOptions(httpHeaders: r.headers)
            // ~10 min of look-ahead (150 x ~4 s segments). That is the largest window the engine accepts without
            // opting out of its 2 GiB retention cap, so a seek or a reconnect never competes with a whole-film
            // download for bandwidth. Raise it if you'd rather trade disk and data for a longer cushion.
            options.forwardBufferSegments = 150
            // Remote files: cap the open-time probe (engine defaults are 50 MB / 60 s, tuned for local disk).
            options.probesize = 16 * 1024 * 1024
            options.maxAnalyzeDuration = 10 * 1_000_000
            if r.p2p != nil {
                // Torrent: smaller probe and ~3 min look-ahead, so the swarm isn't pulled far ahead of playback.
                options.probesize = 8 * 1024 * 1024
                options.forwardBufferSegments = PowerMode.shared.saving ? 20 : 40
            }
            // Open straight at the resume point. Loading at 0:00, playing, then seeking made the engine fetch the
            // head of the file, throw it away, and restart its producer at the target: the cut-and-reload on resume.
            try await engine.load(url: url, startPosition: startAt, options: options)
            // The screen may have been closed while the source was loading.
            if isShutDown { engine.stop(); return }
            engine.play()
        } catch {
            holdPosition = nil
            if error is CancellationError || isShutDown { return }
            self.error = error.localizedDescription
            setBuffering(false)
        }
    }

    private func resetForNewItem() {
        error = nil; didEnd = false
        isPlaying = false; isPaused = false
        setBuffering(true); showSpinner = true
        playhead.position = 0; playhead.duration = 0; playhead.buffered = 0
        seekTask?.cancel(); pendingTarget = nil; seekInFlight = false
        allCues = []; mappedCount = 0; mappedFirst = nil; activeCues = []; invalidateCueWindow()
        activeSubtitleID = nil; subtitleTracks = []; audioTracks = []; activeAudioID = nil
        cueClock = nil
        onlineSubs = []; addedOnline = [:]; onlineFor = nil; loadingOnline = false
        // Default language on first start, then whatever the viewer picked, across episodes.
        autoSelectSubtitle = preferredSubtitleLanguage != nil
        rateStale = rate != 1
    }

    private func bind(_ engine: AetherEngine) {
        guard bag.isEmpty else { return }
        engine.$state.receive(on: DispatchQueue.main).sink { [weak self] s in
            guard let self else { return }
            switch s {
            case .playing:
                holdPosition = nil
                P2PManager.shared.playbackChanged(true)
                isPlaying = true; isPaused = false; setBuffering(false); error = nil; refreshTracks()
                if rateStale { pushRate() }
            case .paused: holdPosition = nil; P2PManager.shared.playbackChanged(false); isPlaying = false; isPaused = true; setBuffering(false); rateStale = rate != 1
            case .loading, .seeking: P2PManager.shared.playbackChanged(true); isPaused = false; setBuffering(true); rateStale = rate != 1
            case .ended: holdPosition = nil; P2PManager.shared.playbackChanged(false); isPlaying = false; isPaused = false; setBuffering(false); didEnd = true
            case .error: holdPosition = nil; P2PManager.shared.playbackChanged(false); isPlaying = false; isPaused = false; setBuffering(false); error = "Playback failed (\(String(describing: s)))."
            default: break
            }
        }.store(in: &bag)
        engine.$duration.receive(on: DispatchQueue.main).sink { [weak self] d in
            guard let self else { return }
            // engine.stop() publishes 0: not a real duration while we are dropped or reloading.
            if (p2pDropped || holdPosition != nil) && Double(d) <= 0 { return }
            playhead.duration = Double(d)
        }.store(in: &bag)
        // P2P torn down while we weren't looking: stop the engine cleanly and wait on the play button (or a seek) to reopen.
        NotificationCenter.default.publisher(for: P2PManager.didStop)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] n in
                guard let self, !isShutDown, lastRequest?.p2p != nil,
                      let raw = n.userInfo?["reason"] as? String,
                      P2PManager.StopReason(rawValue: raw)?.isAutomatic == true else { return }
                // Record the live position BEFORE stop(): it resets the clock and duration to 0.
                let live = Double(engine.clock.currentTime)
                dropResume = pendingTarget ?? (live > 0 ? live : playhead.position)
                if let r = dropResume { playhead.position = r }
                p2pDropped = true
                seekTask?.cancel(); pendingTarget = nil; seekInFlight = false
                engine.stop()
                isPlaying = false; isPaused = true; setBuffering(false)
            }.store(in: &bag)
        // The seek bar only needs the clock to the second: 2 Hz while the controls are up, 1 Hz while they are hidden
        // (the skip-intro button is the only reader then). Fewer publishes means fewer redraws and CPU wake-ups.
        engine.clock.$currentTime
            .throttle(for: .milliseconds(500), scheduler: DispatchQueue.main, latest: true)
            .sink { [weak self] t in
                guard let self, !p2pDropped, holdPosition == nil, !playhead.scrubbing, !seekInFlight else { return }
                let now = ProcessInfo.processInfo.systemUptime
                if !controlsVisible, now - lastPublish < 1 { return }
                lastPublish = now
                playhead.position = Double(t)
            }.store(in: &bag)
        // Buffered-ahead position drives the lighter segment of the seek bar; 2 Hz is plenty.
        engine.clock.$bufferedPosition
            .throttle(for: .milliseconds(500), scheduler: DispatchQueue.main, latest: true)
            .sink { [weak self] b in
                // Reflect copes with the engine publishing Double, Float or an optional of either.
                self?.playhead.buffered = Reflect.unwrap(b).flatMap(Reflect.number) ?? 0
            }.store(in: &bag)
        // Subtitle cues arrive as one cumulative list in source time; only new cues are converted.
        engine.$subtitleCues.receive(on: DispatchQueue.main).sink { [weak self] cues in
            self?.ingest(cues)
        }.store(in: &bag)
    }

    /// Starts or stops the subtitle clock to match the active track.
    private func syncCueClock() {
        guard let engine, !isShutDown, activeSubtitleID != nil else { cueClock = nil; return }
        guard cueClock == nil else { return }
        sourceTime = Double(engine.clock.sourceTime)
        cueClock = engine.clock.$sourceTime
            .throttle(for: .milliseconds(100), scheduler: DispatchQueue.main, latest: true)
            .sink { [weak self] t in
                guard let self else { return }
                sourceTime = Double(t)
                refreshActiveCues()
            }
    }

    private func invalidateCueWindow() { cueFrom = 1; cueTo = 0 }

    // MARK: Buffering indicator

    private func setBuffering(_ on: Bool) {
        if isBuffering != on { isBuffering = on }
        spinnerTask?.cancel()
        if on {
            spinnerTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled else { return }
                self?.showSpinner = true
            }
        } else if showSpinner {
            showSpinner = false
        }
    }

    // MARK: Subtitles

    /// The engine republishes the whole list as it grows. Converting every cue each time (via reflection)
    /// is quadratic work on the main thread, so only the tail is converted.
    private func ingest(_ cues: [SubtitleCue]) {
        let first = cues.first.map { Double($0.startTime) }
        if cues.count < mappedCount || first != mappedFirst { allCues = []; mappedCount = 0 }
        mappedFirst = first
        if cues.count > mappedCount {
            allCues += cues[mappedCount...].compactMap { SubCue.make($0) }
            mappedCount = cues.count
        }
        invalidateCueWindow()
        refreshActiveCues()
    }

    private func refreshActiveCues() {
        guard activeSubtitleID != nil else { if !activeCues.isEmpty { activeCues = [] }; return }
        let t = sourceTime
        // Nothing starts or ends inside the current window, so most ticks cost two comparisons instead of a pass
        // over every cue in the file.
        if t >= cueFrom && t < cueTo { return }
        var now: [SubCue] = []
        var from = -Double.infinity, to = Double.infinity
        for c in allCues {
            if c.start <= t && t < c.end { now.append(c); from = max(from, c.start); to = min(to, c.end) }
            else if c.start > t { to = min(to, c.start) }
            else { from = max(from, c.end) }
        }
        cueFrom = from; cueTo = to
        if now != activeCues { activeCues = now }
    }

    func refreshTracks() {
        guard let engine else { return }
        audioTracks = engine.audioTracks
        subtitleTracks = engine.subtitleTracks
        activeAudioID = Reflect.int(engine.activeAudioTrackIndex)
        activeSubtitleID = Reflect.int(engine.activeSubtitleTrackIndex)
        if autoSelectSubtitle, !subtitleTracks.isEmpty {
            autoSelectSubtitle = false
            if activeSubtitleID == nil, let lang = preferredSubtitleLanguage, let t = bestSubtitle(for: lang) {
                selectSubtitle(t)
                return
            }
        }
        syncCueClock()
        refreshActiveCues()
    }

    /// Prefers a normal track, then a non-forced one, then anything in that language.
    private func bestSubtitle(for lang: String) -> TrackInfo? {
        let hits = subtitleTracks.filter {
            SubLanguages.matches(Reflect.string($0, "language"), lang) || SubLanguages.matches(Reflect.string($0, "name"), lang)
        }
        return hits.first { !Reflect.bool($0, "isForced") && !Reflect.bool($0, "isHearingImpaired") }
            ?? hits.first { !Reflect.bool($0, "isForced") } ?? hits.first
    }

    /// Looks up OpenSubtitles for this request. With `auto`, and a default language that the file itself doesn't
    /// have, the best online match is added and switched on.
    func loadOnlineSubtitles(for r: PlayRequest, auto: Bool) async {
        guard OpenSubtitlesClient.shared.enabled, onlineFor != r.id else { return }
        onlineFor = r.id; onlineSubs = []; loadingOnline = true
        let list = await OpenSubtitlesClient.shared.search(imdb: r.imdb, season: r.season, episode: r.episode)
        guard !Task.isCancelled, onlineFor == r.id else { return }
        onlineSubs = list; loadingOnline = false
        guard auto, let lang = preferredSubtitleLanguage else { return }
        // Give the file's own tracks a moment to show up before deciding it has none in that language.
        for _ in 0..<20 where !isPlaying { try? await Task.sleep(for: .milliseconds(500)) }
        guard !Task.isCancelled, onlineFor == r.id, activeSubtitleID == nil, bestSubtitle(for: lang) == nil,
              let s = list.first(where: { SubLanguages.matches($0.lang, lang) }) else { return }
        useOnline(s)
    }

    /// Registers the downloaded file as an external track (once) and switches to it.
    func useOnline(_ s: OnlineSubtitle) {
        guard let engine else { return }
        if let id = addedOnline[s.id], let t = subtitleTracks.first(where: { Reflect.int($0.id) == id }) {
            selectSubtitle(t); return
        }
        let info = engine.addExternalSubtitleTrack(
            ExternalSubtitleTrack(url: s.url, name: "OpenSubtitles", language: s.lang, httpHeaders: [:], formatHint: "srt"))
        addedOnline[s.id] = Reflect.int(info.id)
        subtitleTracks = engine.subtitleTracks
        selectSubtitle(info)
    }

    func selectSubtitle(_ t: TrackInfo?) {
        guard let engine else { return }
        allCues = []; mappedCount = 0; mappedFirst = nil; invalidateCueWindow()
        if let t {
            engine.selectSubtitleTrack(index: t.id)
            activeSubtitleID = Reflect.int(t.id)
            preferredSubtitleLanguage = Reflect.string(t, "language") ?? Reflect.string(t, "name")
            ingest(engine.subtitleCues)
        } else {
            engine.clearSubtitle()
            activeSubtitleID = nil
            activeCues = []
            preferredSubtitleLanguage = nil
        }
        syncCueClock()
        refreshActiveCues()
    }

    func selectAudio(_ t: TrackInfo) {
        engine?.selectAudioTrack(index: t.id)
        activeAudioID = Reflect.int(t.id)
    }

    // MARK: Transport

    func togglePlay() {
        if p2pDropped { resumeAfterDrop() } else { engine?.togglePlayPause() }
    }

    /// Reopens the torrent at the saved position (or at t, for a seek made while it was torn down).
    private func resumeAfterDrop(at t: Double? = nil) {
        guard p2pDropped, let r = lastRequest else { return }
        p2pDropped = false
        let pos = t ?? dropResume ?? playhead.position
        playhead.position = pos; holdPosition = pos // the clock reads 0 until the reopened stream renders
        Task { await start(r, resume: pos, replacing: true, exact: true) }
    }

    // MARK: Playback speed

    /// Continuous speed control. Values are rounded to 0.01 and snap to exactly 1x near the middle. While the slider
    /// is dragged the engine is only told about the latest value, ~90 ms after the last change.
    func setRate(_ r: Double) {
        let v = min(max(r, 0.5), 2.0)
        rate = abs(v - 1) < 0.025 ? 1 : (v * 100).rounded() / 100
        rateTask?.cancel()
        // Setting a rate on a paused player could start it, so a paused change waits for the next `.playing`.
        guard isPlaying else { rateStale = true; return }
        rateTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(90))
            guard !Task.isCancelled, let self else { return }
            pushRate()
        }
    }

    private func pushRate() {
        guard let engine else { return }
        rateStale = false
        // `setRate` takes the engine's own float type; the generic helper keeps this compiling for Float or Double.
        Self.apply(engine.setRate, rate)
    }

    private static func apply<T: BinaryFloatingPoint>(_ f: (T) -> Void, _ v: Double) { f(T(v)) }

    private func clamp(_ t: Double) -> Double {
        min(max(t, 0), playhead.duration > 0 ? playhead.duration : max(t, 0))
    }

    /// Seek immediately (scrub release, skip-intro button).
    func seek(to t: Double) async {
        seekTask?.cancel()
        pendingTarget = clamp(t)
        playhead.position = pendingTarget ?? t
        seekInFlight = true
        await commitSeek()
    }

    /// Relative skip. Rapid taps are merged into one seek: every seek on a remote file forces a rebuffer.
    func skip(by delta: Double) {
        let target = clamp((pendingTarget ?? playhead.position) + delta)
        pendingTarget = target
        playhead.position = target
        seekInFlight = true
        seekTask?.cancel()
        seekTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled, let self else { return }
            await commitSeek()
        }
    }

    private func commitSeek() async {
        guard let t = pendingTarget else { seekInFlight = false; return }
        pendingTarget = nil
        if p2pDropped { seekInFlight = false; resumeAfterDrop(at: t); return }
        await engine?.seek(to: t)
        if pendingTarget == nil { seekInFlight = false }
    }

    func shutdown() {
        guard !isShutDown else { return }
        isShutDown = true
        spinnerTask?.cancel(); seekTask?.cancel(); rateTask?.cancel()
        cueClock = nil
        bag.removeAll()
        engine?.stop()
        P2PManager.shared.stop()
    }
}

// MARK: - Glass helpers

/// Liquid Glass when enabled, flat translucent fill otherwise (Settings → Playback).
private struct GlassCircle: ViewModifier {
    let on: Bool
    var tint: Color? = nil
    @ViewBuilder func body(content: Content) -> some View {
        if on {
            if let tint { content.glassEffect(.regular.tint(tint.opacity(0.55)), in: .circle) }
            else { content.glassEffect(.regular, in: .circle) }
        } else {
            content.background(tint?.opacity(0.75) ?? Color.black.opacity(0.4), in: Circle())
        }
    }
}

private struct GlassCapsule: ViewModifier {
    let on: Bool
    @ViewBuilder func body(content: Content) -> some View {
        if on { content.glassEffect(.regular, in: .capsule) }
        else { content.background(.black.opacity(0.55), in: Capsule()) }
    }
}

private struct GlassCard: ViewModifier {
    let on: Bool
    var radius: CGFloat = 26
    @ViewBuilder func body(content: Content) -> some View {
        if on { content.glassEffect(.regular, in: .rect(cornerRadius: radius)) }
        else { content.background(.black.opacity(0.88), in: RoundedRectangle(cornerRadius: radius, style: .continuous)) }
    }
}

// MARK: - Player screen

struct PlayerScreen: View {
    let provider: EpisodeProvider?
    let onClose: () -> Void
    @Environment(WatchHistory.self) private var history
    @Environment(LocalLibrary.self) private var library
    @Environment(WatchLog.self) private var watchLog
    @Environment(SimklStore.self) private var simkl
    @Environment(LibraryPrefs.self) private var libraryPrefs
    @Environment(ThemeStore.self) private var theme
    @Environment(AddonStore.self) private var store
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(SubtitleStyle.storageKey) private var subJSON = ""
    @AppStorage("sub.lang") private var subLang = "off"
    @AppStorage("player.glass") private var glassPref = true
    @AppStorage("player.autoplayNext") private var autoplayNext = true
    /// Pill buttons that stay visible while it is folded (Settings → Playback → Player controls).
    @AppStorage(PillItem.storageKey) private var pillPinned = PillItem.defaultRaw
    @AppStorage(PillItem.orderKey) private var pillOrder = PillItem.defaultOrderRaw
    @AppStorage("skip.fallbackSeconds") private var fallbackSkip = 0     // 0 = manual skip button off
    @State private var current: PlayRequest
    @State private var model = PlayerModel()
    @State private var showControls = true
    @State private var showEpisodes = false
    @State private var showSubtitles = false
    @State private var showSources = false
    @State private var showSpeed = false
    /// The controls pill is showing the volume slider instead of its icons.
    @State private var showVolume = false
    @State private var volume = SystemVolume()
    @State private var volumeTask: Task<Void, Never>?
    @State private var volumeDragging = false
    /// The pill has more than `pillFolded` items and the user unfolded it with the chevron.
    @State private var pillExpanded = false
    @State private var pillTask: Task<Void, Never>?
    /// Picture in Picture window (native AVPlayer path only; the pill hides the button otherwise).
    @State private var pip = PiPController()
    @State private var sourceGroups: [(Addon, [StreamItem])] = []
    /// Add-on id the sources panel is narrowed to; nil = all add-ons.
    @State private var sourceFilter: String?
    /// Torrent sources per add-on that are hidden because P2P is switched off.
    @State private var p2pOffCounts: [String: Int] = [:]
    @State private var loadingSources = false
    @State private var hideTask: Task<Void, Never>?
    @State private var scrobbled = false
    @State private var closing = false
    /// When playback time was last added to the watch log.
    @State private var lastTick = Date()
    /// True until the first frame plays: the "pear." loader covers the black screen while the source opens.
    @State private var launching = true
    @State private var switching: Int?
    @State private var notice: String?
    @State private var nextEp: NextEpisode?
    @State private var segments: [SkipSegment] = []
    @State private var segmentsLoaded = false
    /// Shown above the title while paused. Loads in the background at start, so pausing never waits on the network.
    @State private var pausedLogo: UIImage?
    /// The info card opened by tapping the title (episode or movie details).
    @State private var showInfo = false
    @State private var info: PlayerInfo?
    /// Subtitle look, decoded once per change instead of on every redraw of the player.
    @State private var subStyle = SubtitleStyle()

    /// Liquid Glass over live video is re-sampled every frame, so Low Power Mode uses the flat look.
    /// A hot phone does not: the glass stays on regardless of thermal state.
    private var glass: Bool { glassPref && !PowerMode.shared.lowPower }

    init(request: PlayRequest, provider: EpisodeProvider? = nil, onClose: @escaping () -> Void) {
        _current = State(initialValue: request)
        self.provider = provider
        self.onClose = onClose
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let engine = model.engine { AetherPlayerSurface(engine: engine).ignoresSafeArea() }
            if pip.isActive { pipPlaceholder }
            SubtitleOverlay(cues: pip.isActive ? [] : model.activeCues, lift: showControls ? 112 : 0, style: subStyle)
                .animation(.easeInOut(duration: 0.2), value: showControls)
            Color.clear.contentShape(Rectangle()).onTapGesture { tapBackground() }
            // Only while the volume pill is open: gives us the system slider and lets the pill replace iOS's own volume HUD.
            if showVolume { SystemVolumeHost(volume: volume).frame(width: 1, height: 1).opacity(0.011).allowsHitTesting(false) }
            if pausedDim { pausedOverlay }
            if model.showSpinner && model.error == nil && !showControls && !showEpisodes && !launching {
                ProgressView().controlSize(.large).tint(.white)
            }
            if launching && model.error == nil { launchOverlay.transition(.opacity) }
            if model.error != nil || (showControls && !launching) { controls.transition(.opacity) }
            if !showEpisodes && !showSubtitles && !showSources && !showSpeed && !showInfo && model.error == nil { skipLayer }
            if showEpisodes, let provider { episodePanel(provider).transition(.move(edge: .bottom).combined(with: .opacity)) }
            if showSubtitles { subtitlePanel.transition(.move(edge: .trailing).combined(with: .opacity)) }
            if showSources { sourcesPanel.transition(.move(edge: .trailing).combined(with: .opacity)) }
            if showSpeed { speedLayer.transition(.move(edge: .bottom).combined(with: .opacity)) }
            if showInfo, let info { infoPanel(info).transition(.move(edge: .bottom).combined(with: .opacity)) }
            if let e = model.error { errorCard(e) }
            if let n = notice { toast(n) }
        }
        .preferredColorScheme(.dark)
        .statusBarHidden(!showControls)
        .persistentSystemOverlays(showControls ? .automatic : .hidden)
        .animation(.snappy(duration: 0.25), value: notice)
        .task { await begin() }
        .task(id: current.id) { await loadAux() }
        // Fills the info card in while it is open (and again if the episode changes underneath it).
        .task(id: showInfo ? current.id : nil) { if showInfo { await loadInfo() } }
        .task(id: current.item.id) { await loadPausedLogo() }
        .animation(.easeInOut(duration: 0.25), value: pausedDim)
        .animation(.easeInOut(duration: 0.25), value: pip.isActive)
        .task {
            // Coarse 15 s tick: negligible wakeups, still good resume accuracy. Nothing to record while paused.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                if model.isPaused { lastTick = Date(); continue }
                logPlayTime()
                save(isFinal: false)
            }
        }
        .onChange(of: model.isPlaying) { _, playing in
            if playing && !scrobbled { scrobbled = true; if libraryPrefs.usesSimkl(simkl) { simkl.scrobble("start", current, progress: 0) } }
            if playing && launching { withAnimation(.easeOut(duration: 0.25)) { launching = false } }
            if playing { scheduleHide() } else { hideTask?.cancel() }
            // The engine's native layer exists once a session is playing, and may be a new one after a reload or episode switch.
            if playing { pip.refresh(engine: model.engine) }
        }
        // Covers a layer that appears a moment after the first .playing edge (and a pause/resume that follows a reload).
        .onChange(of: model.showSpinner) { _, spinning in
            if !spinning { pip.refresh(engine: model.engine) }
        }
        // While the video is in the PiP window this screen is only a remote: keep the controls up so the way back is visible.
        .onChange(of: pip.isActive) { _, active in
            if active { hideTask?.cancel(); withAnimation(.easeInOut(duration: 0.2)) { showControls = true } }
            else { scheduleHide() }
        }
        .onChange(of: model.isPaused) { _, paused in
            if paused && !showInfo { withAnimation(.easeInOut(duration: 0.2)) { showControls = true } }
            // The 15 s tick skips paused time, and a paused player can sit in the background until iOS ends the app,
            // so pausing is when the resume point gets banked.
            if paused { save(isFinal: false) }
            updateIdleTimer()
        }
        // Same for leaving the app while playing (PiP, background audio): the system may end it without notice.
        .onChange(of: scenePhase) { _, p in
            if p == .background { logPlayTime(); save(isFinal: false) }
        }
        .onChange(of: model.error) { _, _ in updateIdleTimer() }
        .onChange(of: showControls, initial: true) { _, shown in
            model.controlsVisible = shown
            if !shown { volumeTask?.cancel(); pillTask?.cancel(); showVolume = false; pillExpanded = false }
        }
        // Another panel takes over: the pill goes back to its icons.
        .onChange(of: showEpisodes || showSubtitles || showSources || showSpeed || showInfo) { _, open in
            if open { volumeTask?.cancel(); pillTask?.cancel(); showVolume = false; pillExpanded = false }
        }
        // Hardware buttons (or the mute tap) while the pill is open count as adjusting: the 3 s countdown restarts.
        .onChange(of: volume.level) { _, _ in bumpVolume() }
        .onChange(of: subJSON, initial: true) { _, json in subStyle = SubtitleStyle.decode(json) }
        .onChange(of: model.didEnd) { _, ended in
            if ended, autoplayNext, nextEp != nil { playNext() }
        }
        .onAppear {
            updateIdleTimer()
            volume.startObserving()
            OrientationLock.set(.landscape)          // landscape only, free to flip 180°
            pip.onFailure = { flash("Picture in Picture isn't available right now") }
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
            volumeTask?.cancel()
            pillTask?.cancel()
            volume.stopObserving()
            pip.teardown()
            OrientationLock.set(OrientationLock.appMask)   // back to what the rest of the app allows
            // Normal exit goes through close(); this covers any other way the screen can go away.
            if !closing { finalizeCurrent(); model.shutdown() }
        }
    }

    // MARK: Launch

    /// Full-screen "pear." loader (loops at 2x) with a close button, so a slow source can still be cancelled.
    private var launchOverlay: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            PearAnimationView(mode: .loader).frame(maxWidth: 340).padding(.horizontal, 24)
            VStack {
                HStack { circleButton("xmark", size: 42, icon: 16) { close() }; Spacer() }
                Spacer()
            }
            .padding(.horizontal, 24).padding(.top, 4)
        }
    }

    // MARK: Controls

    private var controls: some View {
        ZStack {
            VStack(spacing: 0) {
                LinearGradient(colors: [.black.opacity(0.5), .clear], startPoint: .top, endPoint: .bottom).frame(height: 100)
                Spacer()
                LinearGradient(colors: [.clear, .black.opacity(0.8)], startPoint: .top, endPoint: .bottom).frame(height: 260)
            }
            .ignoresSafeArea().allowsHitTesting(false)

            VStack(spacing: 0) {
                HStack { circleButton("xmark", size: 42, icon: 16) { close() }; Spacer() }
                Spacer()
                transport
                Spacer()
                bottomBar
            }
            .padding(.horizontal, 24).padding(.top, 4).padding(.bottom, 6)
        }
        .foregroundStyle(.white)
    }

    private var transport: some View {
        HStack(spacing: 38) {
            circleButton("gobackward.10", size: 50, icon: 21) { model.skip(by: -10); scheduleHide() }
            ZStack {
                circleButton(model.isPlaying ? "pause.fill" : "play.fill", size: 68, icon: 28) { model.togglePlay(); scheduleHide() }
                    .opacity(model.showSpinner ? 0.3 : 1)
                if model.showSpinner { ProgressView().controlSize(.large).tint(.white).allowsHitTesting(false) }
            }
            circleButton("goforward.10", size: 50, icon: 21) { model.skip(by: 10); scheduleHide() }
        }
    }

    /// Bottom stack: title and episode line on the left, icon buttons on the right, both directly above the glass
    /// seek bar, which sits at the very bottom. In a narrow window the icons drop below the text.
    private var bottomBar: some View {
        VStack(alignment: .leading, spacing: 10) {
            if pausedDim { pausedInfo }
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .bottom, spacing: 16) { titleBlock; iconRow }
                VStack(alignment: .leading, spacing: 12) {
                    titleBlock
                    HStack { Spacer(minLength: 0); iconRow }
                }
            }
            SeekBar(playhead: model.playhead, glass: glass,
                    onScrubStart: { hideTask?.cancel() },
                    onCommit: { t in Task { await model.seek(to: t); scheduleHide() } })
        }
    }

    /// Series name + episode line (tap for the episode / movie info card).
    private var titleBlock: some View {
        Button { openInfo() } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(current.item.name).font(.system(size: 24, weight: .bold)).lineLimit(1)
                    Image(systemName: "chevron.up").font(.system(size: 14, weight: .bold)).opacity(0.85)
                }
                if let l = subtitleLine {
                    Text(l).font(.system(size: 17, weight: .medium)).foregroundStyle(.white.opacity(0.75)).lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: Controls pill

    private static let pillSlot: CGFloat = 46          // one icon
    private static let pillGap: CGFloat = 2            // between icons
    private static let pillPad: CGFloat = 4            // glass padding around the icons
    /// A pill with more items than this folds: it shows the pinned ones plus a chevron, the rest unfold to the left.
    private static let pillFolded = PillItem.maxPinned
    /// Seconds an unfolded pill stays open after the last tap.
    private static let pillLife: Double = 5
    /// Narrowest the volume slider may get (inner width, without the glass padding).
    private static let volumeMinWidth: CGFloat = 260

    /// Width of `n` icons side by side.
    private static func pillSpan(_ n: Int) -> CGFloat {
        n <= 0 ? 0 : CGFloat(n) * pillSlot + CGFloat(n - 1) * pillGap
    }

    /// The items that exist right now, in on-screen order (the user's order, see Settings -> Player controls). When
    /// there are more than `pillFolded`, the ones that are not pinned come first (left), so unfolding grows the pill
    /// to the left, and `extras` says how many they are. Each group keeps the user's order.
    private var pillLayout: (items: [PillItem], extras: Int) {
        let all = PillItem.decodeOrder(pillOrder).filter { pillHas($0) }
        guard all.count > Self.pillFolded else { return (all, 0) }
        // The user's pinned items that exist right now; if none of them do, the defaults.
        var keep = PillItem.decode(pillPinned).intersection(all)
        if keep.isEmpty { keep = PillItem.defaultPinned.intersection(all) }
        let extras = all.filter { !keep.contains($0) }
        let kept = all.filter { keep.contains($0) }
        return (extras + kept, extras.count)
    }

    /// Whether an item applies to what is playing right now (no episodes without a provider, no audio menu with one track...).
    private func pillHas(_ item: PillItem) -> Bool {
        switch item {
        case .speed, .sources, .volume: return true
        case .episodes: return provider != nil
        case .pip: return pip.isAvailable || pip.isActive
        case .subtitles: return !model.subtitleTracks.isEmpty || OpenSubtitlesClient.shared.enabled
        case .audio: return model.audioTracks.count > 1
        case .next: return nextEp != nil
        }
    }

    /// Speed, episodes, sources, volume, Picture in Picture, subtitles, audio track, next: all inside one Liquid Glass pill.
    ///
    /// Every width here is computed, never measured, so the glass, the icons and the volume slider can't disagree:
    /// - Up to 4 items: they all show.
    /// - More than 4: only the pinned items (default: volume, subtitles, speed, PiP) plus a chevron show. The
    ///   chevron unfolds the rest to the left; it folds itself again `pillLife` seconds after the last tap.
    /// - Tapping the speaker turns the pill into a volume slider of a fixed width (never narrower than
    ///   `volumeMinWidth`); the icons fade out and come back 3 s after the last adjustment.
    /// The pill's layout footprint is always its folded size. Anything wider (unfolded, or the slider) grows to the
    /// left over the video, so the title / icon arrangement around it never re-flows.
    private var iconRow: some View {
        let layout = pillLayout
        let n = layout.items.count
        let overflow = layout.extras > 0
        let rest = Self.pillSpan(overflow ? n - layout.extras + 1 : n)      // folded: chevron + pinned items
        let open = overflow && pillExpanded && !showVolume
        let width = showVolume ? max(rest, Self.volumeMinWidth) : (open ? Self.pillSpan(n + 1) : rest)

        return ZStack(alignment: .trailing) {
            HStack(spacing: Self.pillGap) {
                ForEach(Array(layout.items.enumerated()), id: \.element) { i, item in
                    let hidden = i < layout.extras && !open        // folded away: clipped, invisible, untouchable
                    pillItemView(item)
                        .opacity(hidden ? 0 : 1)
                        .allowsHitTesting(!hidden)
                        .accessibilityHidden(hidden || showVolume)
                }
            }
            .fixedSize()
            .opacity(showVolume ? 0 : 1)
            .allowsHitTesting(!showVolume)

            if showVolume {
                VolumeSliderRow(level: volume.level,
                                onChange: { volume.set($0) },
                                onToggleMute: { volume.toggleMute() },
                                onEditing: { volumeEditing($0) })
                    .frame(width: width)
                    .transition(.opacity)
            }
        }
        // The visible window: icons beyond it (folded ones) overflow to the left and are clipped below.
        .frame(width: width, alignment: .trailing)
        .overlay(alignment: .leading) {
            if overflow && !showVolume { pillMoreButton(open: open).transition(.opacity) }
        }
        .padding(Self.pillPad)
        .clipShape(Capsule())
        .modifier(GlassCapsule(on: glass))
        .animation(.snappy(duration: 0.25), value: layout.items)
        .frame(width: rest + Self.pillPad * 2, alignment: .trailing)
    }

    @ViewBuilder private func pillItemView(_ item: PillItem) -> some View {
        switch item {
        case .speed: pillButton("speedometer", active: showSpeed || model.rate != 1) { toggleSpeed() }
        case .episodes: pillButton("list.bullet") { openEpisodes() }
        case .sources: pillButton("rectangle.stack") { openSources() }
        case .volume: pillButton(volume.level < 0.001 ? "speaker.slash" : "speaker.wave.2") { toggleVolume() }
        case .pip: pillButton(pip.isActive ? "pip.exit" : "pip.enter", active: pip.isActive) { togglePiP() }
        case .subtitles:
            pillButton(model.activeSubtitleID == nil ? "captions.bubble" : "captions.bubble.fill",
                       active: showSubtitles) { toggleSubtitles() }
        case .audio: audioMenu
        case .next: nextButton
        }
    }

    /// Left edge of the pill: unfolds the hidden icons (chevron points left), or folds them back (points right).
    private func pillMoreButton(open: Bool) -> some View {
        Button { togglePill() } label: {
            Image(systemName: open ? "chevron.right" : "chevron.left")
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(.white)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: Self.pillSlot, height: Self.pillSlot)
                .contentShape(Circle())
        }
        .buttonStyle(PressableStyle())
        .accessibilityLabel(open ? "Fewer controls" : "More controls")
    }

    private func togglePill() {
        if pillExpanded { foldPill(); scheduleHide(); return }
        hideTask?.cancel()                      // controls stay up while the pill is unfolded
        withAnimation(.snappy(duration: 0.3)) { pillExpanded = true }
        bumpPill()
    }

    /// Folds the pill back to four items right away.
    private func foldPill() {
        pillTask?.cancel()
        guard pillExpanded else { return }
        withAnimation(.snappy(duration: 0.3)) { pillExpanded = false }
    }

    /// (Re)starts the 5 s countdown while the pill is unfolded. Any tap inside the pill calls this.
    private func bumpPill() {
        pillTask?.cancel()
        guard pillExpanded else { return }
        hideTask?.cancel()
        pillTask = Task {
            try? await Task.sleep(for: .seconds(Self.pillLife))
            guard !Task.isCancelled else { return }
            foldPill()
            scheduleHide()
        }
    }

    /// Icon inside the pill: no glass of its own, an accent disc when active.
    private func pillButton(_ symbol: String, active: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(.white)
                .contentTransition(.symbolEffect(.replace))
                .animation(.snappy(duration: 0.2), value: symbol)
                .frame(width: 46, height: 46)
                .background { if active { Circle().fill(theme.accent.opacity(0.6)) } }
                .contentShape(Circle())
        }
        .buttonStyle(PressableStyle())
    }

    private func togglePiP() {
        hideTask?.cancel()
        pip.toggle()
        if pillExpanded { bumpPill() } else { scheduleHide() }
    }

    /// Shown in place of the video while it plays in the PiP window.
    private var pipPlaceholder: some View {
        VStack(spacing: 10) {
            Image(systemName: "pip").font(.system(size: 36, weight: .regular))
            Text("Playing in Picture in Picture").font(.headline)
        }
        .foregroundStyle(.white.opacity(0.7))
        .allowsHitTesting(false)
        .transition(.opacity)
    }

    private var nextButton: some View {
        ZStack {
            pillButton("forward.end.fill") { bumpPill(); playNext() }
                .opacity(switching != nil ? 0.35 : 1)
                .disabled(switching != nil)
            if switching != nil { ProgressView().tint(.white).allowsHitTesting(false) }
        }
    }

    /// "S1 · E3 · Episode title", or the movie's year.
    private var subtitleLine: String? {
        if let s = current.season, let e = current.episode {
            var t = "S\(s) · E\(e)"
            if let n = current.episodeTitle, !n.isEmpty { t += " · \(n)" }
            return t
        }
        return current.item.releaseInfo
    }

    // MARK: Buttons

    private func circleButton(_ symbol: String, size: CGFloat, icon: CGFloat, tint: Color? = nil,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: icon, weight: .semibold))
                .foregroundStyle(.white)
                .contentTransition(.symbolEffect(.replace))
                .animation(.snappy(duration: 0.2), value: symbol)
                .frame(width: size, height: size)
                .modifier(GlassCircle(on: glass, tint: tint))
                .contentShape(Circle())
        }
        .buttonStyle(PressableStyle())
    }

    private var audioMenu: some View {
        Menu {
            ForEach(model.audioTracks, id: \.id) { t in
                Button { model.selectAudio(t); bumpPill() } label: {
                    checkLabel(Reflect.trackTitle(t), Reflect.int(t.id) == model.activeAudioID)
                }
            }
        } label: {
            // Audio track / dub language. The speaker icon belongs to the volume button.
            Image(systemName: "waveform").font(.system(size: 19, weight: .semibold)).foregroundStyle(.white)
                .frame(width: 46, height: 46).contentShape(Circle())
        }
        .menuIndicator(.hidden)
        .tint(.white)
    }

    @ViewBuilder private func checkLabel(_ title: String, _ on: Bool) -> some View {
        if on { Label(title, systemImage: "checkmark") } else { Text(title) }
    }

    // MARK: Skip intro / next episode

    private var skipLayer: some View {
        VStack {
            Spacer()
            HStack {
                Spacer()
                SkipOverlay(playhead: model.playhead, segments: segments, loaded: segmentsLoaded, hasNext: nextEp != nil,
                            fallback: (current.season != nil && fallbackSkip > 0 && showControls) ? Double(fallbackSkip) : nil,
                            glass: glass,
                            onSeek: { t in Task { await model.seek(to: t); scheduleHide() } },
                            onNext: { playNext() })
                    .id(current.id)          // new episode = fresh "used" / "expired" state
            }
            .padding(.trailing, 28)
            .padding(.bottom, showControls ? 140 : 40)
        }
        .animation(.snappy(duration: 0.25), value: showControls)
    }

    /// Timestamps from TheIntroDB, and which episode comes next. Both run again whenever the episode changes.
    private func loadAux() async {
        nextEp = nil; segments = []; segmentsLoaded = false
        let req = current
        async let found = IntroClient.shared.segments(item: req.item, imdb: req.imdb, season: req.season, episode: req.episode)
        if let provider, req.season != nil { nextEp = await provider.next(req) }
        let segs = await found
        guard !Task.isCancelled else { return }
        segments = segs; segmentsLoaded = true
    }

    private func playNext() {
        guard let n = nextEp else { return }
        switchEpisode(n.season, n.episode)
    }

    // MARK: Subtitle panel

    private var subtitlePanel: some View {
        HStack(spacing: 0) {
            Spacer(minLength: 0)
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("Subtitles").font(.title3.weight(.semibold))
                    Spacer()
                    circleButton("xmark", size: 34, icon: 13) { closeSubtitles() }
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        VStack(spacing: 6) {
                            trackRow("Off", on: model.activeSubtitleID == nil) { model.selectSubtitle(nil) }
                            ForEach(model.subtitleTracks, id: \.id) { t in
                                trackRow(Reflect.trackTitle(t), on: Reflect.int(t.id) == model.activeSubtitleID) { model.selectSubtitle(t) }
                            }
                        }
                        onlineSubtitles
                        Text("APPEARANCE").font(.caption.weight(.bold)).tracking(1).foregroundStyle(.white.opacity(0.6))
                        SubtitleStyleControls(showsPreview: false, onDark: true)
                    }
                    .padding(.bottom, 6)
                }
                .scrollIndicators(.hidden)
            }
            .foregroundStyle(.white)
            .padding(18)
            .frame(width: 340)
            .modifier(GlassCard(on: glass))
            .padding(.vertical, 10).padding(.trailing, 10)
        }
    }

    @ViewBuilder private var onlineSubtitles: some View {
        let choices = OpenSubtitlesClient.choices(model.onlineSubs, preferred: subLang)
        if model.loadingOnline || !choices.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Text("OPENSUBTITLES").font(.caption.weight(.bold)).tracking(1).foregroundStyle(.white.opacity(0.6))
                    if model.loadingOnline { ProgressView().controlSize(.small).tint(.white) }
                }
                VStack(spacing: 6) {
                    ForEach(choices) { s in
                        let n = choices.filter { $0.lang == s.lang }.firstIndex(of: s).map { $0 + 1 } ?? 1
                        let multi = choices.filter { $0.lang == s.lang }.count > 1
                        trackRow(multi ? "\(s.languageName) \(n)" : s.languageName, on: false) { model.useOnline(s) }
                    }
                }
            }
        }
    }

    private func trackRow(_ title: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(title).font(.body.weight(.medium)).lineLimit(1)
                Spacer()
                if on { Image(systemName: "checkmark").font(.subheadline.weight(.bold)).foregroundStyle(theme.accent) }
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .background(Color.white.opacity(on ? 0.16 : 0.07), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func toggleSubtitles() {
        hideTask?.cancel()
        if showSubtitles { closeSubtitles(); return }
        // Controls get out of the way so the subtitles can be judged where they will really appear.
        withAnimation(.snappy(duration: 0.3)) { showSubtitles = true; showEpisodes = false; showSources = false; showSpeed = false; showInfo = false; showControls = false }
    }

    private func closeSubtitles() {
        withAnimation(.snappy(duration: 0.3)) { showSubtitles = false; showControls = true }
        scheduleHide()
    }

    // MARK: Speed panel

    /// Floats above the icon row; the video keeps playing and the controls stay up while it is open.
    private var speedLayer: some View {
        VStack {
            Spacer()
            HStack {
                Spacer()
                speedPanel
            }
            .padding(.trailing, 20)
            .padding(.bottom, 118)
        }
    }

    private var speedPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Playback speed").font(.title3.weight(.semibold))
                Spacer()
                Text(rateText(model.rate)).font(.title3.weight(.bold).monospacedDigit())
                    .foregroundStyle(model.rate == 1 ? Color.white : theme.accent)
                circleButton("xmark", size: 34, icon: 13) { closeSpeed() }
            }
            HStack(spacing: 12) {
                Image(systemName: "tortoise.fill").font(.system(size: 18)).foregroundStyle(.white.opacity(0.7))
                Slider(value: Binding(get: { model.rate }, set: { model.setRate($0) }), in: 0.5...2.0)
                    .tint(.white)
                Image(systemName: "hare.fill").font(.system(size: 18)).foregroundStyle(.white.opacity(0.7))
            }
            HStack {
                Text("0.5×")
                Spacer()
                Button("Reset to 1×") { model.setRate(1) }
                    .buttonStyle(.plain).fontWeight(.semibold)
                    .opacity(model.rate == 1 ? 0.35 : 1).disabled(model.rate == 1)
                Spacer()
                Text("2×")
            }
            .font(.subheadline.monospacedDigit()).foregroundStyle(.white.opacity(0.75))
        }
        .foregroundStyle(.white)
        .padding(18)
        .frame(width: 360)
        .modifier(GlassCard(on: glass))
    }

    private func rateText(_ r: Double) -> String {
        var t = String(format: "%.2f", r)
        while t.hasSuffix("0") { t.removeLast() }
        if t.hasSuffix(".") { t.removeLast() }
        return t + "×"
    }

    private func toggleSpeed() {
        hideTask?.cancel()
        if showSpeed { closeSpeed(); return }
        withAnimation(.snappy(duration: 0.3)) { showSpeed = true; showSubtitles = false; showSources = false; showEpisodes = false; showInfo = false }
    }

    private func closeSpeed() {
        withAnimation(.snappy(duration: 0.3)) { showSpeed = false }
        scheduleHide()
    }

    // MARK: Info card

    /// Bottom card over the video (which keeps playing): thumbnail, title, date, runtime, ratings and synopsis of
    /// the episode being watched, or of the movie.
    private func infoPanel(_ info: PlayerInfo) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer(minLength: 0)
            PlayerInfoCard(info: info, logo: pausedLogo, onClose: { closeInfo() })
                .foregroundStyle(.white)
                .padding(20)
                .frame(maxWidth: 720)
                .modifier(GlassCard(on: glass))
                .padding(.horizontal, 20).padding(.bottom, 10)
        }
    }

    private func openInfo() {
        hideTask?.cancel()
        // Filled in before the card animates in, so it slides up with content instead of popping in afterwards.
        info = basicInfo()
        withAnimation(.snappy(duration: 0.3)) {
            showInfo = true; showEpisodes = false; showSubtitles = false; showSources = false; showSpeed = false; showControls = false
        }
    }

    private func closeInfo() {
        withAnimation(.snappy(duration: 0.3)) { showInfo = false; showControls = true }
        scheduleHide()
    }

    /// What is known without a network call: the request itself plus the catalog entry.
    private func basicInfo() -> PlayerInfo {
        let req = current, item = current.item
        if let s = req.season, let e = req.episode {
            return PlayerInfo(kicker: item.name, episodeTag: "S\(s) · E\(e)", isLoading: true,
                              title: req.episodeTitle ?? "Episode \(e)",
                              image: req.thumb ?? item.backdropURL, overview: nil)
        }
        return PlayerInfo(kicker: nil, title: item.name, image: req.thumb ?? item.backdropURL,
                          overview: item.description, date: item.releaseInfo)
    }

    /// IMDb, Rotten Tomatoes, Metacritic... for a title. Empty without an MDBList key.
    private func mdbRatings(for req: PlayRequest) async -> [MDBListClient.Rating] {
        guard MDBListClient.shared.hasKey, !req.imdb.isEmpty else { return [] }
        return await MDBListClient.shared.ratings(imdb: req.imdb, type: req.item.type)
    }

    /// Completes the card from TMDB / MDBList. Runs while the card is open, again if the episode changes under it.
    private func loadInfo() async {
        let req = current, item = current.item
        var out = basicInfo()
        info = out

        if let s = req.season, let e = req.episode {
            // Episode: its own still, synopsis, air date, runtime and TMDB rating.
            if let ep = await provider?.episodes(s).first(where: { $0.id == e }) {
                out.title = ep.name
                out.image = ep.image ?? out.image
                out.overview = ep.overview
                out.date = PlayerInfo.pretty(ep.airDate)
                out.runtime = ep.runtime
                if let r = ep.rating, r > 0 {
                    out.ratings = [MDBListClient.Rating(label: "TMDB", text: String(format: "%.1f", r), score: r)]
                }
            }
            // A brand-new episode often has no synopsis yet: say so rather than showing nothing.
            if (out.overview ?? "").isEmpty, let d = item.description, !d.isEmpty {
                out.overview = d
                out.overviewNote = "About the series"
            }
        } else {
            // Movie: the whole film. Details (release date, runtime, TMDB vote) and MDBList ratings load side by side.
            async let details = TMDBClient.shared.cachedDetails(for: item.id, type: item.type)
            async let mdb = mdbRatings(for: req)
            let d = await details
            var ratings = await mdb
            func add(_ label: String, _ v: Double?) {
                if let v, v > 0, !ratings.contains(where: { $0.label == label }) {
                    ratings.append(MDBListClient.Rating(label: label, text: String(format: "%.1f", v), score: v))
                }
            }
            add("TMDB", d?.voteAverage)
            add(item.ratingLabel, item.rating)      // the catalog's own score when nothing else has one
            if let o = d?.overview, !o.isEmpty { out.overview = o }
            out.date = PlayerInfo.pretty(d?.releaseDate) ?? out.date
            out.runtime = d?.minutes
            out.ratings = ratings
        }
        guard !Task.isCancelled else { return }
        out.isLoading = false
        info = out
    }

    // MARK: Volume pill

    /// Seconds after the last adjustment before the pill returns to its icons.
    private static let volumeLife: Double = 3

    private func toggleVolume() {
        if showVolume { closeVolume(); return }
        hideTask?.cancel()                      // controls stay up while the slider is open
        volume.refresh()
        pillTask?.cancel()
        withAnimation(.snappy(duration: 0.3)) { showVolume = true; showSpeed = false; pillExpanded = false }
        bumpVolume()
    }

    private func closeVolume() {
        volumeTask?.cancel()
        volumeDragging = false
        volume.isAdjusting = false
        guard showVolume else { return }
        withAnimation(.snappy(duration: 0.3)) { showVolume = false }
        scheduleHide()
    }

    /// (Re)starts the countdown. It does not run while a finger is on the slider; lifting it starts it again.
    private func bumpVolume() {
        volumeTask?.cancel()
        guard showVolume, !volumeDragging else { return }
        volumeTask = Task {
            try? await Task.sleep(for: .seconds(Self.volumeLife))
            guard !Task.isCancelled else { return }
            closeVolume()
        }
    }

    private func volumeEditing(_ on: Bool) {
        volumeDragging = on
        volume.isAdjusting = on
        if on { volumeTask?.cancel() } else { bumpVolume() }
    }

    // MARK: Sources panel

    private var sourcesPanel: some View {
        HStack(spacing: 0) {
            Spacer(minLength: 0)
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("Sources").font(.title3.weight(.semibold))
                    Spacer()
                    if sourceGroups.count > 1 {
                        AddonFilterMenu(groups: sourceGroups, selection: $sourceFilter, onDark: true)
                    }
                    circleButton("xmark", size: 34, icon: 13) { closeSources() }
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        if loadingSources && sourceGroups.isEmpty {
                            ProgressView().tint(.white).frame(maxWidth: .infinity).padding(.top, 30)
                        }
                        if loadingSources && !sourceGroups.isEmpty {
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.small).tint(.white)
                                Text("Checking more add-ons…").font(.footnote).foregroundStyle(.white.opacity(0.6))
                            }
                            .frame(maxWidth: .infinity)
                        }
                        ForEach(SourceFilter.apply(sourceGroups, sourceFilter), id: \.0.id) { addon, items in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(addon.manifest.name.uppercased()).font(.caption.weight(.bold)).tracking(1)
                                    .foregroundStyle(.white.opacity(0.6))
                                ForEach(items) { s in sourceRow(addon, s) }
                                if let n = p2pOffCounts[addon.id], n > 0 {
                                    Label("\(n) torrent source\(n == 1 ? "" : "s") unavailable: P2P is off (Settings → Peer-to-peer)",
                                          systemImage: "antenna.radiowaves.left.and.right.slash")
                                        .font(.footnote).foregroundStyle(.white.opacity(0.6))
                                        .padding(.horizontal, 4)
                                }
                            }
                        }
                        if !loadingSources && sourceGroups.isEmpty {
                            Text("No playable sources found for this title.")
                                .font(.subheadline).foregroundStyle(.white.opacity(0.7))
                        }
                    }
                    .padding(.bottom, 6)
                }
                .scrollIndicators(.hidden)
            }
            .foregroundStyle(.white)
            .padding(18)
            .frame(width: 360)
            .modifier(GlassCard(on: glass))
            .padding(.vertical, 10).padding(.trailing, 10)
        }
    }

    private func sourceRow(_ addon: Addon, _ s: StreamItem) -> some View {
        let isCurrent = addon.id == current.sourceAddonID && s.signature == current.sourceSignature
        let detail = s.description ?? s.title
        return Button { selectSource(addon, s) } label: {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(s.name ?? s.title ?? "Stream").font(.body.weight(.semibold)).lineLimit(2)
                    if let d = detail, d != s.name {
                        Text(d).font(.footnote).foregroundStyle(.white.opacity(0.65)).lineLimit(3)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if isCurrent { Image(systemName: "checkmark").font(.subheadline.weight(.bold)).foregroundStyle(theme.accent) }
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .background(Color.white.opacity(isCurrent ? 0.16 : 0.07), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func openSources() {
        hideTask?.cancel()
        sourceGroups = []
        sourceFilter = nil
        p2pOffCounts = [:]
        withAnimation(.snappy(duration: 0.3)) { showSources = true; showSubtitles = false; showEpisodes = false; showSpeed = false; showInfo = false; showControls = false }
        Task { await loadSources() }
    }

    private func closeSources() {
        withAnimation(.snappy(duration: 0.3)) { showSources = false; showControls = true }
        scheduleHide()
    }

    /// Same query the detail page runs: every add-on that serves this title / episode, playable streams only.
    /// Groups appear as each add-on answers, in the user's add-on order.
    private func loadSources() async {
        loadingSources = true; defer { loadingSources = false }
        let r = current
        let sid = (r.season != nil && r.episode != nil) ? "\(r.imdb):\(r.season ?? 0):\(r.episode ?? 0)" : r.imdb
        let addons = store.enabledAddons
        var raw: [(Addon, [StreamItem])] = []
        for await group in AddonClient.shared.streamUpdates(for: sid, type: r.item.type, addons: addons) {
            guard !Task.isCancelled, showSources else { return }
            raw = AddonClient.ordered(raw + [group], by: addons)
            var ordered: [(Addon, [StreamItem])] = []
            var off: [String: Int] = [:]
            for (a, items) in raw {
                let playable = items.filter(\.isPlayable)
                let hidden = items.filter(\.p2pOff).count
                if hidden > 0 { off[a.id] = hidden }
                // An add-on whose torrents are all hidden still gets a group, so the panel can say why.
                if !playable.isEmpty || hidden > 0 { ordered.append((a, playable)) }
            }
            p2pOffCounts = off
            sourceGroups = ordered
        }
    }

    /// Same episode, different stream: carries the position over and keeps the saved progress.
    private func selectSource(_ addon: Addon, _ s: StreamItem) {
        guard let t = s.playTarget else { return }
        if addon.id == current.sourceAddonID && s.signature == current.sourceSignature { closeSources(); return }
        let resume = model.playhead.position
        save()
        let next = PlayRequest(url: t.url, headers: s.requestHeaders, item: current.item, key: current.key, imdb: current.imdb,
                               season: current.season, episode: current.episode, episodeTitle: current.episodeTitle,
                               logo: current.logo, thumb: current.thumb,
                               sourceAddonID: addon.id, sourceSignature: s.signature, p2p: t.p2p)
        current = next
        withAnimation(.snappy(duration: 0.3)) { showSources = false; showControls = true }
        Task {
            await model.start(next, resume: resume, replacing: true)
            scheduleHide()
        }
    }

    // MARK: Episode carousel

    private func episodePanel(_ provider: EpisodeProvider) -> some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            EpisodePanel(provider: provider, showName: current.item.name,
                         currentSeason: current.season, currentEpisode: current.episode,
                         switching: switching,
                         onSelect: { s, ep in switchEpisode(s, ep) },
                         onClose: { closeEpisodes() })
        }
    }

    private func openEpisodes() {
        guard provider != nil else { return }
        hideTask?.cancel()
        withAnimation(.snappy(duration: 0.3)) { showEpisodes = true; showSubtitles = false; showSources = false; showSpeed = false; showInfo = false; showControls = false }
    }

    private func closeEpisodes() {
        withAnimation(.snappy(duration: 0.3)) { showEpisodes = false; showControls = true }
        scheduleHide()
    }

    /// Jumps to another episode. `resolve` keeps the source you are watching now (same add-on and release name),
    /// then falls back to the pinned source, then to any playable stream.
    private func switchEpisode(_ s: Int, _ ep: EpisodeItem) {
        guard let provider, switching == nil else { return }
        if s == current.season, ep.id == current.episode { closeEpisodes(); return }
        switching = ep.id
        Task {
            let next = await provider.resolve(s, ep, current)
            switching = nil
            guard !closing else { return }
            guard let next else { flash("No playable source found for that episode"); return }
            finalizeCurrent()                 // save + scrobble the episode we are leaving
            current = next
            scrobbled = false
            withAnimation(.snappy(duration: 0.3)) { showEpisodes = false; showControls = true }
            await model.start(next, resume: resumePoint(for: next), replacing: true)
            scheduleHide()
        }
    }

    private func flash(_ message: String) {
        notice = message
        Task {
            try? await Task.sleep(for: .seconds(2.6))
            if notice == message { notice = nil }
        }
    }

    private func toast(_ message: String) -> some View {
        VStack {
            Text(message).font(.subheadline.weight(.semibold)).foregroundStyle(.white)
                .padding(.horizontal, 16).padding(.vertical, 10)
                .background(.black.opacity(0.78), in: Capsule())
                .padding(.top, 18)
            Spacer()
        }
        .transition(.move(edge: .top).combined(with: .opacity))
        .allowsHitTesting(false)
    }

    // MARK: Paused + error

    /// Paused with the controls up and nothing else open.
    private var pausedDim: Bool {
        model.isPaused && model.error == nil && showControls && !showEpisodes && !showSubtitles && !showSources && !showSpeed && !showInfo
    }

    /// Dims the frozen frame with one flat gradient. A real blur would have to snapshot the video surface and
    /// re-filter it every time, which costs far more than a single translucent layer.
    private var pausedOverlay: some View {
        LinearGradient(colors: [.black.opacity(0.4), .black.opacity(0.6)], startPoint: .top, endPoint: .bottom)
            .ignoresSafeArea()
            .allowsHitTesting(false)
            .transition(.opacity)
    }

    /// The show logo, right above the title. Nothing is drawn when no logo was found.
    /// (The synopsis lives in the info card now: tap the title.)
    @ViewBuilder private var pausedInfo: some View {
        if let logo = pausedLogo {
            Image(uiImage: logo).resizable().scaledToFit()
                .frame(maxWidth: 220, maxHeight: 48, alignment: .leading)
                .shadow(color: .black.opacity(0.45), radius: 6)
                .accessibilityHidden(true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .allowsHitTesting(false)
                .transition(.opacity)
        }
    }

    /// Logo is per show, so it is fetched once and kept across episode changes. Downsampled and cached by ImagePipeline.
    private func loadPausedLogo() async {
        pausedLogo = nil
        let item = current.item
        var url = current.logo
        if url == nil { url = await LogoResolver.shared.logo(for: item) }
        guard let url, let img = await ImagePipeline.shared.image(for: url, maxPixel: 440), !Task.isCancelled else { return }
        pausedLogo = img
    }

    private func errorCard(_ message: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle.fill").font(.largeTitle).foregroundStyle(.yellow)
            Text("Couldn't play this source").font(.headline)
            Text(message).font(.footnote).multilineTextAlignment(.center).textSelection(.enabled)
            Text("The link may have expired or the server may be refusing the request. Try another source, or open this one in another player.")
                .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            HStack {
                Button("Open in VLC") { open("vlc-x-callback://x-callback-url/stream?url=") }
                Button("Open in Infuse") { open("infuse://x-callback-url/play?url=") }
            }
            .buttonStyle(.glass)
        }
        .padding(24)
        .frame(maxWidth: 360)
        .glassEffect(.regular, in: .rect(cornerRadius: 24))
        .padding(20)
    }

    // MARK: Actions

    private func begin() async {
        model.configure(defaultSubtitleLanguage: subLang == "off" ? nil : subLang)
        await model.start(current, resume: resumePoint(for: current))
        scheduleHide()
    }

    private func resumePoint(for r: PlayRequest) -> Double? {
        if let e = history.entry(for: r.item.id), e.key == r.key, e.position > 30, !e.isFinished { return e.position }
        return nil
    }

    private func tapBackground() {
        if showEpisodes { closeEpisodes(); return }
        if showSubtitles { closeSubtitles(); return }
        if showSources { closeSources(); return }
        if showSpeed { closeSpeed(); return }
        if showInfo { closeInfo(); return }
        if showVolume { closeVolume(); return }
        if pillExpanded { foldPill(); scheduleHide(); return }
        withAnimation(.easeInOut(duration: 0.2)) { showControls.toggle() }
        if showControls { scheduleHide() }
    }

    private func scheduleHide() {
        hideTask?.cancel()
        guard model.isPlaying, !pip.isActive else { return }
        hideTask = Task {
            try? await Task.sleep(for: .seconds(3.5))
            guard !Task.isCancelled, !model.playhead.scrubbing, !showEpisodes, !showSubtitles, !showSources, !showSpeed, !showVolume, !pillExpanded, !showInfo else { return }
            withAnimation(.easeInOut(duration: 0.25)) { showControls = false }
        }
    }

    /// Adds the time since the last call to the watch log (only while the video is actually playing).
    private func logPlayTime() {
        let now = Date()
        if model.isPlaying && !model.isPaused && !model.isBuffering {
            watchLog.record(seconds: min(now.timeIntervalSince(lastTick), 20), at: now)
        }
        lastTick = now
    }

    /// Keeps the screen awake only while something is actually playing: a paused or failed player lets the
    /// auto-lock timer run, instead of holding the display on indefinitely.
    private func updateIdleTimer() {
        UIApplication.shared.isIdleTimerDisabled = !model.isPaused && model.error == nil
    }

    /// `isFinal: false` is the periodic save during playback (storage only, no UI churn behind the player).
    private func save(isFinal: Bool = true) {
        let p = model.playhead.position, d = model.playhead.duration
        guard d > 0, p > 0 else { return }
        if isFinal {
            history.update(current.item, key: current.key, position: p, duration: d,
                           season: current.season, episode: current.episode,
                           episodeTitle: current.episodeTitle, thumb: current.thumb?.absoluteString)
        } else {
            history.checkpoint(current.item, key: current.key, position: p, duration: d,
                               season: current.season, episode: current.episode,
                               episodeTitle: current.episodeTitle, thumb: current.thumb?.absoluteString)
        }
        // A saved movie that has been watched through moves to "Watched" (Simkl does this itself when connected).
        if current.item.type == "movie", p >= d * 0.92 { library.markWatchedIfSaved(current.item.id) }
    }

    /// Saves progress and tells Simkl we stopped. Used when leaving an episode (close or switch).
    private func finalizeCurrent() {
        hideTask?.cancel()
        logPlayTime()
        watchLog.flush()
        save()
        let d = model.playhead.duration
        if d > 0, libraryPrefs.usesSimkl(simkl) { simkl.scrobble("stop", current, progress: model.playhead.position / d * 100) }
    }

    /// X button. Dismisses first so it always responds instantly, then tears the engine down a moment later.
    private func close() {
        guard !closing else { return }
        closing = true
        finalizeCurrent()
        let m = model
        onClose()
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(250))
            m.shutdown()
        }
    }

    private func open(_ prefix: String) {
        guard current.p2p == nil else { return } // a loopback torrent URL means nothing to another app
        let enc = current.url.absoluteString.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
        if let u = URL(string: prefix + enc) { openURL(u) }
    }
}

// MARK: - Seek bar

/// Liquid Glass scrubber in the style of the Apple TV player: a glass capsule track with a white fill that grows
/// thicker while you drag, plus a glass thumb. Reads the playhead itself so only this view redraws on clock ticks.
private struct SeekBar: View {
    let playhead: Playhead
    let glass: Bool
    var onScrubStart: () -> Void = {}
    let onCommit: (Double) -> Void
    @State private var dragValue: Double?

    private var shown: Double { dragValue ?? playhead.position }

    var body: some View {
        let dur = max(playhead.duration, 1)
        let active = dragValue != nil
        HStack(spacing: 12) {
            Text(Fmt.clock(shown)).frame(width: 58, alignment: .leading)
            GeometryReader { geo in
                let w = max(geo.size.width, 1)
                let frac = min(max(shown / dur, 0), 1)
                // Buffered region = from the playhead to the end of what is downloaded ahead of it.
                let posFrac = min(max(playhead.position / dur, 0), 1)
                let bufFrac = min(max(max(playhead.buffered, playhead.position) / dur, 0), 1)
                let h: CGFloat = active ? 20 : 12
                let knob: CGFloat = 30
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.clear).frame(height: h)
                        .modifier(GlassCapsule(on: glass))
                    ZStack(alignment: .leading) {
                        Rectangle().fill(.white.opacity(0.38))
                            .frame(width: max(w * (bufFrac - posFrac), 0))
                            .offset(x: w * posFrac)
                    }
                    .frame(width: w, height: h, alignment: .leading)
                    .clipShape(Capsule())
                    .animation(.linear(duration: 0.4), value: bufFrac)
                    // The fill is a plain rectangle clipped by the track shape, so only its left end is rounded.
                    ZStack(alignment: .leading) {
                        Rectangle().fill(.white).frame(width: w * frac)
                    }
                    .frame(width: w, height: h, alignment: .leading)
                    .clipShape(Capsule())
                    Circle().fill(Color.clear).frame(width: knob, height: knob)
                        .modifier(GlassCircle(on: glass && active, tint: .white))
                        .offset(x: w * frac - knob / 2)
                        .scaleEffect(active ? 1 : 0.4)
                        .opacity(active ? 1 : 0)
                        .allowsHitTesting(false)
                }
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { g in
                            if dragValue == nil { playhead.scrubbing = true; onScrubStart() }
                            dragValue = min(max(g.location.x / w, 0), 1) * dur
                        }
                        .onEnded { g in
                            let v = min(max(g.location.x / w, 0), 1) * dur
                            dragValue = nil
                            playhead.scrubbing = false
                            onCommit(v)
                        }
                )
                .animation(.snappy(duration: 0.18), value: active)
            }
            .frame(height: 40)
            Text("-" + Fmt.clock(max(dur - shown, 0))).frame(width: 62, alignment: .trailing)
        }
        .font(.system(size: 14, weight: .semibold).monospacedDigit())
        .foregroundStyle(.white.opacity(0.85))
    }
}

// MARK: - Skip intro / next episode button

/// One floating button that changes with the moment: Skip Intro / Recap / Preview during those segments,
/// "Next Episode" in the credits or the last 45 s, and (when no timestamps exist) a manual skip while controls show.
private struct SkipOverlay: View {
    let playhead: Playhead
    let segments: [SkipSegment]
    let loaded: Bool
    let hasNext: Bool
    let fallback: Double?
    let glass: Bool
    let onSeek: (Double) -> Void
    let onNext: () -> Void

    private struct Choice { let title: String; let symbol: String; let target: Double?; var isFallback = false }   // nil target = next episode

    /// The manual "Skip 85s" button is a convenience, not a fixture: one tap per episode, and each time it
    /// appears it goes away again after a few seconds. (The parent gives this view a new identity per episode.)
    @State private var fallbackUsed = false
    @State private var fallbackExpired = false
    /// Resumed mid-episode (playback opened past the start): the manual skip isn't offered at all.
    @State private var resumed = false
    private static let fallbackLife: Double = 12

    /// Would the manual button be on screen if it hadn't expired? Also drives the expiry timer.
    private var fallbackEligible: Bool {
        guard loaded, !resumed, segments.isEmpty, fallback != nil, !fallbackUsed, !fallbackExpired else { return false }
        let p = playhead.position
        return playhead.duration > 0 && p >= 3 && p <= 420
    }

    private var choice: Choice? {
        let p = playhead.position, d = playhead.duration
        guard d > 0 else { return nil }
        let seg = segments.first { p >= $0.start - 0.5 && p < ($0.end ?? d) - 1.5 }
        if hasNext && ((d - p <= 45 && p > 60) || seg?.kind == .credits) {
            return Choice(title: "Next Episode", symbol: "forward.end.fill", target: nil)
        }
        if let seg { return Choice(title: seg.label, symbol: "forward.fill", target: seg.end ?? d) }
        if fallbackEligible, let f = fallback {
            return Choice(title: "Skip \(Int(f))s", symbol: "goforward", target: p + f, isFallback: true)
        }
        return nil
    }

    var body: some View {
        let c = choice
        ZStack {
            if let c {
                Button {
                    if c.isFallback { fallbackUsed = true }
                    if let t = c.target { onSeek(t) } else { onNext() }
                } label: {
                    Label(c.title, systemImage: c.symbol)
                        .font(.system(size: 17, weight: .semibold)).foregroundStyle(.white)
                        .padding(.horizontal, 22).frame(height: 48)
                        .modifier(GlassCapsule(on: glass))
                        .contentShape(Capsule())
                }
                .buttonStyle(PressableStyle())
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(.snappy(duration: 0.25), value: c?.title)
        // Fresh timer every time the manual button becomes eligible (controls shown again); cleared when it stops.
        .onAppear { resumed = playhead.position > 30 }
        .task(id: fallbackEligible) {
            guard fallbackEligible else { return }
            try? await Task.sleep(for: .seconds(Self.fallbackLife))
            if !Task.isCancelled { fallbackExpired = true }
        }
    }
}

// MARK: - Episode panel

/// Bottom sheet over the video: season pills + a carousel of episode thumbnails.
private struct EpisodePanel: View {
    let provider: EpisodeProvider
    let showName: String
    let currentSeason: Int?
    let currentEpisode: Int?
    let switching: Int?
    let onSelect: (Int, EpisodeItem) -> Void
    let onClose: () -> Void
    @Environment(ThemeStore.self) private var theme

    @State private var season: Int
    @State private var episodes: [EpisodeItem] = []
    @State private var loading = true

    private let cardWidth: CGFloat = 240
    private var cardHeight: CGFloat { cardWidth * 9 / 16 }

    init(provider: EpisodeProvider, showName: String, currentSeason: Int?, currentEpisode: Int?,
         switching: Int?, onSelect: @escaping (Int, EpisodeItem) -> Void, onClose: @escaping () -> Void) {
        self.provider = provider
        self.showName = showName
        self.currentSeason = currentSeason
        self.currentEpisode = currentEpisode
        self.switching = switching
        self.onSelect = onSelect
        self.onClose = onClose
        _season = State(initialValue: currentSeason ?? provider.seasons.first?.id ?? 1)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(showName).font(.system(size: 22, weight: .bold)).lineLimit(1)
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "chevron.down").font(.system(size: 13, weight: .bold))
                        .frame(width: 32, height: 32).background(.white.opacity(0.16), in: Circle())
                        .padding(6).contentShape(Rectangle())
                }
                .buttonStyle(PressableStyle())
            }
            .padding(.horizontal, 24)

            if provider.seasons.count > 1 { seasonPills }
            carousel
        }
        .foregroundStyle(.white)
        .padding(.top, 20).padding(.bottom, 12)
        .background {
            LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black.opacity(0.88), location: 0.3),
                                   .init(color: .black.opacity(0.95), location: 1)],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
        }
        .task(id: season) {
            loading = true; episodes = []
            let list = await provider.episodes(season)
            guard !Task.isCancelled else { return }
            episodes = list; loading = false
        }
    }

    private var seasonPills: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(provider.seasons) { s in
                    Button { season = s.id } label: {
                        Text(s.title).font(.system(size: 16, weight: .semibold))
                            .padding(.horizontal, 16).padding(.vertical, 8)
                            .foregroundStyle(s.id == season ? theme.onAccent : Color.white)
                            .background(s.id == season ? theme.accent : Color.white.opacity(0.14), in: Capsule())
                    }
                    .buttonStyle(PressableStyle())
                }
            }
            .padding(.horizontal, 24)
        }
        .scrollIndicators(.hidden)
    }

    private var carousel: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                LazyHStack(spacing: 12) {
                    if loading && episodes.isEmpty {
                        ProgressView().tint(.white).frame(width: cardWidth, height: cardHeight)
                    }
                    ForEach(episodes) { ep in card(ep).id(ep.id) }
                    if !loading && episodes.isEmpty {
                        Text("No episode list available for this season")
                            .font(.subheadline).foregroundStyle(.white.opacity(0.7)).frame(height: cardHeight)
                    }
                }
                .padding(.horizontal, 24)
            }
            .scrollIndicators(.hidden)
            .onChange(of: episodes.count) { _, _ in
                if season == currentSeason, let e = currentEpisode { proxy.scrollTo(e, anchor: .center) }
            }
        }
    }

    private func card(_ ep: EpisodeItem) -> some View {
        let isCurrent = season == currentSeason && ep.id == currentEpisode
        let extras = [ep.runtime.map { "\($0) min" }, ep.rating.map { String(format: "★ %.1f", $0) }]
            .compactMap { $0 }.joined(separator: " · ")
        return Button { onSelect(season, ep) } label: {
            VStack(alignment: .leading, spacing: 6) {
                StillImage(url: ep.image, size: cardWidth)
                    .frame(width: cardWidth, height: cardHeight)
                    .overlay { LinearGradient(colors: [.clear, .black.opacity(0.5)], startPoint: .center, endPoint: .bottom) }
                    .overlay(alignment: .bottomLeading) {
                        Text("E\(ep.id)").font(.system(size: 13, weight: .bold))
                            .padding(.horizontal, 7).padding(.vertical, 3)
                            .background(.black.opacity(0.6), in: Capsule()).padding(8)
                    }
                    .overlay(alignment: .topTrailing) {
                        if isCurrent {
                            Label("Playing", systemImage: "waveform").font(.system(size: 13, weight: .bold))
                                .foregroundStyle(theme.onAccent)
                                .padding(.horizontal, 8).padding(.vertical, 4)
                                .background(theme.accent, in: Capsule()).padding(8)
                        }
                    }
                    .overlay {
                        if switching == ep.id {
                            ZStack { Color.black.opacity(0.55); ProgressView().tint(.white) }
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .selectionRing(isCurrent, radius: 12)
                Text(ep.name).font(.system(size: 16, weight: .semibold)).lineLimit(1)
                    .frame(width: cardWidth, alignment: .leading)
                Text(extras.isEmpty ? " " : extras).font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.65)).lineLimit(1)
            }
        }
        .buttonStyle(PressableStyle())
        .disabled(switching != nil)
    }
}
