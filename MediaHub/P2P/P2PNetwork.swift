import Foundation
import Network
import os

/// Network gate for P2P. The path monitor only exists while P2P is enabled and in use; `stop()` cancels it,
/// so with the feature off there is no monitor, no queue wake-ups and no state.
final class P2PNetwork: @unchecked Sendable {
    static let shared = P2PNetwork()
    /// Posted on the main queue when `allowed` flips. userInfo["allowed"] is the new Bool.
    static let didChange = Notification.Name("P2PNetworkDidChange")

    private struct State {
        var monitor: NWPathMonitor?
        var path: NWPath?
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let queue = DispatchQueue(label: "p2p.network", qos: .utility)

    /// True when the current path may carry P2P traffic. False until the first path update arrives.
    var allowed: Bool { state.withLock { Self.evaluate($0.path) } }

    private static func evaluate(_ p: NWPath?) -> Bool {
        guard let p, p.status == .satisfied else { return false }
        guard P2PSettings.wifiOnly else { return true }
        // Wi-Fi only: also rejects personal hotspots (isExpensive) and Low Data Mode (isConstrained).
        return !p.isExpensive && !p.isConstrained
            && (p.usesInterfaceType(.wifi) || p.usesInterfaceType(.wiredEthernet))
    }

    func start() {
        state.withLock { s in
            guard s.monitor == nil else { return }
            let m = NWPathMonitor()
            m.pathUpdateHandler = { [weak self] path in self?.update(path) }
            m.start(queue: queue)
            s.monitor = m
        }
    }

    func stop() {
        state.withLock { s in
            s.monitor?.cancel()
            s.monitor = nil
            s.path = nil
        }
    }

    /// Starts the monitor if needed and waits (max ~1.5 s) for the first path, so a fresh launch doesn't read "offline".
    func ready() async {
        start()
        var waited = 0
        while state.withLock({ $0.path == nil }) && waited < 15 {
            try? await Task.sleep(for: .milliseconds(100))
            waited += 1
        }
    }

    private func update(_ path: NWPath) {
        let (old, new) = state.withLock { s -> (Bool, Bool) in
            let o = Self.evaluate(s.path)
            s.path = path
            return (o, Self.evaluate(path))
        }
        guard old != new else { return }
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: Self.didChange, object: nil, userInfo: ["allowed": new])
        }
    }
}
