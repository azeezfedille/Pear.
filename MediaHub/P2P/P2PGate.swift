import Foundation

/// Single chokepoint for add-on streams (called from AddonClient.streams, which feeds Detail, Player and episode switching).
enum P2PGate {
    /// - Debrid / HTTPS streams: always pass through untouched.
    /// - Torrent streams, P2P off: kept so the UI can show them as unavailable (`StreamItem.p2pOff`). They are never
    ///   `isPlayable`, and nothing here starts a network monitor or the engine.
    /// - Torrent streams, P2P on: kept. `StreamItem.p2pLocked` reports live whether the network currently allows them.
    static func apply(_ streams: [StreamItem]) async -> [StreamItem] {
        guard streams.contains(where: \.isTorrent) else { return streams }
        guard P2PSettings.isEnabled else { return streams }
        await P2PNetwork.shared.ready()
        return streams
    }
}
