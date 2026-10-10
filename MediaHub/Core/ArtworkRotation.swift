import SwiftUI

/// Decides which artwork a title shows today.
///
/// - Local and deterministic: the choice is a pure function of (title, role, day) over the alternates already in
///   `ArtworkPool`. No request is made to rotate anything. Slot 0 of every cycle is the artwork the app always
///   showed, so titles also come back to their familiar poster, and each title starts at its own offset so a whole
///   row never changes in lockstep.
/// - Stable: the day number only moves when the app comes to the foreground (`refresh()`), never while a screen is
///   being looked at, so artwork never swaps under the user's finger and no timer or observer runs in between.
/// - Frugal: a rotated image is only used when it is free to fetch (Wi-Fi, no Low Data Mode, no Low Power Mode,
///   not hot) or already sitting in the disk cache. Otherwise the standard artwork is shown and rotation resumes
///   the next time the cell is built on a good connection.
@MainActor @Observable
final class ArtworkRotation {
    static let shared = ArtworkRotation()

    enum Period: Sendable {
        /// New artwork each local calendar day (default).
        case daily
        /// New artwork each app launch.
        case session
    }

    /// What a view should load. `fallback` is set only when `url` is optional rotated artwork that might not be
    /// available after all (evicted from cache, network changed mid-flight): the view then falls back to it.
    struct Choice: Sendable, Equatable {
        let url: URL?
        let fallback: URL?
    }

    @ObservationIgnored var period: Period = .daily
    private(set) var epoch: Int

    /// Titles whose poster is held still: id -> TMDB file path of the kept poster (\"\" = the default one).
    /// Observed, so every poster of the title updates the moment it is pinned or released.
    private(set) var pinned: [String: String] = UserDefaults.standard.dictionary(forKey: ArtworkRotation.pinnedKey) as? [String: String] ?? [:]
    static let pinnedKey = "artwork.pinned"

    @ObservationIgnored private let sessionSeed = Int.random(in: 0..<10_000)
    /// Picks are remembered for the epoch, so a title never changes artwork mid-day even if more alternates are
    /// discovered meanwhile ("" = keep the default).
    @ObservationIgnored private var pickMemo: [String: String] = [:]
    @ObservationIgnored private var probeMemo: [URL: (net: NetworkConditions.Snapshot, cached: Bool)] = [:]

    private init() { epoch = Self.dayNumber() }

    private static func dayNumber() -> Int { Calendar.current.ordinality(of: .day, in: .era, for: .now) ?? 0 }

    /// Call when the app becomes active.
    func refresh() {
        let e = period == .daily ? Self.dayNumber() : sessionSeed
        guard e != epoch else { return }
        epoch = e
        pickMemo.removeAll(keepingCapacity: true)
        probeMemo.removeAll(keepingCapacity: true)
    }

    // MARK: Keep current poster

    func isPinned(_ id: String) -> Bool { pinned[id] != nil }

    /// Stops the daily rotation of this title's poster at whatever it shows right now.
    func pinPoster(_ item: MetaPreview) {
        let base = item.posterURL
        var keep = ""
        // Keep what is actually on screen: today's alternate only if it is being shown (not held back by the network).
        if let path = pick(id: item.id, role: .poster, base: base, epoch: epoch),
           let url = TMDBImage.url(path: path, role: .poster, pixelWidth: 500), url != base, isAvailable(url) {
            keep = path
        }
        pinned[item.id] = keep
        UserDefaults.standard.set(pinned, forKey: Self.pinnedKey)
    }

    func unpin(_ id: String) {
        guard pinned[id] != nil else { return }
        pinned[id] = nil
        UserDefaults.standard.set(pinned, forKey: Self.pinnedKey)
    }

    // MARK: Choices

    /// Poster card artwork. `longestEdgePixels` is the poster's height in pixels (points x display scale).
    func poster(for item: MetaPreview, longestEdgePixels: CGFloat) -> Choice {
        choose(item: item, role: .poster, base: item.posterURL) {
            TMDBImage.url(path: $0, role: .poster, pixelWidth: longestEdgePixels * 2 / 3)
        }
    }

    /// Full-width hero / feature card artwork: backdrop on wide screens, poster on phones (as `heroURL` does).
    func hero(for item: MetaPreview, wide: Bool) -> Choice {
        let role: ArtworkRole = wide ? .backdrop : .poster
        return choose(item: item, role: role, base: item.heroURL(wide: wide)) {
            TMDBImage.url(path: $0, role: role, pixelWidth: wide ? 1280 : 780)
        }
    }

    /// Details-page backdrop: follows the same rotation as the cards and is always fetched at full resolution
    /// (TMDB "original", typically 1920 px or more), since it fills the screen width and is looked at closely.
    /// On a restricted network, or if the full-size file isn't available, it shows the 1280 px version instead.
    func detailBackdrop(for item: MetaPreview) -> Choice {
        let day = epoch
        let standard = Choice(url: item.heroURL(wide: true), fallback: nil)      // w1280, one step above the old w780
        let tmdbBackdrop = item.background.flatMap(URL.init(string:)).flatMap { $0.host == "image.tmdb.org" ? $0 : nil }
        // Rotated pick for today, or the title's own backdrop when today's slot is the default.
        guard let path = pick(id: item.id, role: .backdrop, base: tmdbBackdrop, epoch: day)
                ?? tmdbBackdrop.map({ "/" + $0.lastPathComponent }),
              let full = TMDBImage.url(path: path, role: .backdrop, pixelWidth: 1920),
              full != standard.url, isAvailable(full) else { return standard }
        return Choice(url: full, fallback: standard.url)
    }

    private func choose(item: MetaPreview, role: ArtworkRole, base: URL?, build: (String) -> URL?) -> Choice {
        let day = epoch                                    // read here so views re-evaluate when the epoch moves
        let standard = Choice(url: base, fallback: nil)
        guard let path = pick(id: item.id, role: role, base: base, epoch: day),
              let rotated = build(path), rotated != base,
              isAvailable(rotated) else { return standard }
        return Choice(url: rotated, fallback: base)
    }

    private func pick(id: String, role: ArtworkRole, base: URL?, epoch: Int) -> String? {
        if role == .poster, let kept = pinned[id] { return kept.isEmpty ? nil : kept }
        let key = "\(id)|\(role.rawValue)|\(epoch)"
        if let hit = pickMemo[key] { return hit.isEmpty ? nil : hit }
        let basePath = base.flatMap { $0.host == "image.tmdb.org" ? "/" + $0.lastPathComponent : nil }
        let alternates = ArtworkPool.shared.candidates(for: id, role: role).map(\.path).filter { $0 != basePath }
        var result = ""
        if !alternates.isEmpty {
            let slots = alternates.count + 1                         // slot 0 = the default artwork
            let phase = Int(Self.stableHash(id + role.rawValue) % UInt64(slots))
            let slot = (phase + epoch) % slots
            result = slot == 0 ? "" : alternates[slot - 1]
        }
        if pickMemo.count > 4000 { pickMemo.removeAll(keepingCapacity: true) }
        pickMemo[key] = result
        return result.isEmpty ? nil : result
    }

    /// Free to fetch right now, or already on disk. The disk probe runs only when the network is restricted and its
    /// answer is remembered until the network conditions change, so scrolling never repeats it.
    private func isAvailable(_ url: URL) -> Bool {
        if NetworkConditions.upgradesAllowed { return true }
        let net = NetworkConditions.current
        if let m = probeMemo[url], m.net == net { return m.cached }
        let cached = ImagePipeline.isCached(url)
        if probeMemo.count > 2000 { probeMemo.removeAll(keepingCapacity: true) }
        probeMemo[url] = (net, cached)
        return cached
    }

    /// FNV-1a. Swift's own `hashValue` is re-seeded every launch, which would reshuffle everything on each start.
    private static func stableHash(_ s: String) -> UInt64 {
        var h: UInt64 = 0xcbf29ce484222325
        for b in s.utf8 { h ^= UInt64(b); h = h &* 0x100000001b3 }
        return h
    }
}

/// Drop-in for `RemoteImage` on browse surfaces (posters, hero, feature cards) that rotates artwork.
struct RotatingArtwork: View {
    enum Kind { case poster, hero(wide: Bool), detail }

    let item: MetaPreview
    let kind: Kind
    /// Longest edge in points, same meaning as `RemoteImage.size`.
    let size: CGFloat
    @Environment(\.displayScale) private var scale

    private var choice: ArtworkRotation.Choice {
        switch kind {
        case .poster: return ArtworkRotation.shared.poster(for: item, longestEdgePixels: size * scale)
        case .hero(let wide): return ArtworkRotation.shared.hero(for: item, wide: wide)
        case .detail: return ArtworkRotation.shared.detailBackdrop(for: item)
        }
    }

    var body: some View {
        let c = choice
        RemoteImage(url: c.url, size: size, fallback: c.fallback)
    }
}
