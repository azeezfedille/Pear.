import SwiftUI

/// Background fade from clear to the page colour. Smoothstep-eased rather than linear, so there is no visible
/// "edge" where the gradient starts and the artwork melts into the page instead of ending at a line.
private let heroFadeStops: [Gradient.Stop] = (0...10).map { i in
    let t = Double(i) / 10
    return .init(color: Color(.systemBackground).opacity(t * t * (3 - 2 * t)), location: t)
}

/// Apple TV-style collapsing hero for the details page.
///
/// - The artwork sits in a fixed window and slides through it at `parallax` x the scroll speed, so it travels more
///   slowly than the content (depth, not just a scroll).
/// - Pulling down past the top stretches the artwork to fill the gap instead of exposing the page behind it.
/// - As the hero collapses, the artwork dims toward the page colour.
/// - `info` (title, metadata) is anchored to the bottom of the window, over the fade. It scrolls with the content
///   at full speed, so the artwork visibly drifts behind it, and it fades out before it reaches the navigation bar.
///
/// Scroll position is read from this view's own geometry, so only the hero redraws while scrolling, not the page.
/// Must be placed at the top of a `ScrollView` that lets content run under the status bar.
struct ParallaxHero<Art: View, Info: View>: View {
    let height: CGFloat
    /// Artwork speed relative to the scroll: 0 = moves with the content, 1 = stays put.
    var parallax: CGFloat = 0.5
    /// Height of the fade into the page at the bottom of the hero.
    var fadeHeight: CGFloat = 360
    @ViewBuilder let art: () -> Art
    @ViewBuilder let info: () -> Info

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geo in
            // Top edge of the hero in scroll-view space: 0 at rest, negative while scrolling up, positive while
            // pulling down past the top.
            let minY = geo.frame(in: .scrollView).minY
            let pulled = reduceMotion ? 0 : max(minY, 0)
            let scrolled = max(-minY, 0)
            // 0 → 1 as the hero scrolls away.
            let progress = min(scrolled / (height * 0.8), 1)
            // The title block fades out before it reaches the navigation bar.
            let infoOpacity = 1 - min(max((scrolled - height * 0.3) / (height * 0.25), 0), 1)
            let window = height + pulled

            ZStack(alignment: .bottom) {
                art()
                    .frame(width: geo.size.width, height: window)
                    .offset(y: reduceMotion ? 0 : scrolled * parallax)
                    .opacity(1 - 0.6 * progress)
                LinearGradient(stops: heroFadeStops, startPoint: .top, endPoint: .bottom)
                    .frame(height: min(fadeHeight, height))
                    .allowsHitTesting(false)
                info()
                    .padding(.bottom, 10)
                    .opacity(infoOpacity)
            }
            .frame(width: geo.size.width, height: window, alignment: .bottom)
            .clipped()
            // Grow upward when pulled down, so the stretch starts at the top of the screen.
            .offset(y: -pulled)
        }
        .frame(height: height)
    }
}
