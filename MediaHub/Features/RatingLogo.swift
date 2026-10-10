import SwiftUI

/// Small brand-style marks drawn in SwiftUI, so there are no image assets to bundle and nothing to download.
/// Drop official artwork into Assets.xcassets later and swap the body of `RatingLogo` if you want pixel-exact logos.
struct RatingLogo: View {
    let label: String
    var score: Double? = nil
    var height: CGFloat = 18

    var body: some View {
        switch label {
        case "IMDb": imdb
        case "TMDB": tmdb
        case "Rotten Tomatoes": tomato
        case "RT Audience": popcorn
        case "Metacritic": metacritic
        case "Letterboxd": letterboxd
        case "Trakt": trakt
        default: Text(label).font(.caption2.weight(.semibold)).lineLimit(1)
        }
    }

    private var imdb: some View {
        Text("IMDb")
            .font(.system(size: height * 0.62, weight: .black))
            .foregroundStyle(.black)
            .padding(.horizontal, height * 0.28)
            .frame(height: height)
            .background(Color(red: 0.96, green: 0.77, blue: 0.09), in: RoundedRectangle(cornerRadius: height * 0.2, style: .continuous))
    }

    private var tmdb: some View {
        Text("TMDB")
            .font(.system(size: height * 0.5, weight: .heavy))
            .foregroundStyle(Color(red: 0.05, green: 0.15, blue: 0.25))
            .padding(.horizontal, height * 0.3)
            .frame(height: height)
            .background(LinearGradient(colors: [Color(red: 0.56, green: 0.81, blue: 0.63), Color(red: 0.0, green: 0.71, blue: 0.89)],
                                       startPoint: .leading, endPoint: .trailing),
                        in: RoundedRectangle(cornerRadius: height * 0.2, style: .continuous))
    }

    /// Fresh tomato at 60% and above, green splat below.
    private var tomato: some View {
        Group {
            if (score ?? 100) >= 60 {
                ZStack(alignment: .top) {
                    Circle().fill(Color(red: 0.98, green: 0.19, blue: 0.13)).padding(.top, height * 0.1)
                    Capsule().fill(Color(red: 0.3, green: 0.67, blue: 0.2))
                        .frame(width: height * 0.4, height: height * 0.2)
                }
            } else {
                Image(systemName: "seal.fill").resizable().scaledToFit()
                    .foregroundStyle(Color(red: 0.45, green: 0.7, blue: 0.15))
            }
        }
        .frame(width: height, height: height)
    }

    private var popcorn: some View {
        ZStack(alignment: .bottom) {
            HStack(spacing: -height * 0.12) {
                ForEach(0..<3, id: \.self) { _ in Circle().fill(Color(red: 1, green: 0.9, blue: 0.55)).frame(width: height * 0.4) }
            }
            .offset(y: -height * 0.5)
            Bucket().fill(Color(red: 0.98, green: 0.19, blue: 0.13)).frame(width: height * 0.72, height: height * 0.62)
        }
        .frame(width: height, height: height)
    }

    private var metacritic: some View {
        let s = score ?? 50
        let color: Color = s >= 61 ? Color(red: 0.4, green: 0.8, blue: 0.2) : s >= 40 ? Color(red: 1, green: 0.8, blue: 0.2) : Color(red: 1, green: 0.1, blue: 0.1)
        return Text("M").font(.system(size: height * 0.66, weight: .black)).foregroundStyle(.white)
            .frame(width: height, height: height)
            .background(color, in: RoundedRectangle(cornerRadius: height * 0.22, style: .continuous))
    }

    private var letterboxd: some View {
        HStack(spacing: -height * 0.16) {
            Circle().fill(Color(red: 1, green: 0.5, blue: 0))
            Circle().fill(Color(red: 0, green: 0.88, blue: 0.33))
            Circle().fill(Color(red: 0.25, green: 0.74, blue: 0.96))
        }
        .frame(width: height * 1.5, height: height * 0.62)
    }

    private var trakt: some View {
        Image(systemName: "checkmark").font(.system(size: height * 0.55, weight: .black)).foregroundStyle(.white)
            .frame(width: height, height: height)
            .background(Color(red: 0.93, green: 0.11, blue: 0.14), in: Circle())
    }

    private struct Bucket: Shape {
        func path(in r: CGRect) -> Path {
            var p = Path()
            p.move(to: CGPoint(x: r.minX, y: r.minY))
            p.addLine(to: CGPoint(x: r.maxX, y: r.minY))
            p.addLine(to: CGPoint(x: r.maxX - r.width * 0.12, y: r.maxY))
            p.addLine(to: CGPoint(x: r.minX + r.width * 0.12, y: r.maxY))
            p.closeSubpath()
            return p
        }
    }
}

/// Logo + score used on the detail page. `flat` drops the pill behind it and shrinks the logo for a quieter row.
struct RatingBadge: View {
    let rating: MDBListClient.Rating
    var flat = false

    var body: some View {
        HStack(spacing: flat ? 6 : 7) {
            RatingLogo(label: rating.label, score: rating.score, height: flat ? 15 : 18)
            Text(rating.text).font(flat ? .footnote.weight(.semibold) : .subheadline.weight(.semibold)).monospacedDigit()
        }
        .padding(.horizontal, flat ? 0 : 12).padding(.vertical, flat ? 2 : 8)
        .background { if !flat { Capsule().fill(.quaternary) } }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(rating.label) \(rating.text)")
    }
}

/// Brand logo + score, for use over artwork (Home hero).
struct RatingPill: View {
    let rating: MDBListClient.Rating

    var body: some View {
        HStack(spacing: 6) {
            RatingLogo(label: rating.label, score: rating.score, height: 16)
            Text(rating.text).font(.subheadline.weight(.bold)).monospacedDigit()
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(.black.opacity(0.4), in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.12), lineWidth: 0.5))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(rating.label) \(rating.text)")
    }
}
