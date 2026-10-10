import SwiftUI

/// Soft "selected" outline: a fine bright hairline with a faint glow fading inward from it.
///
/// Built only from a few flat vector strokes, so there is no blur, no shadow and no offscreen render pass (the usual
/// battery cost of glow effects), nothing repeats or pulses, and it is only drawn on the one selected view. The glow
/// sits inside the shape, so scroll views can't clip it. Under Low Power Mode or heat only the hairline remains.
struct SelectionRing: ViewModifier {
    @Environment(ThemeStore.self) private var theme
    let on: Bool
    let radius: CGFloat
    let width: CGFloat
    /// 1 = full strength. Lower values scale every layer's opacity down for a fainter outline.
    let intensity: Double

    func body(content: Content) -> some View {
        content.overlay {
            Group {
                if on {
                    let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
                    let a = theme.accent
                    let k = intensity
                    ZStack {
                        if !PowerMode.shared.saving {
                            shape.strokeBorder(a.opacity(0.06 * k), lineWidth: width * 6)
                            shape.strokeBorder(a.opacity(0.09 * k), lineWidth: width * 3.6)
                            shape.strokeBorder(a.opacity(0.16 * k), lineWidth: width * 2)
                        }
                        shape.strokeBorder(LinearGradient(colors: [a.opacity(0.95 * k), a.opacity(0.5 * k)],
                                                          startPoint: .topLeading, endPoint: .bottomTrailing),
                                           lineWidth: width)
                    }
                    .allowsHitTesting(false)
                    .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.18), value: on)
        }
    }
}

extension View {
    /// Elegant accent-coloured selection outline. See `SelectionRing`.
    func selectionRing(_ on: Bool, radius: CGFloat, width: CGFloat = 1.25, intensity: Double = 1) -> some View {
        modifier(SelectionRing(on: on, radius: radius, width: width, intensity: intensity))
    }
}
