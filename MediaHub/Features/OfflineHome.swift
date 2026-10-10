import SwiftUI

/// What the app opens to when there is no connection at launch: the Downloads page, with a banner and a way into the full app.
/// It never closes by itself when the connection returns, so playback isn't interrupted; the banner offers the switch.
struct OfflineHome: View {
    let exit: () -> Void
    @Environment(Connectivity.self) private var connectivity
    @Environment(ThemeStore.self) private var theme

    private var online: Bool { connectivity.isOnline ?? false }

    var body: some View {
        NavigationStack {
            DownloadsView()
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) { Button("Open App", action: exit) }
                }
                .safeAreaInset(edge: .bottom) { banner }
        }
        .tint(theme.accent)
    }

    private var banner: some View {
        HStack(spacing: 12) {
            Image(systemName: online ? "wifi" : "wifi.slash").font(.title3)
                .foregroundStyle(online ? theme.accent : Color.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(online ? "You're back online" : "You're offline").font(.subheadline.weight(.semibold))
                Text(online ? "Open the full app whenever you like." : "Showing what's saved on this device.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if online { Button("Open Pear", action: exit).buttonStyle(.glassProminent) }
        }
        .padding(14)
        .glassEffect(.regular, in: .rect(cornerRadius: 22))
        .padding(.horizontal, 16).padding(.bottom, 8)
    }
}
