import SwiftUI

/// Description text clamped to `lines`, with a low-key "more" that fades in over the end of the last line.
/// "more" only appears when the text really is cut off. Truncation is detected by comparing the clamped height
/// with a hidden, unclamped copy (two cheap layout reads, no timers or extra state churn).
struct ExpandableText: View {
    let text: String
    var lines = 2
    var font: Font = .subheadline

    @State private var expanded = false
    @State private var truncated = false
    @State private var clampedHeight: CGFloat = 0
    @State private var fullHeight: CGFloat = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(text)
                .font(font)
                .lineLimit(expanded ? nil : lines)
                .frame(maxWidth: .infinity, alignment: .leading)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { h in
                    if !expanded { clampedHeight = h; refresh() }
                }
                .background {
                    Text(text).font(font)
                        .fixedSize(horizontal: false, vertical: true)
                        .hidden()
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { h in
                            fullHeight = h; refresh()
                        }
                }
                .overlay(alignment: .bottomTrailing) {
                    if truncated && !expanded {
                        Button(action: toggle) {
                            Text("more").font(font).foregroundStyle(.secondary)
                                .padding(.leading, 28)
                                .background(LinearGradient(stops: [.init(color: .clear, location: 0),
                                                                   .init(color: Color(.systemBackground), location: 0.4)],
                                                           startPoint: .leading, endPoint: .trailing))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Show full description")
                    }
                }
            if truncated && expanded {
                Button("less", action: toggle)
                    .font(font).foregroundStyle(.secondary).buttonStyle(.plain)
                    .accessibilityLabel("Show less")
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { if truncated { toggle() } }
        .animation(.snappy(duration: 0.25), value: expanded)
    }

    private func refresh() { truncated = fullHeight > clampedHeight + 1 }
    private func toggle() { expanded.toggle() }
}
