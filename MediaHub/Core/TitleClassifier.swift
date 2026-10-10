import Foundation

/// Applies the user's `ContentRules` to lists of titles.
///
/// Most titles are decided from what they already carry: TMDB lists include genres and original language, and
/// add-on catalogues usually include genre names. Only titles that can't be decided that way (an add-on that lists no
/// genres, or "Animation" with no origin, which could be anime or a cartoon) cost a TMDB lookup. Lookups run a few at
/// a time and are kept on disk, because genres and origin never change: each title is asked about once, ever.
actor TitleClassifier {
    static let shared = TitleClassifier()

    private var cache: [String: TitleTraits] = [:]
    private var loaded = false
    /// Lookups that failed this session. They aren't retried until the next launch, so a title TMDB doesn't know
    /// can't cause a request on every refresh.
    private var misses: Set<String> = []
    private var persistPending = false

    private static let cacheLimit = 4000
    private static let batchSize = 6
    private static let fileURL: URL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("title-traits.json")

    /// The titles the rules allow, in their original order. Returns the list untouched when nothing is hidden.
    func filter(_ items: [MetaPreview], rules: ContentRules) async -> [MetaPreview] {
        guard rules.hasFilters, !items.isEmpty else { return items }
        loadIfNeeded()

        var hide = [Bool](repeating: false, count: items.count)
        var pending: [Int] = []
        for (i, item) in items.enumerated() {
            switch rules.outcome(for: item, resolved: cache[Self.key(item)]) {
            case .hide: hide[i] = true
            case .keep: break
            case .undecided: pending.append(i)
            }
        }

        if !pending.isEmpty {
            let found = await lookUp(pending.map { items[$0] })
            for i in pending {
                let item = items[i]
                let outcome = found[Self.key(item)].map { rules.outcome(for: item, resolved: $0) } ?? .undecided
                switch outcome {
                case .hide: hide[i] = true
                case .keep: break
                case .undecided: hide[i] = rules.fallbackHides(item)
                }
            }
        }
        var kept: [MetaPreview] = []
        for (i, item) in items.enumerated() where !hide[i] { kept.append(item) }
        return kept
    }

    // MARK: Lookups

    /// Same title, same key: TMDB numbers movies and shows separately, so the kind is part of it.
    private static func key(_ item: MetaPreview) -> String {
        "\(item.id)|\(item.type == "series" ? "tv" : "movie")"
    }

    private func lookUp(_ items: [MetaPreview]) async -> [String: TitleTraits] {
        guard TMDBClient.shared.hasKey else { return [:] }
        var todo: [MetaPreview] = []
        var seen = Set<String>()
        for item in items {
            let k = Self.key(item)
            // Only ids TMDB can resolve (IMDb or TMDB); add-on specific ids (kitsu:, yt:...) have nothing to ask about.
            guard item.id.hasPrefix("tt") || item.id.hasPrefix("tmdb:"),
                  !misses.contains(k), seen.insert(k).inserted else { continue }
            todo.append(item)
        }

        var out: [String: TitleTraits] = [:]
        var start = 0
        while start < todo.count {
            let batch = Array(todo[start..<min(start + Self.batchSize, todo.count)])
            start += Self.batchSize
            let results = await withTaskGroup(of: (String, TitleTraits?).self) { group -> [(String, TitleTraits?)] in
                for item in batch {
                    let k = Self.key(item)
                    group.addTask { (k, await TMDBClient.shared.traits(for: item.id, type: item.type)) }
                }
                var r: [(String, TitleTraits?)] = []
                for await x in group { r.append(x) }
                return r
            }
            if Task.isCancelled { break }
            for (k, t) in results {
                if let t { cache[k] = t; out[k] = t } else { misses.insert(k) }
            }
        }
        if !out.isEmpty { schedulePersist() }
        return out
    }

    // MARK: Disk cache

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        if let d = try? Data(contentsOf: Self.fileURL),
           let c = try? JSONDecoder().decode([String: TitleTraits].self, from: d) { cache = c }
    }

    /// Writes at most once every few seconds, however many titles resolve in between.
    private func schedulePersist() {
        guard !persistPending else { return }
        persistPending = true
        Task {
            try? await Task.sleep(for: .seconds(5))
            flush()
        }
    }

    private func flush() {
        persistPending = false
        if cache.count > Self.cacheLimit {
            cache = Dictionary(uniqueKeysWithValues: Array(cache.prefix(Self.cacheLimit / 2)))
        }
        if let d = try? JSONEncoder().encode(cache) { try? d.write(to: Self.fileURL, options: .atomic) }
    }
}
