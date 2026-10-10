import Foundation
import Network
import Observation
import os

/// Network state readable from any thread without hopping to the main actor (image loading, cache decisions).
/// Written by `Connectivity`'s path monitor, so there is still only one NWPathMonitor in the app.
enum NetworkConditions {
    struct Snapshot: Sendable, Equatable {
        var online = true
        var expensive = false       // cellular or personal hotspot
        var constrained = false     // Low Data Mode
    }

    private static let lock = OSAllocatedUnfairLock(initialState: Snapshot())
    static var current: Snapshot { lock.withLock { $0 } }
    fileprivate static func set(_ s: Snapshot) { lock.withLock { $0 = s } }

    /// Optional, bandwidth- or battery-hungry extras (rotated high-res artwork) are only worth it on an unrestricted
    /// connection with no power pressure.
    static var upgradesAllowed: Bool {
        let n = current, p = ProcessInfo.processInfo
        return n.online && !n.expensive && !n.constrained
            && !p.isLowPowerModeEnabled && p.thermalState.rawValue < ProcessInfo.ThermalState.serious.rawValue
    }
}

/// Always-on reachability for the offline start and the downloader.
/// `isOnline` is nil until the first path update arrives (a few ms after launch).
@MainActor @Observable
final class Connectivity {
    static let shared = Connectivity()
    private(set) var isOnline: Bool?
    @ObservationIgnored private let monitor = NWPathMonitor()
    @ObservationIgnored private let queue = DispatchQueue(label: "connectivity", qos: .utility)

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            NetworkConditions.set(.init(online: online, expensive: path.isExpensive, constrained: path.isConstrained))
            Task { @MainActor in self?.isOnline = online }
        }
        monitor.start(queue: queue)
    }

    /// Waits (max ~1.5 s) for the first path so a fresh launch doesn't read "offline" by mistake.
    func ready() async -> Bool {
        var waited = 0
        while isOnline == nil && waited < 15 {
            try? await Task.sleep(for: .milliseconds(100))
            waited += 1
        }
        return isOnline ?? true
    }
}
