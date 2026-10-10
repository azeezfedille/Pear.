import SwiftUI

/// Episode stills and continue-watching thumbnails.
///
/// TMDB only offers episode stills as w92 / w185 / w300 / original. The app asked for w300, so on a 3x screen a card
/// needing about 1000 px had 300 px of picture stretched over it, which is why they looked pixelated. This loads the
/// original instead (usually 1920 px) and downsamples it to the card's exact pixel size.
///
/// Same rules as rotated artwork: the big file is only fetched on an unrestricted connection (Wi-Fi, no Low Data
/// Mode, no Low Power Mode, not hot) or when it is already cached; otherwise the w300 still is shown, exactly as
/// before. Anything that isn't a TMDB still (TVDB images, movie backdrops, add-on art) loads unchanged.
struct StillImage: View {
    let url: URL?
    /// Longest edge of the picture as drawn, in points (same meaning as `RemoteImage.size`).
    let size: CGFloat

    var body: some View {
        let big = url.flatMap(Self.original)
        RemoteImage(url: big ?? url, size: size, fallback: big == nil ? nil : url)
    }

    static func original(_ url: URL) -> URL? {
        guard url.host == "image.tmdb.org" else { return nil }
        let s = url.absoluteString
        for small in ["/t/p/w300/", "/t/p/w185/", "/t/p/w92/"] where s.contains(small) {
            return URL(string: s.replacingOccurrences(of: small, with: "/t/p/original/"))
        }
        return nil
    }
}
