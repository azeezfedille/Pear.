import SwiftUI

/// What the player's info card shows for the episode (or movie) that is playing now.
struct PlayerInfo {
    /// The series name for an episode; nil for a movie.
    var kicker: String?
    /// "S2 · E6" for an episode; nil for a movie. Sits on the thumbnail.
    var episodeTag: String?
    /// True while an episode's synopsis is still being fetched, so the card shows placeholder lines instead of jumping in height.
    var isLoading = false
    var title: String
    /// Episode still, or the movie's backdrop.
    var image: URL?
    var overview: String?
    /// Shown above the synopsis when the episode has none and the series' own description stands in.
    var overviewNote: String?
    /// Already formatted ("June 12, 2025", or just the year when that is all that is known).
    var date: String?
    /// Minutes.
    var runtime: Int?
    var ratings: [MDBListClient.Rating] = []

    private static let isoDay: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// "2025-06-12" -> "June 12, 2025". nil when the string is missing or not a date.
    static func pretty(_ s: String?) -> String? {
        guard let s, let d = isoDay.date(from: s) else { return nil }
        return d.formatted(date: .long, time: .omitted)
    }
}

/// Content of the info card opened by tapping the title. Wide: still on the left, details on the right. Narrow
/// (portrait phone): still on top, details underneath. Details are the series and title, date / runtime / rating chips,
/// then the synopsis. No background of its own: the player puts it on its glass card.
struct PlayerInfoCard: View {
    let info: PlayerInfo
    /// The show / movie logo, drawn under the thumbnail. nil until one is found (or when there is none).
    var logo: UIImage? = nil
    let onClose: () -> Void

    private static let thumbWidth: CGFloat = 230
    /// Below this width the still moves above the text; beside it, the text column would be too narrow to read.
    private static let stackBelow: CGFloat = 520
    @State private var stacked = false

    private var runtimeText: String? {
        guard let m = info.runtime, m > 0 else { return nil }
        return m >= 60 ? (m % 60 == 0 ? "\(m / 60)h" : "\(m / 60)h \(m % 60)m") : "\(m) min"
    }

    var body: some View {
        Group {
            if stacked {
                VStack(alignment: .leading, spacing: 14) { thumbColumn; details }
            } else {
                HStack(alignment: .top, spacing: 18) { thumbColumn; details }
            }
        }
        .onGeometryChange(for: Bool.self) { $0.size.width < Self.stackBelow } action: { stacked = $0 }
    }

    // MARK: Thumbnail

    /// The still with the title's logo underneath it.
    private var thumbColumn: some View {
        VStack(alignment: .leading, spacing: 12) {
            thumbnail
            titleLogo
        }
        .frame(maxWidth: stacked ? .infinity : Self.thumbWidth, alignment: .leading)
    }

    @ViewBuilder private var titleLogo: some View {
        if let logo {
            Image(uiImage: logo).resizable().scaledToFit()
                .frame(maxWidth: stacked ? 220 : Self.thumbWidth, maxHeight: 44, alignment: .leading)
                .shadow(color: .black.opacity(0.45), radius: 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityHidden(true)
        }
    }

    @ViewBuilder private var thumbnail: some View {
        if info.image != nil {
            ZStack(alignment: .topLeading) {
                Color.white.opacity(0.08)
                StillImage(url: info.image, size: stacked ? 480 : Self.thumbWidth)
                LinearGradient(colors: [.black.opacity(0.4), .clear], startPoint: .top, endPoint: .center)
                if let tag = info.episodeTag {
                    Text(tag).font(.caption2.bold()).monospacedDigit().foregroundStyle(.white)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(.black.opacity(0.55), in: Capsule())
                        .padding(8)
                }
            }
            .aspectRatio(16.0 / 9.0, contentMode: .fit)
            .frame(width: stacked ? nil : Self.thumbWidth)
            .frame(maxWidth: stacked ? .infinity : nil)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.white.opacity(0.12), lineWidth: 1))
            .accessibilityHidden(true)
        }
    }

    // MARK: Details

    private var details: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            chips
            synopsis
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                if let k = info.kicker {
                    Text(k.uppercased()).font(.caption.weight(.bold)).tracking(0.9)
                        .foregroundStyle(.white.opacity(0.6)).lineLimit(1)
                }
                Text(info.title).font(.system(size: 23, weight: .bold)).lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            // Mirrors the chevron on the title that opened this card.
            Button(action: onClose) {
                Image(systemName: "chevron.down").font(.system(size: 13, weight: .bold))
                    .frame(width: 32, height: 32).background(.white.opacity(0.16), in: Circle())
                    .padding(6).contentShape(Rectangle())
            }
            .buttonStyle(PressableStyle())
            .accessibilityLabel("Close")
        }
    }

    /// Date, runtime and ratings as one row of matching capsules.
    @ViewBuilder private var chips: some View {
        if info.date != nil || runtimeText != nil || !info.ratings.isEmpty {
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    if let d = info.date { chip(d, symbol: "calendar") }
                    if let r = runtimeText { chip(r, symbol: "clock") }
                    ForEach(info.ratings) { ratingChip($0) }
                }
            }
            .scrollIndicators(.hidden)
        }
    }

    private func chip(_ text: String, symbol: String) -> some View {
        Label(text, systemImage: symbol)
            .font(.system(size: 13, weight: .semibold)).lineLimit(1)
            .foregroundStyle(.white.opacity(0.9))
            .padding(.horizontal, 11).padding(.vertical, 7)
            .background(.white.opacity(0.12), in: Capsule())
    }

    private func ratingChip(_ r: MDBListClient.Rating) -> some View {
        HStack(spacing: 6) {
            RatingLogo(label: r.label, score: r.score, height: 15)
            Text(r.text).font(.system(size: 13, weight: .bold)).monospacedDigit()
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 11).padding(.vertical, 6)
        .background(.white.opacity(0.12), in: Capsule())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(r.label) \(r.text)")
    }

    // MARK: Synopsis

    private var synopsis: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text((info.overviewNote ?? "Synopsis").uppercased())
                .font(.caption2.weight(.bold)).tracking(0.9).foregroundStyle(.white.opacity(0.5))
            if let o = info.overview, !o.isEmpty {
                // Plain text when it fits; scrolls when a long synopsis would push the card off a landscape phone.
                ViewThatFits(in: .vertical) {
                    text(o)
                    ScrollView { text(o) }.scrollIndicators(.automatic)
                }
                .frame(maxHeight: 124)
            } else if info.isLoading {
                skeleton
            } else {
                Text("No synopsis available yet.").font(.system(size: 15).italic()).foregroundStyle(.white.opacity(0.5))
            }
        }
    }

    private func text(_ s: String) -> some View {
        Text(s)
            .font(.system(size: 15, weight: .regular)).lineSpacing(3)
            .foregroundStyle(.white.opacity(0.9))
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// Static placeholder lines while the episode's synopsis loads.
    private var skeleton: some View {
        VStack(alignment: .leading, spacing: 9) {
            let widths: [CGFloat] = [1, 1, 0.6]
            ForEach(widths.indices, id: \.self) { i in
                Capsule().fill(.white.opacity(0.1)).frame(height: 10)
                    .frame(maxWidth: .infinity)
                    .scaleEffect(x: widths[i], anchor: .leading)
            }
        }
        .padding(.vertical, 4)
        .accessibilityHidden(true)
    }
}
