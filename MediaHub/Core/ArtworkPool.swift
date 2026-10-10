import Foundation
import os

enum ArtworkRole: String, Codable, Sendable { case poster, backdrop }

/// One alternate image for a title. Only the TMDB *file path* ("/abc123.jpg") is stored. The size variant is chosen
/// when the image is actually shown, so one entry serves a 185 px thumbnail and a 1280 px hero alike.
struct ArtworkCandidate: Codable, Hashable, Sendable {
    let path: String
    let width: Int
    let score: Double
}

/// Builds TMDB CDN URLs for a file path at the smallest size that still covers the view's pixel width.
enum TMDBImage {
    private static let base = "https://image.tmdb.org/t/p/"
    private static let posterSizes: [(name: String, width: CGFloat)] = [("w185", 185), ("w342", 342), ("w500", 500), ("w780", 780)]
    private static let backdropSizes: [(name: String, width: CGFloat)] = [("w300", 300), ("w780", 780), ("w1280", 1280), ("original", 4096)]

    static func url(path: String, role: ArtworkRole, pixelWidth: CGFloat) -> URL? {
        let sizes = role == .poster ? posterSizes : backdropSizes
        let size = sizes.first { $0.width >= pixelWidth } ?? sizes[sizes.count - 1]
        return URL(string: base + size.name + path)
    }
}

/// Local store of alternate artwork per title. It is filled from responses the app already downloads (TMDB's
/// `/images` call that `TMDBClient.logo(for:)` makes anyway), so rotating artwork never costs an extra request.
///
/// - Bounded: at most `maxTitles` titles (least recently used go first) and `perRole` candidates per title.
/// - Curated on the way in: right aspect ratio, high resolution, English / language-less only, best-voted first.
/// - Persisted as one small JSON file in Caches (derived data, so the system may purge it; it simply refills).
/// - Thread-safe and synchronous, so views can read it from `body` with no hop and no I/O after the first read.
final class ArtworkPool: @unchecked Sendable {
    static let shared = ArtworkPool()

    /// What TMDB returns per image, reduced to the fields curation needs.
    struct Raw: Sendable {
        let path: String
        let language: String?
        let width: Int
        let height: Int
        let votes: Double
    }

    private struct Entry: Codable, Sendable {
        var posters: [ArtworkCandidate]
        var backdrops: [ArtworkCandidate]
        var touched: Date
    }

    private struct State: Sendable {
        var entries: [String: Entry] = [:]
        var loaded = false
        var dirty = false
        var saveScheduled = false
    }

    private static let maxTitles = 400
    private static let perRole = 8
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let fileURL: URL = {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return dir.appendingPathComponent("ArtworkPool.json")
    }()

    // MARK: Read

    /// Alternates for a title, best first. Empty when nothing is known (the caller then keeps the default artwork).
    func candidates(for id: String, role: ArtworkRole) -> [ArtworkCandidate] {
        let url = fileURL
        let (result, touchedNow): ([ArtworkCandidate], Bool) = state.withLock { s in
            if !s.loaded { s.entries = Self.read(url); s.loaded = true }
            guard var e = s.entries[id] else { return ([], false) }
            // LRU bookkeeping at most twice a day per title, so reads don't turn into disk writes.
            var touched = false
            if Date.now.timeIntervalSince(e.touched) > 12 * 3600 {
                e.touched = .now; s.entries[id] = e; s.dirty = true; touched = true
            }
            return (role == .poster ? e.posters : e.backdrops, touched)
        }
        if touchedNow { scheduleSave() }
        return result
    }

    // MARK: Write

    func ingest(id: String, posters: [Raw], backdrops: [Raw]) {
        let p = Self.curate(posters, role: .poster)
        let b = Self.curate(backdrops, role: .backdrop)
        guard !p.isEmpty || !b.isEmpty else { return }
        let url = fileURL
        state.withLock { s in
            if !s.loaded { s.entries = Self.read(url); s.loaded = true }
            s.entries[id] = Entry(posters: p, backdrops: b, touched: .now)
            if s.entries.count > Self.maxTitles {                      // drop the least recently used quarter
                let drop = s.entries.count - Self.maxTitles * 3 / 4
                for key in s.entries.sorted(by: { $0.value.touched < $1.value.touched }).prefix(drop).map({ $0.key }) {
                    s.entries[key] = nil
                }
            }
            s.dirty = true
        }
        scheduleSave()
    }

    /// Writes pending changes now (call when the app leaves the foreground).
    func flush() { save() }

    // MARK: Curation

    private static func curate(_ raw: [Raw], role: ArtworkRole) -> [ArtworkCandidate] {
        let minWidth = role == .poster ? 500 : 1280
        let ratio: ClosedRange<Double> = role == .poster ? 0.60...0.72 : 1.70...1.85
        let sized = raw.filter { r in
            r.width >= minWidth && r.height > 0 && ratio.contains(Double(r.width) / Double(r.height))
        }
        let readable = sized.filter { $0.language == nil || $0.language == "en" }
        var pool = readable
        if role == .backdrop {
            // Textless backdrops first: the title logo is drawn on top of them, so baked-in titles would clash.
            let textless = sized.filter { $0.language == nil }
            if textless.count >= 2 { pool = textless }
        }
        return pool
            .sorted { ($0.votes, $0.width) > ($1.votes, $1.width) }
            .prefix(perRole)
            .map { ArtworkCandidate(path: $0.path, width: $0.width, score: $0.votes) }
    }

    // MARK: Persistence

    private static func read(_ url: URL) -> [String: Entry] {
        guard let data = try? Data(contentsOf: url) else { return [:] }
        return (try? JSONDecoder().decode([String: Entry].self, from: data)) ?? [:]
    }

    /// Coalesces bursts of changes into one write a few seconds later, off the main thread.
    private func scheduleSave() {
        let first = state.withLock { s -> Bool in
            if s.saveScheduled { return false }
            s.saveScheduled = true
            return true
        }
        guard first else { return }
        Task.detached(priority: .utility) { [self] in
            try? await Task.sleep(for: .seconds(3))
            save()
        }
    }

    private func save() {
        let (snapshot, needed): ([String: Entry], Bool) = state.withLock { s in
            s.saveScheduled = false
            let needed = s.dirty
            s.dirty = false
            return (s.entries, needed)
        }
        guard needed, let data = try? JSONEncoder().encode(snapshot) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
