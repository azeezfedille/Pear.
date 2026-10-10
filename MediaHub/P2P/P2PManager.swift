import AVFoundation
import Foundation
import SwiftUI
import UIKit

/// What the player needs to ask the engine for one torrent file.
struct P2PSource: Sendable, Hashable {
    let infoHash: String
    let trackers: [String]
    let fileIdx: Int?
}

/// Owns the Rust engine's whole lifecycle. The engine exists only between `open` and `stop`:
/// `stop()` sets `engine = nil`, which closes every socket, joins the Tokio threads and deletes the cached pieces.
@MainActor
final class P2PManager {
    static let shared = P2PManager()
    /// Stand-in `PlayRequest.url` for torrent sources; the real loopback URL only exists after `open`.
    nonisolated static let placeholderURL = URL(string: "p2p://pending")!
    /// Posted (main queue) whenever a running engine is torn down. userInfo["reason"] is a StopReason raw value.
    static let didStop = Notification.Name("P2PManagerDidStop")
    /// A paused stream keeps the engine this long (instant resume, buffered pieces kept); after that everything is torn down.
    /// A paused engine is nearly free: the pacer throttles the swarm to a trickle once the read-ahead window is full,
    /// so a long hold costs little, while a teardown throws away the buffer and forces a cold start. Shorter under
    /// Low Power Mode / thermal pressure.
    nonisolated static var idleTimeout: Duration { powerSaving ? .seconds(5 * 60) : .seconds(15 * 60) }
    /// After an audio interruption (call, Siri, alarm) begins: much shorter, since it may last minutes.
    static let interruptionGrace: Duration = .seconds(15)

    enum StopReason: String {
        case user, idle, background, memory, network, interruption
        /// Everything except an explicit stop (leaving the player, switching source, turning P2P off).
        var isAutomatic: Bool { self != .user }
    }

    enum Failure: LocalizedError {
        case disabled, networkBlocked, noPeers, noVideo, engine(String)
        var errorDescription: String? {
            switch self {
            case .disabled: return "Peer-to-peer streaming is turned off in Settings."
            case .networkBlocked: return "Peer-to-peer streaming is limited to Wi-Fi. Connect to Wi-Fi or change the setting."
            case .noPeers: return "Couldn't find peers for this torrent. Try another source."
            case .noVideo: return "This torrent has no playable video file."
            case .engine(let m): return "Peer-to-peer engine error: \(m)"
            }
        }
    }

    private var engine: P2pEngine?
    /// Bumped by every `open` and `stop`; an `open` that finds it changed was cancelled while it waited on the engine.
    private var generation = 0
    /// Serial: engine construction and metadata fetch block their thread, so they never run on the main thread or the cooperative pool.
    private let worker = DispatchQueue(label: "p2p.worker", qos: .userInitiated)
    private var idleTask: Task<Void, Never>?
    private var isPlaying = false
    private var interrupted = false
    private var observers: [NSObjectProtocol] = []

    private init() {
        let nc = NotificationCenter.default
        func watch(_ name: Notification.Name, _ body: @escaping @MainActor (P2PManager, Notification) -> Void) {
            observers.append(nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] n in
                MainActor.assumeIsolated { if let self { body(self, n) } }
            })
        }
        // Leaving an allowed network (Wi-Fi only) ends the stream immediately: no cellular P2P traffic.
        watch(P2PNetwork.didChange) { m, n in if (n.userInfo?["allowed"] as? Bool) == false { m.stop(.network) } }
        // Jetsam guard: under memory pressure the engine goes first; playback can reopen at the same position.
        watch(UIApplication.didReceiveMemoryWarningNotification) { m, _ in m.stop(.memory) }
        watch(AVAudioSession.interruptionNotification) { m, n in
            let raw = n.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            m.interruption(raw.flatMap(AVAudioSession.InterruptionType.init(rawValue:)))
        }
        watch(.NSProcessInfoPowerStateDidChange) { m, _ in m.applyPowerSaving() }
        watch(ProcessInfo.thermalStateDidChangeNotification) { m, _ in m.applyPowerSaving() }
    }

    nonisolated static var powerSaving: Bool {
        let p = ProcessInfo.processInfo
        return p.isLowPowerModeEnabled || p.thermalState == .serious || p.thermalState == .critical
    }

    private func applyPowerSaving() { engine?.setPowerSaving(on: Self.powerSaving) }

    // MARK: Lifecycle hooks (called by RootView and PlayerModel)

    /// Scene went to the background. A stream that is playing keeps going (background audio / PiP); anything else is torn down.
    func scenePhaseChanged(_ phase: ScenePhase) {
        guard phase == .background, engine != nil, !isPlaying else { return }
        stop(.background)
    }

    /// Mirrors the player: playing / buffering / seeking = true; paused / ended / failed = false.
    /// While not playing, an idle countdown runs and ends in a full teardown.
    func playbackChanged(_ playing: Bool) {
        isPlaying = playing
        idleTask?.cancel(); idleTask = nil
        guard engine != nil, !playing else { return }
        if UIApplication.shared.applicationState == .background { stop(.background); return }
        let wait = interrupted ? Self.interruptionGrace : Self.idleTimeout
        idleTask = Task { [weak self] in
            try? await Task.sleep(for: wait)
            guard !Task.isCancelled, let self else { return }
            self.stop(self.interrupted ? .interruption : .idle)
        }
    }

    private func interruption(_ type: AVAudioSession.InterruptionType?) {
        switch type {
        case .began: interrupted = true; playbackChanged(false)
        case .ended: interrupted = false; playbackChanged(isPlaying)
        default: break
        }
    }

    var isActive: Bool { engine != nil }

    /// Starts the engine if needed (lazily), resolves the torrent and returns the loopback URL for AetherEngine.
    /// Seeks need no handling here: AetherEngine/FFmpeg send HTTP Range requests and the Rust proxy answers 206.
    func open(_ src: P2PSource) async throws -> URL {
        guard P2PSettings.isEnabled else { throw Failure.disabled }
        idleTask?.cancel(); idleTask = nil
        await P2PNetwork.shared.ready()
        guard P2PNetwork.shared.allowed else { throw Failure.networkBlocked }

        generation += 1
        let gen = generation
        do {
            let eng: P2pEngine
            if let e = engine {
                eng = e
            } else {
                let made = try await onWorker { try P2pEngine(config: Self.makeConfig()) }
                // stop() (or a newer open) ran while the engine was being built: discard it.
                guard gen == generation else { DispatchQueue.global(qos: .utility).async { made.stop() }; throw CancellationError() }
                made.setPowerSaving(on: Self.powerSaving)
                engine = made
                eng = made
            }
            let info = try await onWorker {
                try eng.startStream(infoHash: src.infoHash, trackers: src.trackers, fileIdx: src.fileIdx.map { UInt32($0) })
            }
            guard gen == generation, engine === eng else { throw CancellationError() }
            guard let url = URL(string: info.url) else { throw Failure.engine("bad stream URL") }
            return url
        } catch {
            if gen != generation { throw CancellationError() }
            throw Self.map(error)
        }
    }

    /// Killswitch. Safe to call any time on the main actor; returns immediately.
    /// Teardown (graceful session stop, thread join, file delete) runs off the main thread, inside a short background
    /// task so it also finishes when the app is moving to the background.
    func stop(_ reason: StopReason = .user) {
        generation += 1
        idleTask?.cancel(); idleTask = nil
        guard let e = engine else { return }
        engine = nil
        NotificationCenter.default.post(name: Self.didStop, object: nil, userInfo: ["reason": reason.rawValue])
        let box = BackgroundTaskBox()
        box.id = UIApplication.shared.beginBackgroundTask(withName: "p2p.teardown") { MainActor.assumeIsolated { box.end() } }
        DispatchQueue.global(qos: .utility).async {
            e.stop()
            DispatchQueue.main.async { MainActor.assumeIsolated { box.end() } }
        }
    }

    func stats() -> EngineStats? { engine?.stats() }

    // MARK: Helpers

    private func onWorker<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { c in
            worker.async { c.resume(with: Result { try body() }) }
        }
    }

    private nonisolated static func makeConfig() -> EngineConfig {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("P2P", isDirectory: true).path
        return defaultEngineConfig(cacheDir: dir)
    }

    private static func map(_ e: Error) -> Error {
        let desc = String(describing: e)
        if desc.localizedCaseInsensitiveContains("metadata") || desc.localizedCaseInsensitiveContains("timeout") {
            return Failure.noPeers
        }
        if desc.localizedCaseInsensitiveContains("nofile") || desc.localizedCaseInsensitiveContains("no file") {
            return Failure.noVideo
        }
        if desc.localizedCaseInsensitiveContains("stopped") {
            return CancellationError()
        }
        return Failure.engine(e.localizedDescription.isEmpty ? desc : e.localizedDescription)
    
    }
}

@MainActor
private final class BackgroundTaskBox: @unchecked Sendable {
    var id: UIBackgroundTaskIdentifier = .invalid
    func end() {
        guard id != .invalid else { return }
        UIApplication.shared.endBackgroundTask(id)
        id = .invalid
    }
}
