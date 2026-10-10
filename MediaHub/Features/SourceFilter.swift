import SwiftUI

/// Narrows a sources list to one add-on / provider. `id == nil` means "all add-ons".
enum SourceFilter {
    static func apply(_ groups: [(Addon, [StreamItem])], _ id: String?) -> [(Addon, [StreamItem])] {
        // A stale id (the add-on returned nothing this time) falls back to showing everything.
        guard let id, groups.contains(where: { $0.0.id == id }) else { return groups }
        return groups.filter { $0.0.id == id }
    }
}

/// Dropdown for choosing which add-on's sources to list. Shared by the details sheet and the player panel.
struct AddonFilterMenu: View {
    let groups: [(Addon, [StreamItem])]
    @Binding var selection: String?
    /// White-on-glass styling for the player; the default follows the system look.
    var onDark = false

    private var selectedName: String {
        guard let id = selection, let g = groups.first(where: { $0.0.id == id }) else { return "All add-ons" }
        return g.0.manifest.name
    }

    private func title(_ addon: Addon, _ items: [StreamItem]) -> String {
        let n = items.filter(\.isPlayable).count
        return n > 0 ? "\(addon.manifest.name) (\(n))" : addon.manifest.name
    }

    var body: some View {
        Menu {
            Picker("Add-on", selection: $selection) {
                Text("All add-ons").tag(String?.none)
                ForEach(groups, id: \.0.id) { addon, items in
                    Text(title(addon, items)).tag(String?.some(addon.id))
                }
            }
        } label: {
            HStack(spacing: 5) {
                Text(selectedName).lineLimit(1)
                Image(systemName: "chevron.up.chevron.down").font(.caption2.weight(.bold))
            }
            .font(.footnote.weight(.semibold))
            .foregroundStyle(onDark ? Color.white : Color.primary)
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(onDark ? Color.white.opacity(0.14) : Color.secondary.opacity(0.18), in: Capsule())
            .frame(maxWidth: 190)
        }
    }
}
