import SwiftUI

/// The "pear." face animation: the P becomes a face, winks, and settles into the wordmark.
/// `.intro` plays once on launch, `.loader` loops while a stream opens. Runs at 2x by default.
/// Time comes from the wall clock, so a busy main thread skips frames instead of slowing the animation.
struct PearAnimationView: View {
    var mode: PearMode = .loader
    var speed: Double = 2
    /// Called once when a one-shot mode (`.intro`) has finished.
    var onFinish: (() -> Void)? = nil

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var start = Date()

    var body: some View {
        Group {
            if reduceMotion {
                Canvas { ctx, size in Self.draw(PearGeometry.shared.restFrame(mode: mode), &ctx, size) }
            } else {
                let t0 = start, mode = mode, speed = speed
                // The one-shot intro is a brand moment and keeps 60 fps. The loader can run for a long time while a
                // stream opens (torrents especially), and a morphing outline reads the same at 30, so it costs half
                // the path building. Low Power Mode / a hot phone drops the intro to 30 as well.
                let fps: Double = (mode == .intro && !PowerMode.shared.saving) ? 60 : 30
                TimelineView(.animation(minimumInterval: 1.0 / fps)) { tl in
                    Canvas(rendersAsynchronously: true) { ctx, size in
                        let ms = tl.date.timeIntervalSince(t0) * 1000 * speed
                        Self.draw(PearGeometry.shared.frame(at: ms, mode: mode), &ctx, size)
                    }
                }
            }
        }
        .aspectRatio(PearGeometry.canvas.width / PearGeometry.canvas.height, contentMode: .fit)
        .accessibilityElement()
        .accessibilityLabel(mode == .loader ? "Loading" : "Pear")
        .task {
            guard let total = PearGeometry.duration(of: mode), let onFinish else { return }
            // Reduced motion shows the final frame straight away, so only a short hold is needed.
            try? await Task.sleep(for: .seconds(reduceMotion ? 0.6 : total / 1000 / speed))
            guard !Task.isCancelled else { return }
            onFinish()
        }
    }

    private static func draw(_ f: PearGeometry.Frame, _ ctx: inout GraphicsContext, _ size: CGSize) {
        let c = PearGeometry.canvas
        let s = min(size.width / c.width, size.height / c.height)
        ctx.translateBy(x: (size.width - c.width * s) / 2, y: (size.height - c.height * s) / 2)
        ctx.scaleBy(x: s, y: s)
        if f.tile > 0.001 { ctx.fill(PearGeometry.shared.tile, with: .color(Brand.tile.opacity(f.tile))) }
        ctx.fill(f.cream, with: .color(Brand.cream))
        ctx.fill(f.accent, with: .color(Brand.accent))
    }
}

// MARK: - App launch

/// Black screen with the intro on top of the app. The app loads underneath while it plays, then it fades out.
private struct PearLaunchScreen: ViewModifier {
    @State private var showing = true

    func body(content: Content) -> some View {
        content.overlay {
            if showing {
                ZStack {
                    Brand.splash.ignoresSafeArea()
                    PearAnimationView(mode: .intro, onFinish: dismiss)
                        .frame(maxWidth: 520)
                        .padding(.horizontal, 28)
                }
                .transition(.opacity)
            }
        }
    }

    private func dismiss() {
        Task {
            try? await Task.sleep(for: .milliseconds(350))      // a beat on "pear."
            withAnimation(.easeOut(duration: 0.35)) { showing = false }
        }
    }
}

extension View {
    /// Plays the "pear." intro over this view when the app launches.
    func pearLaunchScreen() -> some View { modifier(PearLaunchScreen()) }
}
