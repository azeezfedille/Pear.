import SwiftUI

/// Appearance controls for subtitles: used inside the player (compact, over video) and on the Settings page.
/// Everything edits the same stored style, so what you set in the player becomes your default.
struct SubtitleStyleControls: View {
    @AppStorage(SubtitleStyle.storageKey) private var json = ""
    var showsPreview = true
    var onDark = false

    private var style: SubtitleStyle { SubtitleStyle.decode(json) }

    private func binding<T>(_ kp: WritableKeyPath<SubtitleStyle, T>) -> Binding<T> {
        Binding(get: { style[keyPath: kp] },
                set: { v in var s = style; s[keyPath: kp] = v; json = s.encoded })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if showsPreview { preview }

            row("Size", value: "\(Int(style.size)) px") {
                HStack(spacing: 10) {
                    Image(systemName: "textformat.size.smaller").font(.footnote).foregroundStyle(.secondary)
                    Slider(value: binding(\.size), in: 12...72, step: 1)
                    Image(systemName: "textformat.size.larger").foregroundStyle(.secondary)
                }
            }

            row("Colour") {
                HStack(spacing: 12) {
                    ForEach(SubtitleStyle.colors, id: \.name) { c in
                        Button { binding(\.color).wrappedValue = c.name } label: {
                            Circle().fill(c.color).frame(width: 28, height: 28)
                                .overlay(Circle().strokeBorder(.white.opacity(0.9), lineWidth: style.color == c.name ? 3 : 0))
                                .overlay(Circle().strokeBorder(.black.opacity(0.25), lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            row("Font") {
                Picker("Font", selection: binding(\.font)) {
                    Text("System").tag("system"); Text("Rounded").tag("rounded"); Text("Serif").tag("serif"); Text("Mono").tag("mono")
                }
                .pickerStyle(.segmented)
            }

            row("Weight") {
                Picker("Weight", selection: binding(\.weight)) {
                    Text("Reg").tag("regular"); Text("Med").tag("medium"); Text("Semi").tag("semibold")
                    Text("Bold").tag("bold"); Text("Heavy").tag("heavy")
                }
                .pickerStyle(.segmented)
            }

            row("Edge") {
                Picker("Edge", selection: binding(\.edge)) {
                    Text("None").tag("none"); Text("Shadow").tag("shadow"); Text("Outline").tag("outline")
                }
                .pickerStyle(.segmented)
            }

            row("Background", value: style.boxOpacity < 0.01 ? "Off" : "\(Int(style.boxOpacity * 100))%") {
                Slider(value: binding(\.boxOpacity), in: 0...0.9, step: 0.05)
            }

            row("Distance from bottom", value: "\(Int(style.bottom)) px") {
                Slider(value: binding(\.bottom), in: 0...160, step: 2)
            }

            Button("Reset to defaults", role: .destructive) { json = "" }
                .font(.footnote.weight(.semibold))
        }
        .tint(onDark ? .white : nil)
    }

    private func row<C: View>(_ title: String, value: String? = nil, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                if let value { Text(value).font(.footnote.monospacedDigit()).foregroundStyle(.secondary) }
            }
            content()
        }
    }

    /// Live preview on a fake video frame.
    private var preview: some View {
        ZStack {
            LinearGradient(colors: [Color(white: 0.28), Color(white: 0.08)], startPoint: .top, endPoint: .bottom)
            VStack {
                Spacer()
                SubtitlePreviewText(style: style).padding(.bottom, 10)
            }
        }
        .frame(height: 120)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

/// Same rendering as the real overlay, without needing cues.
private struct SubtitlePreviewText: View {
    let style: SubtitleStyle

    var body: some View {
        ZStack {
            // Reuse the overlay so the preview can't drift from what the player draws.
            SubtitleOverlay(cues: [SubCue(start: 0, end: 1, text: "This is how subtitles look", image: nil, rect: nil)],
                            lift: 0, style: scaled)
        }
        .frame(height: 70)
    }

    /// The preview box is small: cap the size and keep the text inside it.
    private var scaled: SubtitleStyle {
        var s = style
        s.size = min(style.size, 34)
        s.bottom = 0
        return s
    }
}

/// Settings page: default language + look.
struct SubtitleSettingsView: View {
    @AppStorage("sub.lang") private var lang = "off"
    @AppStorage("subs.online") private var online = true

    var body: some View {
        Form {
            Section {
                Toggle("Find subtitles on OpenSubtitles", isOn: $online)
            } footer: {
                Text("Adds an OpenSubtitles list to the player's subtitle panel (no account needed). If your default language isn't in the file, the best match is loaded automatically.")
            }
            Section {
                Picker("Default language", selection: $lang) {
                    Text("Off").tag("off")
                    ForEach(SubLanguages.all) { Text($0.name).tag($0.code) }
                }
            } footer: {
                Text("Picked automatically when a video starts and the file has a matching track. Forced and hearing-impaired tracks are used only if nothing else matches.")
            }
            Section("Appearance") {
                SubtitleStyleControls().padding(.vertical, 4)
            }
        }
        .navigationTitle("Subtitles")
        .navigationBarTitleDisplayMode(.inline)
    }
}
