import SwiftUI

/// Settings -> Add-ons: everything about installed Stremio add-ons in one place.
/// Reorder (Edit), switch on/off without removing, open an add-on's setup page, reload, remove, and add.
struct AddonsSettingsView: View {
    @Environment(AddonStore.self) private var store
    @Environment(\.openURL) private var openURL
    @State private var urlText = ""
    @State private var error: String?
    @State private var busy = false
    @State private var reloading = Set<String>()
    @State private var note: String?

    var body: some View {
        List {
            Section {
                if store.addons.isEmpty {
                    Text("No add-ons installed.").foregroundStyle(.secondary)
                }
                ForEach(store.addons) { a in row(a) }
                    .onMove { store.move(from: $0, to: $1) }
                    .onDelete { store.remove(at: $0) }
            } header: {
                Text("Installed")
            } footer: {
                Text("Add-ons are used from top to bottom. That sets the order of Home rows, search results and sources, so put the ones you prefer first. Switch an add-on off to skip it without removing it. Tap Edit to drag them into order; swipe left to remove one.\n\nThe gear opens an add-on's setup page in your browser. After changing settings there, copy the new add-on link it gives you, add it below, then remove the old one.")
            }

            if !store.addons.isEmpty {
                Section {
                    Button { reloadAll() } label: { Label("Reload all add-ons", systemImage: "arrow.clockwise") }
                        .disabled(!reloading.isEmpty)
                    if let note { Text(note).font(.footnote).foregroundStyle(.secondary) }
                }
            }

            Section {
                TextField("Add-on URL", text: $urlText)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                Button(busy ? "Adding…" : "Add add-on") { add() }
                    .disabled(urlText.isEmpty || busy)
            } header: {
                Text("Add an add-on")
            } footer: {
                if let error { Text(error).foregroundStyle(.red) }
                else { Text("Paste an add-on's manifest link (https:// or stremio://).") }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Add-ons")
        .navigationBarTitleDisplayMode(.inline)
        .scrollDismissesKeyboard(.interactively)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                EditButton().disabled(store.addons.isEmpty)
            }
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") {
                    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                }
            }
        }
    }

    // MARK: Row

    private func row(_ a: Addon) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(a.manifest.name).font(.headline).lineLimit(1)
                if let d = a.manifest.description, !d.isEmpty {
                    Text(d).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                Text(detailLine(a)).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                if a.needsConfiguration {
                    Label("Needs setup", systemImage: "exclamationmark.circle.fill")
                        .font(.caption2.weight(.semibold)).foregroundStyle(.orange)
                }
            }
            .opacity(store.isEnabled(a) ? 1 : 0.45)
            Spacer(minLength: 8)
            if reloading.contains(a.id) { ProgressView() }
            if a.isConfigurable {
                // Borderless so tapping the gear doesn't act on the whole row.
                Button { configure(a) } label: { Image(systemName: "gearshape") }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Configure \(a.manifest.name)")
            }
            Toggle("Use \(a.manifest.name)", isOn: enabledBinding(a)).labelsHidden()
        }
        .swipeActions(edge: .leading) {
            Button { reload(a) } label: { Label("Reload", systemImage: "arrow.clockwise") }.tint(.blue)
            if a.isConfigurable {
                Button { configure(a) } label: { Label("Configure", systemImage: "gearshape") }.tint(.indigo)
            }
        }
        .contextMenu {
            Button { store.setEnabled(a, !store.isEnabled(a)) } label: {
                Label(store.isEnabled(a) ? "Turn off" : "Turn on",
                      systemImage: store.isEnabled(a) ? "pause.circle" : "play.circle")
            }
            // Offered for every add-on: some have a setup page without declaring it in their manifest.
            Button { configure(a) } label: {
                Label(a.isConfigurable ? "Configure" : "Open configuration page", systemImage: "gearshape")
            }
            Button { reload(a) } label: { Label("Reload", systemImage: "arrow.clockwise") }
        }
    }

    /// Version and host only. The full URL is never shown: debrid add-ons embed API keys in it.
    private func detailLine(_ a: Addon) -> String {
        var parts: [String] = []
        if let v = a.manifest.version, !v.isEmpty { parts.append("v\(v)") }
        if let h = a.baseURL.host { parts.append(h) }
        return parts.joined(separator: " · ")
    }

    private func enabledBinding(_ a: Addon) -> Binding<Bool> {
        Binding(get: { store.isEnabled(a) }, set: { store.setEnabled(a, $0) })
    }

    // MARK: Actions

    private func configure(_ a: Addon) { openURL(a.configureURL) }

    private func reload(_ a: Addon) {
        reloading.insert(a.id)
        Task {
            defer { reloading.remove(a.id) }
            do { try await store.reload(a); note = "\(a.manifest.name) reloaded." }
            catch { note = "Couldn't reach \(a.manifest.name)." }
        }
    }

    private func reloadAll() {
        Task {
            reloading = Set(store.addons.map(\.id))
            let failed = await store.reloadAll()
            reloading = []
            note = failed == 0 ? "Add-ons reloaded." : "\(failed) add-on(s) couldn't be reached and were left as they were."
        }
    }

    private func add() {
        Task {
            busy = true; defer { busy = false }
            do { try await store.add(urlText); urlText = ""; error = nil }
            catch { self.error = "Couldn't load that manifest. Check the URL and try again." }
        }
    }
}
