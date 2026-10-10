import SwiftUI
import AVFoundation
import MediaPlayer

// MARK: - System volume

/// The device's output volume, the same one the hardware buttons change. Readable and settable from SwiftUI.
///
/// iOS has no public "set volume" call. The supported route is the slider inside an `MPVolumeView`, so
/// `SystemVolumeHost` keeps one alive (invisible) while the player's volume pill is open and hands its slider here.
/// Reading and observing goes through `AVAudioSession.outputVolume`, which also reports hardware-button presses.
@MainActor @Observable
final class SystemVolume {
    /// 0...1
    private(set) var level: Float = 0.5
    /// True while a finger is on the slider: hardware / KVO updates are ignored so they can't fight the drag.
    @ObservationIgnored var isAdjusting = false
    /// Last audible level, so tapping the speaker while muted brings the sound back to where it was.
    @ObservationIgnored private var restoreLevel: Float = 0.5
    @ObservationIgnored private weak var slider: UISlider?
    @ObservationIgnored private var observation: NSKeyValueObservation?

    init() { refresh() }

    func refresh() {
        let v = AVAudioSession.sharedInstance().outputVolume
        level = v
        if v > 0.001 { restoreLevel = v }
    }

    /// Follows the hardware buttons while the player is on screen.
    func startObserving() {
        refresh()
        guard observation == nil else { return }
        observation = Self.observeOutputVolume { [weak self] v in
            Task { @MainActor in self?.systemChanged(v) }
        }
    }

    /// Kept outside the main actor: KVO may call back from any thread.
    private nonisolated static func observeOutputVolume(_ handler: @escaping @Sendable (Float) -> Void) -> NSKeyValueObservation {
        AVAudioSession.sharedInstance().observe(\.outputVolume, options: [.new]) { _, change in
            if let v = change.newValue { handler(v) }
        }
    }

    func stopObserving() {
        observation?.invalidate()
        observation = nil
    }

    private func systemChanged(_ v: Float) {
        guard !isAdjusting else { return }
        level = v
        if v > 0.001 { restoreLevel = v }
    }

    func set(_ value: Float) {
        let v = min(max(value, 0), 1)
        level = v
        if v > 0.001 { restoreLevel = v }
        guard let slider else { return }
        slider.setValue(v, animated: false)
        slider.sendActions(for: .valueChanged)
    }

    func toggleMute() {
        set(level > 0.001 ? 0 : max(restoreLevel, 0.1))
    }

    fileprivate func attach(_ slider: UISlider?) { self.slider = slider }
}

// MARK: - Hidden MPVolumeView

/// Zero-size, effectively invisible `MPVolumeView` whose only job is to expose the system volume slider.
/// Mount it only while the volume pill is open: while an `MPVolumeView` is on screen iOS suppresses its own volume HUD
/// (the pill takes over), and the normal HUD comes back as soon as it is removed.
struct SystemVolumeHost: UIViewRepresentable {
    let volume: SystemVolume

    func makeUIView(context: Context) -> MPVolumeView {
        let v = HostVolumeView(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
        v.onSlider = { [weak volume] s in volume?.attach(s) }
        return v
    }

    func updateUIView(_ uiView: MPVolumeView, context: Context) {}

    static func dismantleUIView(_ uiView: MPVolumeView, coordinator: ()) {
        (uiView as? HostVolumeView)?.onSlider?(nil)
    }

    /// The slider subview only exists after the first layout pass, so it is picked up there.
    private final class HostVolumeView: MPVolumeView {
        var onSlider: (@MainActor (UISlider?) -> Void)?
        override func layoutSubviews() {
            super.layoutSubviews()
            onSlider?(subviews.compactMap { $0 as? UISlider }.first)
        }
    }
}

// MARK: - Pill content

/// What the controls pill turns into when the speaker icon is tapped: speaker (tap to mute) + slider.
/// No background of its own: it sits inside the pill's Liquid Glass. The slider follows the seek bar's look,
/// a white fill that grows thicker while it is being dragged.
struct VolumeSliderRow: View {
    let level: Float
    let onChange: (Float) -> Void
    let onToggleMute: () -> Void
    /// true when a drag starts, false when it ends. The player pauses its 3 s "back to normal" countdown in between.
    let onEditing: (Bool) -> Void

    @State private var dragLevel: Float?
    private var shown: Float { dragLevel ?? level }

    var body: some View {
        HStack(spacing: 4) {
            Button(action: onToggleMute) {
                Image(systemName: shown < 0.001 ? "speaker.slash.fill" : "speaker.wave.3.fill",
                      variableValue: Double(shown))
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(.white)
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 46, height: 46)
                    .contentShape(Circle())
            }
            .buttonStyle(PressableStyle())
            .accessibilityLabel(shown < 0.001 ? "Unmute" : "Mute")

            GeometryReader { geo in
                let w = max(geo.size.width, 1)
                let active = dragLevel != nil
                ZStack(alignment: .leading) {
                    Color.white.opacity(0.28)
                    Color.white.frame(width: w * CGFloat(shown))
                }
                .frame(height: active ? 16 : 10)
                .clipShape(Capsule())
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { g in
                            if dragLevel == nil { onEditing(true) }
                            let v = Float(min(max(g.location.x / w, 0), 1))
                            dragLevel = v
                            onChange(v)
                        }
                        .onEnded { g in
                            onChange(Float(min(max(g.location.x / w, 0), 1)))
                            dragLevel = nil
                            onEditing(false)
                        }
                )
                .animation(.snappy(duration: 0.18), value: active)
            }
            .frame(height: 40)
            .padding(.trailing, 16)
            .accessibilityElement()
            .accessibilityLabel("Volume")
            .accessibilityValue("\(Int((shown * 100).rounded())) percent")
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: onChange(min(level + 0.0625, 1))
                case .decrement: onChange(max(level - 0.0625, 0))
                @unknown default: break
                }
            }
        }
    }
}
