import Foundation

/// One shared, cache-aware client. HTTP caching (ETag / Cache-Control) is honored by URLCache,
/// so repeat launches don't refetch catalogs the add-on says are still fresh.
actor AddonClient {
    static let shared = AddonClient()
    private let session: URLSession
    /// Stream lookups get their own session so a slow catalog fetch never queues behind them (and vice versa).
    /// It shares the URLCache object with `session`, so `clearCache()` still clears everything.
    private let streamSession: URLSession
    /// Hard ceiling per add-on. The URLSession timeout is an idle timeout; a trickling response could outlive it.
    private static let streamDeadline: Duration = .seconds(8)

    init() {
        let cache = URLCache(memoryCapacity: 20 << 20, diskCapacity: 150 << 20)
        let cfg = URLSessionConfiguration.default
        cfg.urlCache = cache
        cfg.requestCachePolicy = .useProtocolCachePolicy
        cfg.timeoutIntervalForRequest = 12
        cfg.httpMaximumConnectionsPerHost = 4
        session = URLSession(configuration: cfg)

        let sc = URLSessionConfiguration.default
        sc.urlCache = cache
        sc.requestCachePolicy = .useProtocolCachePolicy
        sc.timeoutIntervalForRequest = 8
        sc.httpMaximumConnectionsPerHost = 8
        streamSession = URLSession(configuration: sc)
    }

    /// Stream-lookup fetch with a real 8 s deadline (the fetch races a timer).
    private func streamData(_ url: URL) async throws -> Data {
        try await withThrowingTaskGroup(of: Data.self) { group in
            group.addTask {
                // Never from the HTTP cache: a cached empty / failed answer would hide an add-on until the cache expires.
                var req = URLRequest(url: url)
                req.cachePolicy = .reloadIgnoringLocalCacheData
                let (d, resp) = try await self.streamSession.data(for: req)
                guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
                return d
            }
            group.addTask {
                try await Task.sleep(for: Self.streamDeadline)
                throw URLError(.timedOut)
            }
            defer { group.cancelAll() }
            guard let d = try await group.next() else { throw URLError(.cannotLoadFromNetwork) }
            return d
        }
    }

    private func data(_ url: URL, fresh: Bool = false) async throws -> Data {
        var req = URLRequest(url: url)
        if fresh { req.cachePolicy = .reloadIgnoringLocalCacheData }
        let (d, resp) = try await session.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return d
    }

    /// Retries twice on a failed fetch (cold-starting hosts, a network that isn't up yet at launch), and refetches
    /// once ignoring the cache if a cached copy doesn't decode.
    func manifest(at url: URL, fresh: Bool = false) async throws -> AddonManifest {
        var lastError: Error = URLError(.unknown)
        for attempt in 0..<3 {
            if attempt > 0 { try await Task.sleep(for: .seconds(Double(attempt) * 1.5)) }
            do {
                let d = try await data(url, fresh: fresh || attempt > 0)
                return try JSONDecoder().decode(AddonManifest.self, from: d)
            } catch is CancellationError { throw CancellationError()
            } catch { lastError = error }
        }
        throw lastError
    }

    /// Drops every cached catalog / manifest response, so the next fetch goes to the network.
    func clearCache() { session.configuration.urlCache?.removeAllCachedResponses() }

    /// `skip` pages through add-ons that declare it; `search` queries add-ons that declare it.
    func catalog(addon: Addon, catalog: AddonManifest.CatalogDef, skip: Int = 0, search: String? = nil) async throws -> [MetaPreview] {
        // A Jellyfin / Plex server is answered by its backend, not over the add-on protocol.
        if let server = MediaServerRegistry.shared.backend(for: addon) {
            return try await server.catalog(type: catalog.type, id: catalog.id, skip: skip, search: search)
        }
        var extras: [String] = []
        if let q = search?.trimmingCharacters(in: .whitespacesAndNewlines), !q.isEmpty {
            let safe = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
            extras.append("search=" + (q.addingPercentEncoding(withAllowedCharacters: safe) ?? q))
        }
        if skip > 0 { extras.append("skip=\(skip)") }
        var path = "catalog/\(catalog.type)/\(catalog.id)"
        if !extras.isEmpty { path += "/" + extras.joined(separator: "&") }
        // Built as a string: appendingPathComponent would double-encode the % escapes.
        guard let url = URL(string: addon.baseURL.absoluteString + path + ".json") else { throw URLError(.badURL) }
        return try MetaPreview.decodeList(try await data(url))
    }

    // MARK: Metadata extras (theme rows)

    /// The two things Home's theme rows take from an add-on's `meta` response.
    struct MetaExtras: Sendable {
        let genres: [String]
        let logo: URL?
        static let empty = MetaExtras(genres: [], logo: nil)
    }

    private struct MetaEnvelope: Decodable {
        struct Meta: Decodable {
            let genres: [String]
            let logo: String?
            private enum K: String, CodingKey { case genres, logo }
            // Tolerant like the rest of the add-on models: one odd field must not lose the other.
            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: K.self)
                genres = (try? c.decodeIfPresent([String].self, forKey: .genres)) ?? []
                logo = try? c.decodeIfPresent(String.self, forKey: .logo)
            }
        }
        let meta: Meta
    }

    /// Answers kept for this launch: a title is asked about once however often Home reloads. Failures and timeouts
    /// are not kept, so a flaky moment doesn't blank a title until the next launch.
    private var metaCache: [String: MetaExtras] = [:]

    /// Genres and logo for one title from `addon`'s `meta` resource (`.empty` when it has none, doesn't serve this id,
    /// or doesn't answer within the stream deadline).
    func metaExtras(addon: Addon, type: String, id: String) async -> MetaExtras {
        let key = addon.id + "|" + type + "|" + id
        if let hit = metaCache[key] { return hit }
        guard addon.provides("meta", type: type, id: id) else { metaCache[key] = .empty; return .empty }
        guard let url = URL(string: addon.baseURL.absoluteString + "meta/\(type)/\(id).json"),
              let data = try? await streamData(url), !Task.isCancelled else { return .empty }
        guard let decoded = try? JSONDecoder().decode(MetaEnvelope.self, from: data) else {
            metaCache[key] = .empty
            return .empty
        }
        let out = MetaExtras(genres: decoded.meta.genres, logo: decoded.meta.logo.flatMap { URL(string: $0) })
        metaCache[key] = out
        return out
    }

    /// Fans out only to add-ons that declare the `stream` resource for this type/id, and yields each add-on's
    /// result the moment it answers (completion order; use `ordered(_:by:)` to restore the user's add-on order).
    /// Add-ons that fail or time out are simply skipped. Cancelling the consumer cancels the lookups.
    nonisolated func streamUpdates(for id: String, type: String, addons: [Addon]) -> AsyncStream<(Addon, [StreamItem])> {
        AsyncStream { cont in
            let task = Task {
                // Warm the path monitor now so P2PGate.ready() rarely has to wait for the first path update.
                if P2PSettings.isEnabled { P2PNetwork.shared.start() }
                await withTaskGroup(of: (Addon, [StreamItem])?.self) { group in
                    for addon in addons where addon.provides("stream", type: type, id: id) {
                        group.addTask {
                            if let server = MediaServerRegistry.shared.backend(for: addon) {
                                let found = await server.streams(type: type, id: id)
                                return found.isEmpty ? nil : (addon, found)
                            }
                            let url = addon.baseURL.appendingPathComponent("stream/\(type)/\(id).json")
                            guard let d = try? await self.streamData(url),
                                  let s = try? StreamItem.decodeList(d) else { return nil }
                            return (addon, await P2PGate.apply(s))
                        }
                    }
                    for await r in group { if let r { cont.yield(r) } }
                }
                cont.finish()
            }
            cont.onTermination = { _ in task.cancel() }
        }
    }

    /// Same fan-out, waits for everyone. Signature unchanged for Downloads and episode switching.
    func streams(for id: String, type: String, addons: [Addon]) async -> [(Addon, [StreamItem])] {
        var out: [(Addon, [StreamItem])] = []
        for await r in streamUpdates(for: id, type: type, addons: addons) { out.append(r) }
        return out
    }

    /// Sorts results into the user's add-on order.
    nonisolated static func ordered(_ groups: [(Addon, [StreamItem])], by addons: [Addon]) -> [(Addon, [StreamItem])] {
        addons.compactMap { a in groups.first(where: { $0.0.id == a.id }) }
    }
}
