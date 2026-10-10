import SwiftUI

/// The profile's library switch: this device or Simkl, plus syncing the two. Used on the profile page and in Settings.
/// Rows only, so it works inside a Form section or a card.
struct LibrarySourceControls: View {
    @Environment(LibraryPrefs.self) private var prefs
    @Environment(SimklStore.self) private var simkl
    @Environment(LocalLibrary.self) private var library
    @Environment(WatchHistory.self) private var history

    var body: some View {
        let connected = simkl.isConnected
        let source = prefs.source(simkl)
        Picker("Library", selection: Binding(get: { source }, set: { choose($0) })) {
            Text("This device").tag(LibrarySource.local)
            Text("Simkl").tag(LibrarySource.simkl)
        }
        .pickerStyle(.segmented)
        .disabled(!connected)

        if connected {
            Text(source == .local
                 ? "Your own library and watch tracking on this device. Nothing is sent to Simkl."
                 : "Simkl's lists are your library, and what you watch is scrobbled to Simkl.")
                .font(.footnote).foregroundStyle(.secondary)

            Toggle("Keep in sync automatically", isOn: Binding(get: { prefs.autoSync }, set: { prefs.setAutoSync($0) }))

            Button { Task { await prefs.sync(simkl: simkl, library: library, history: history, force: true) } } label: {
                HStack {
                    Label("Sync now", systemImage: "arrow.triangle.2.circlepath")
                    Spacer()
                    if prefs.isSyncing { ProgressView() }
                }
            }
            .disabled(prefs.isSyncing)

            if let report = prefs.report {
                Text(report).font(.footnote).foregroundStyle(.secondary)
            } else if let last = prefs.lastSync {
                Text("Last synced \(last.formatted(.relative(presentation: .named)))").font(.footnote).foregroundStyle(.secondary)
            }
        } else {
            Text("Using the library on this device. Connect Simkl in Integrations to use it as your library or to sync with it.")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }

    private func choose(_ s: LibrarySource) {
        withAnimation(.snappy(duration: 0.3)) { prefs.choose(s) }
        // Switching to Simkl: make sure its lists are loaded (a no-op if they were fetched in the last 15 minutes).
        if s == .simkl { Task { await simkl.sync() } }
    }
}
