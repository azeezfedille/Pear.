import SwiftUI

/// The typed "pear." logo, drawn as vectors (no image assets). Use this inside the app; the mark is for the app icon only.
/// Ink follows the colour scheme (cream on dark, near-black on light); the full stop is always the brand violet.
struct PearWordmark: View {
    var height: CGFloat = 22
    var color: Color? = nil
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let box = PearGlyphs.wordmarkBox
        ZStack {
            FitShape(source: PearGlyphs.letters, box: box).fill(color ?? (scheme == .dark ? Brand.cream : Brand.ink))
            FitShape(source: PearGlyphs.dotPath, box: box).fill(Brand.accent)
        }
        .aspectRatio(box.width / box.height, contentMode: .fit)
        .frame(height: height)
        .accessibilityElement()
        .accessibilityLabel("Pear")
    }
}

/// Scales `source` so that `box` fills the shape's rect.
private struct FitShape: Shape {
    let source: Path
    let box: CGRect

    func path(in rect: CGRect) -> Path {
        let t = CGAffineTransform(scaleX: rect.width / box.width, y: rect.height / box.height)
            .translatedBy(x: -box.minX, y: -box.minY)
        return source.applying(t)
    }
}
