import Foundation

extension StreamItem {
    /// A raw BitTorrent stream: has a valid info hash and no direct URL. Anything with a `url` (debrid / HTTPS) is never a torrent here.
    var isTorrent: Bool {
        guard url == nil, let h = infoHash, h.count == 40 else { return false }
        return h.allSatisfy(\.isHexDigit)
    }

    /// Torrentio's `sources` entries look like "tracker:udp://host:port/announce" or "dht:<hash>". Only trackers are kept.
    var trackers: [String] {
        (sources ?? []).compactMap { $0.hasPrefix("tracker:") ? String($0.dropFirst("tracker:".count)) : nil }
    }

    /// A torrent stream while the P2P feature is switched off in Settings.
    var p2pOff: Bool { isTorrent && !P2PSettings.isEnabled }

    /// P2P is on, but the current network isn't allowed (cellular / hotspot / Low Data Mode with "Wi-Fi only").
    var p2pLocked: Bool { isTorrent && P2PSettings.isEnabled && !P2PNetwork.shared.allowed }
}

extension StreamItem {
    /// A torrent that can be started right now: P2P enabled and the network allows it.
    var canStreamP2P: Bool { isTorrent && P2PSettings.isEnabled && P2PNetwork.shared.allowed }

    /// What the player needs: a direct URL (debrid / HTTPS), or the placeholder + torrent source resolved at playback time.
    var playTarget: (url: URL, p2p: P2PSource?)? {
        if let u = url.flatMap(URL.init(string:)) { return (u, nil) }
        guard canStreamP2P, let h = infoHash else { return nil }
        return (P2PManager.placeholderURL, P2PSource(infoHash: h, trackers: trackers, fileIdx: fileIdx))
    }
}
