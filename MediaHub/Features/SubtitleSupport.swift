import SwiftUI
import UIKit
import AetherEngine

/// Reads fields off engine types by name. The engine's `TrackInfo` / `SubtitleCue` / `SubtitleImage` field
/// types (optional or not, Int vs Int32 ...) can shift between releases; this keeps the app compiling either way.
enum Reflect {
    static func unwrap(_ v: Any?) -> Any? {
        guard let v else { return nil }
        let m = Mirror(reflecting: v)
        guard m.displayStyle == .optional else { return v }
        guard let first = m.children.first else { return nil }
        return unwrap(first.value)
    }
    static func value(_ obj: Any, _ name: String) -> Any? {
        for c in Mirror(reflecting: obj).children where c.label == name { return unwrap(c.value) }
        return nil
    }
    static func string(_ obj: Any, _ name: String) -> String? { value(obj, name) as? String }
    static func bool(_ obj: Any, _ name: String) -> Bool { (value(obj, name) as? Bool) ?? false }
    static func double(_ obj: Any, _ name: String) -> Double? {
        guard let v = value(obj, name) else { return nil }
        return number(v)
    }
    static func number(_ v: Any) -> Double? {
        if let d = v as? Double { return d }
        if let f = v as? Float { return Double(f) }
        if let i = v as? Int { return Double(i) }
        if let i = v as? Int64 { return Double(i) }
        if let i = v as? Int32 { return Double(i) }
        if let c = v as? CGFloat { return Double(c) }
        return nil
    }
    static func int(_ v: Any?) -> Int? {
        guard let u = unwrap(v) else { return nil }
        if let i = u as? Int { return i }
        if let i = u as? Int32 { return Int(i) }
        if let i = u as? Int64 { return Int(i) }
        if let i = u as? UInt32 { return Int(i) }
        return nil
    }

    /// Plain text of a cue payload: handles `.text(String)` and styled `.richText([runs])` alike.
    static func text(_ any: Any?) -> String {
        guard let v = unwrap(any) else { return "" }
        if let s = v as? String { return s }
        let m = Mirror(reflecting: v)
        switch m.displayStyle {
        case .collection:
            return m.children.map { text($0.value) }.joined()
        case .struct, .class:
            for key in ["text", "string", "content"] { if let t = value(v, key) { let s = text(t); if !s.isEmpty { return s } } }
            return ""
        case .enum, .tuple:
            return m.children.first.map { text($0.value) } ?? ""
        default:
            return ""
        }
    }

    static func cgImage(_ any: Any?, depth: Int = 0) -> CGImage? {
        guard depth < 3, let v = unwrap(any) else { return nil }
        // `as? CGImage` is rejected for CF types ("will always succeed"); compare CFTypeIDs instead.
        let obj = v as AnyObject
        if CFGetTypeID(obj) == CGImage.typeID { return unsafeBitCast(obj, to: CGImage.self) }
        if let u = v as? UIImage { return u.cgImage }
        for c in Mirror(reflecting: v).children { if let i = cgImage(c.value, depth: depth + 1) { return i } }
        return nil
    }

    static func normalizedRect(_ any: Any?) -> CGRect? {
        guard let v = unwrap(any) else { return nil }
        for c in Mirror(reflecting: v).children {
            if let r = unwrap(c.value) as? CGRect, r.width > 0, r.height > 0 { return r }
        }
        return nil
    }

    /// "English", "English (SDH)", "Spanish · Forced"...
    static func trackTitle(_ t: Any) -> String {
        let id = int(value(t, "id")) ?? 0
        let lang = string(t, "language")
        let name = string(t, "name")
        var base = "Track \(id)"
        if let l = lang, !l.isEmpty, l.lowercased() != "und" {
            base = Locale.current.localizedString(forLanguageCode: l)?.capitalized ?? l.uppercased()
        } else if let n = name, !n.isEmpty { base = n }
        if let n = name, !n.isEmpty, n.caseInsensitiveCompare(base) != .orderedSame,
           n.caseInsensitiveCompare(lang ?? "") != .orderedSame { base += " (\(n))" }
        if bool(t, "isForced") { base += " · Forced" }
        if bool(t, "isHearingImpaired") { base += " · SDH" }
        if bool(t, "isExternal") { base += " · External" }
        return base
    }
}

/// One subtitle line or bitmap, flattened from the engine's `SubtitleCue`.
struct SubCue: Equatable {
    let start: Double
    let end: Double
    let text: String
    let image: CGImage?
    let rect: CGRect?       // normalised placement of a bitmap on the video canvas, when the engine provides it

    static func == (a: SubCue, b: SubCue) -> Bool {
        a.start == b.start && a.end == b.end && a.text == b.text
            && a.image?.width == b.image?.width && a.image?.height == b.image?.height && a.rect == b.rect
    }

    static func make(_ c: SubtitleCue) -> SubCue? {
        let start = Double(c.startTime)
        let end = Reflect.double(c, "endTime") ?? Reflect.double(c, "end")
            ?? Reflect.double(c, "duration").map { start + $0 } ?? start + 5
        let payload = Mirror(reflecting: c.body).children.first?.value
        let image = Reflect.cgImage(payload)
        var text = image == nil ? Reflect.text(payload) : ""
        // Strip leftover ASS override tags ({\an8}, {\i1}...) and convert hard line breaks.
        text = text.replacingOccurrences(of: "\\{[^}]*\\}", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\\N", with: "\n").replacingOccurrences(of: "\\n", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard image != nil || !text.isEmpty else { return nil }
        return SubCue(start: start, end: end, text: text, image: image, rect: image == nil ? nil : Reflect.normalizedRect(payload))
    }
}

/// User-chosen subtitle look. Persisted as one JSON string (`sub.style`), shared by Settings and the player.
struct SubtitleStyle: Codable, Equatable {
    var size: Double = 26            // px (points)
    var color: String = "white"      // white, yellow, cyan, green, orange, pink
    var weight: String = "semibold"  // regular, medium, semibold, bold, heavy
    var font: String = "system"      // system, rounded, serif, mono
    var edge: String = "shadow"      // none, shadow, outline
    var boxOpacity: Double = 0       // 0 = no box, up to 0.9
    var bottom: Double = 40          // distance from the bottom edge

    static let storageKey = "sub.style"
    static let colors: [(name: String, color: Color)] = [
        ("white", .white), ("yellow", Color(red: 1, green: 0.9, blue: 0.2)), ("cyan", Color(red: 0.3, green: 0.9, blue: 1)),
        ("green", Color(red: 0.4, green: 1, blue: 0.5)), ("orange", Color(red: 1, green: 0.65, blue: 0.2)),
        ("pink", Color(red: 1, green: 0.55, blue: 0.75)),
    ]
    static func decode(_ json: String) -> SubtitleStyle {
        guard let d = json.data(using: .utf8), let s = try? JSONDecoder().decode(SubtitleStyle.self, from: d) else { return SubtitleStyle() }
        return s
    }
    var encoded: String { (try? JSONEncoder().encode(self)).flatMap { String(data: $0, encoding: .utf8) } ?? "" }

    var textColor: Color { Self.colors.first { $0.name == color }?.color ?? .white }
    var fontWeight: Font.Weight {
        switch weight { case "regular": return .regular; case "medium": return .medium; case "bold": return .bold
        case "heavy": return .heavy; default: return .semibold }
    }
    var design: Font.Design {
        switch font { case "rounded": return .rounded; case "serif": return .serif; case "mono": return .monospaced; default: return .default }
    }
}

/// Subtitle languages offered as the default. `matches` copes with "en", "eng", "en-US" and "English".
enum SubLanguages {
    struct Lang: Identifiable, Hashable { let code: String; let name: String; let aliases: [String]; var id: String { code } }
    static let all: [Lang] = [
        .init(code: "en", name: "English", aliases: ["eng"]), .init(code: "ar", name: "Arabic", aliases: ["ara"]),
        .init(code: "fr", name: "French", aliases: ["fra", "fre"]), .init(code: "es", name: "Spanish", aliases: ["spa"]),
        .init(code: "de", name: "German", aliases: ["deu", "ger"]), .init(code: "it", name: "Italian", aliases: ["ita"]),
        .init(code: "pt", name: "Portuguese", aliases: ["por", "pob"]), .init(code: "ru", name: "Russian", aliases: ["rus"]),
        .init(code: "tr", name: "Turkish", aliases: ["tur"]), .init(code: "ja", name: "Japanese", aliases: ["jpn"]),
        .init(code: "ko", name: "Korean", aliases: ["kor"]), .init(code: "zh", name: "Chinese", aliases: ["zho", "chi", "cmn"]),
        .init(code: "hi", name: "Hindi", aliases: ["hin"]), .init(code: "nl", name: "Dutch", aliases: ["nld", "dut"]),
        .init(code: "pl", name: "Polish", aliases: ["pol"]), .init(code: "sv", name: "Swedish", aliases: ["swe"]),
        .init(code: "da", name: "Danish", aliases: ["dan"]), .init(code: "no", name: "Norwegian", aliases: ["nor", "nob"]),
        .init(code: "fi", name: "Finnish", aliases: ["fin"]), .init(code: "el", name: "Greek", aliases: ["ell", "gre"]),
        .init(code: "he", name: "Hebrew", aliases: ["heb"]), .init(code: "id", name: "Indonesian", aliases: ["ind"]),
        .init(code: "th", name: "Thai", aliases: ["tha"]), .init(code: "vi", name: "Vietnamese", aliases: ["vie"]),
        .init(code: "uk", name: "Ukrainian", aliases: ["ukr"]), .init(code: "cs", name: "Czech", aliases: ["ces", "cze"]),
        .init(code: "hu", name: "Hungarian", aliases: ["hun"]), .init(code: "ro", name: "Romanian", aliases: ["ron", "rum"]),
    ]

    /// Two-letter code for any spelling of a language, or nil if unknown.
    static func canonical(_ raw: String?) -> String? {
        guard var l = raw?.lowercased().trimmingCharacters(in: .whitespaces), !l.isEmpty else { return nil }
        if let i = l.firstIndex(where: { $0 == "-" || $0 == "_" }) { l = String(l[..<i]) }
        for lang in all {
            if l == lang.code || lang.aliases.contains(l) || l == lang.name.lowercased() { return lang.code }
        }
        return nil
    }
    static func matches(_ track: String?, _ wanted: String) -> Bool {
        if let a = canonical(track), let b = canonical(wanted) { return a == b }
        return track?.lowercased() == wanted.lowercased()
    }
}

/// Paints the active cues over the video. Text is drawn natively; PGS / DVD bitmaps are placed on a 16:9 canvas.
struct SubtitleOverlay: View {
    let cues: [SubCue]
    let lift: CGFloat
    var style = SubtitleStyle()

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            let video = Self.videoRect(in: size)
            let lines = cues.filter { $0.image == nil }.map(\.text).joined(separator: "\n")
            ZStack {
                ForEach(Array(cues.enumerated()), id: \.offset) { _, cue in
                    bitmap(cue, video: video, size: size)
                }
                if !lines.isEmpty {
                    VStack {
                        Spacer(minLength: 0)
                        label(lines)
                            .frame(maxWidth: size.width * 0.9)
                            .padding(.bottom, style.bottom + lift)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .frame(width: size.width, height: size.height)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    @ViewBuilder private func label(_ text: String) -> some View {
        let base = Text(text)
            .font(.system(size: style.size, weight: style.fontWeight, design: style.design))
            .multilineTextAlignment(.center)
            .foregroundStyle(style.textColor)
        let boxed = style.boxOpacity > 0.01
        Group {
            switch style.edge {
            case "none":
                base
            case "outline":
                base.shadow(color: .black, radius: 0, x: 1.3, y: 0).shadow(color: .black, radius: 0, x: -1.3, y: 0)
                    .shadow(color: .black, radius: 0, x: 0, y: 1.3).shadow(color: .black, radius: 0, x: 0, y: -1.3)
            default:
                base.shadow(color: .black, radius: 1.5).shadow(color: .black, radius: 3)
            }
        }
        .padding(.horizontal, boxed ? 12 : 0).padding(.vertical, boxed ? 5 : 0)
        .background(.black.opacity(style.boxOpacity), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    @ViewBuilder private func bitmap(_ cue: SubCue, video: CGRect, size: CGSize) -> some View {
        if let img = cue.image {
            let pic = Image(decorative: img, scale: 1).resizable()
            if let r = cue.rect, r.maxX <= 1.01, r.maxY <= 1.01 {
                pic.frame(width: r.width * video.width, height: r.height * video.height)
                    .position(x: video.minX + r.midX * video.width, y: video.minY + r.midY * video.height)
            } else {
                pic.scaledToFit()
                    .frame(maxWidth: size.width * 0.9, maxHeight: size.height * 0.3)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .padding(.bottom, style.bottom + lift)
            }
        }
    }

    private static func videoRect(in s: CGSize) -> CGRect {
        let ar: CGFloat = 16.0 / 9.0
        var w = s.width, h = s.width / ar
        if h > s.height { h = s.height; w = h * ar }
        return CGRect(x: (s.width - w) / 2, y: (s.height - h) / 2, width: w, height: h)
    }
}
