import Foundation
import Observation

/// Battery-aware switch shared by the whole app.
///
/// While Low Power Mode is on, or the phone is running hot, purely decorative motion (the hero zoom, shimmer sweeps)
/// gives way to static versions. Nothing functional changes. Views read `PowerMode.shared.saving` in their body,
/// so they update by themselves the moment the system state flips.
///
/// The player's Liquid Glass is the exception: it only goes flat under Low Power Mode (`lowPower`), never for heat.
@MainActor @Observable
final class PowerMode {
    static let shared = PowerMode()

    private(set) var saving: Bool
    /// Low Power Mode alone, ignoring heat. The player's Liquid Glass follows this instead of `saving`, so a warm
    /// phone never strips the glass off the player controls.
    private(set) var lowPower: Bool

    private init() {
        saving = Self.current()
        lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        let center = NotificationCenter.default
        center.addObserver(forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        center.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    private static func current() -> Bool {
        let p = ProcessInfo.processInfo
        return p.isLowPowerModeEnabled || p.thermalState == .serious || p.thermalState == .critical
    }

    private func refresh() {
        let now = Self.current()
        if now != saving { saving = now }
        let low = ProcessInfo.processInfo.isLowPowerModeEnabled
        if low != lowPower { lowPower = low }
    }
}
