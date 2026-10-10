import SwiftUI
import SafariServices

/// Episode-card styling without the description: the thumbnail dissolves into a softly tinted panel,
/// with the kind ("TRAILER"), the title and a play button. Shorter than EpisodeCard.
struct TrailerCard: View {
    let video: TMDBClient.Video
    let onTap: () -> Void
    @State private var tint: Color?

    static let width: CGFloat = 250
    static let height: CGFloat = 214
    private let radius: CGFloat = 22

    var body: some View {
        ZStack(alignment: .top) {
            Color(white: 0.09)
            if let tint { tint.opacity(0.3).transition(.opacity) }
            RemoteImage(url: video.thumbnail, size: Self.width)
                .frame(width: Self.width, height: Self.width * 9 / 16)
                .mask {
                    LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black, location: 0.5),
                                           .init(color: .clear, location: 1)], startPoint: .top, endPoint: .bottom)
                }
                .overlay {
                    Image(systemName: "play.fill").font(.system(size: 16, weight: .bold)).foregroundStyle(.white)
                        .frame(width: 44, height: 44).background(.black.opacity(0.38), in: Circle())
                        .overlay(Circle().strokeBorder(.white.opacity(0.25), lineWidth: 0.5))
                        .offset(y: -12)
                }
        }
        .frame(width: Self.width, height: Self.height)
        .overlay(alignment: .bottomLeading) {
            VStack(alignment: .leading, spacing: 4) {
                Text(video.type.uppercased()).font(.system(size: 12, weight: .semibold)).tracking(0.8)
                    .foregroundStyle(.white.opacity(0.65))
                Text(video.name).font(.system(size: 17, weight: .bold)).lineLimit(2).multilineTextAlignment(.leading)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 16).padding(.bottom, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .allowsHitTesting(false)
        }
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(.white.opacity(0.1), lineWidth: 1) }
        .overlay { Button(action: onTap) { Color.clear.contentShape(Rectangle()) }.buttonStyle(PressableStyle()) }
        .contentShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .animation(.easeOut(duration: 0.3), value: tint == nil)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(video.type): \(video.name)")
        .accessibilityAddTraits(.isButton)
        .task(id: video.key) {
            tint = nil
            guard let u = video.thumbnail, let c = await ImagePipeline.shared.averageColor(for: u), !Task.isCancelled else { return }
            tint = Color(uiColor: c)
        }
    }
}

/// In-app browser for opening a trailer.
struct SafariView: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> SFSafariViewController { SFSafariViewController(url: url) }
    func updateUIViewController(_ vc: SFSafariViewController, context: Context) {}
}
