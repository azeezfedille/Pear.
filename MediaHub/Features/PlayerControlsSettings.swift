import SwiftUI

// MARK: - Items

/// Everything that can sit in the player's controls pill. Declaration order is the default on-screen order;
/// the user can rearrange it (`orderKey`).
enum PillItem: String, CaseIterable, Identifiable {
    case speed, episodes, sources, volume, pip, subtitles, audio, next

    var id: String { rawValue }

    var title: String {
        switch self {
        case .speed: "Speed"
        case .episodes: "Episodes"
        case .sources: "Sources"
        case .volume: "Volume"
        case .pip: "Picture in Picture"
        case .subtitles: "Subtitles"
        case .audio: "Audio track"
        case .next: "Next episode"
        }
    }

    var symbol: String {
        switch self {
        case .speed: "speedometer"
        case .episodes: "list.bullet"
        case .sources: "rectangle.stack"
        case .volume: "speaker.wave.2"
        case .pip: "pip.enter"
        case .subtitles: "captions.bubble"
        case .audio: "waveform"
        case .next: "forward.end.fill"
        }
    }

    // MARK: Which items stay visible when the pill is folded

    /// `@AppStorage` key: the pinned items as comma-separated raw values.
    static let storageKey = "player.pillPinned"
    /// The pill folds when it has more items than this, and at most this many can be pinned.
    static let maxPinned = 4
    /// What stays visible out of the box.
    static let defaultPinned: Set<PillItem> = [.volume, .subtitles, .speed, .pip]
    static let defaultRaw = encode(defaultPinned)

    /// Unknown names are ignored, anything past `maxPinned` is dropped, and an empty list means the default.
    static func decode(_ raw: String) -> Set<PillItem> {
        let found = raw.split(separator: ",").compactMap { PillItem(rawValue: String($0)) }
        let set = Set(found.prefix(maxPinned))
        return set.isEmpty ? defaultPinned : set
    }

    static func encode(_ items: Set<PillItem>) -> String {
        allCases.filter { items.contains($0) }.map(\.rawValue).joined(separator: ",")
    }

    // MARK: Order

    /// `@AppStorage` key: every item in the user's order, as comma-separated raw values.
    static let orderKey = "player.pillOrder"
    static let defaultOrder: [PillItem] = allCases
    static let defaultOrderRaw = encodeOrder(defaultOrder)

    /// Always returns every item exactly once: unknown names and repeats are ignored, and items missing from the saved
    /// list (a button added in a later version) go at the end.
    static func decodeOrder(_ raw: String) -> [PillItem] {
        var seen = Set<PillItem>()
        var out: [PillItem] = []
        for part in raw.split(separator: ",") {
            if let item = PillItem(rawValue: String(part)), seen.insert(item).inserted { out.append(item) }
        }
        return out + allCases.filter { !seen.contains($0) }
    }

    static func encodeOrder(_ items: [PillItem]) -> String {
        items.map(\.rawValue).joined(separator: ",")
    }
}

// MARK: - Settings screen

/// Settings -> Playback -> Player controls: which buttons of the player's pill stay visible while it is folded,
/// and the order they sit in. The pill only folds when it has more than four buttons; the rest sit behind its chevron.
struct PlayerControlsSettingsView: View {
    @AppStorage(PillItem.storageKey) private var raw = PillItem.defaultRaw
    @AppStorage(PillItem.orderKey) private var orderRaw = PillItem.defaultOrderRaw

    private var pinned: Set<PillItem> { PillItem.decode(raw) }
    private var order: [PillItem] { PillItem.decodeOrder(orderRaw) }

    var body: some View {
        Form {
            Section {
                preview
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
            }

            Section {
                ForEach(PillItem.allCases) { item in
                    Toggle(isOn: binding(item)) {
                        Label(item.title, systemImage: item.symbol)
                    }
                    .disabled(isLocked(item))
                }
            } header: {
                Text("Always visible · \(pinned.count) of \(PillItem.maxPinned)")
            } footer: {
                Text("These stay in the pill while it is folded. Everything else slides out to the left when you tap the arrow, and folds back after 5 seconds. A button only shows when it applies: Episodes for shows, Next for series, Audio when there is more than one track.")
            }

            Section {
                ForEach(order) { item in
                    Label(item.title, systemImage: item.symbol)
                }
                .onMove { source, destination in move(from: source, to: destination) }
            } header: {
                Text("Order")
            } footer: {
                Text("Drag the handles to rearrange the buttons, left to right. When the pill is unfolded, the buttons that aren't always visible slide out to the left of the others; each group keeps this order.")
            }
            // Drag handles are always showing here, so there is no Edit button to find.
            .environment(\.editMode, .constant(.active))

            Section {
                Button("Reset to default") { raw = PillItem.defaultRaw; orderRaw = PillItem.defaultOrderRaw }
                    .disabled(pinned == PillItem.defaultPinned && order == PillItem.defaultOrder)
            }
        }
        .navigationTitle("Player controls")
        .navigationBarTitleDisplayMode(.inline)
    }

    /// The pill as it will look when folded.
    private var preview: some View {
        HStack(spacing: 2) {
            Image(systemName: "chevron.left").font(.system(size: 15, weight: .bold)).frame(width: 40, height: 40)
            ForEach(order.filter { pinned.contains($0) }) { item in
                Image(systemName: item.symbol).font(.system(size: 17, weight: .semibold)).frame(width: 40, height: 40)
            }
        }
        .foregroundStyle(.white)
        .padding(4)
        .background(Color.black.opacity(0.75), in: Capsule())
        .animation(.snappy(duration: 0.2), value: raw)
        .animation(.snappy(duration: 0.2), value: orderRaw)
    }

    private func move(from source: IndexSet, to destination: Int) {
        var next = order
        next.move(fromOffsets: source, toOffset: destination)
        orderRaw = PillItem.encodeOrder(next)
    }

    private func binding(_ item: PillItem) -> Binding<Bool> {
        Binding(get: { pinned.contains(item) },
                set: { on in
                    var next = pinned
                    if on { next.insert(item) } else { next.remove(item) }
                    raw = PillItem.encode(next)
                })
    }

    /// Full: nothing more can be pinned until something is unpinned. Last one: at least one stays.
    private func isLocked(_ item: PillItem) -> Bool {
        pinned.contains(item) ? pinned.count <= 1 : pinned.count >= PillItem.maxPinned
    }
}
