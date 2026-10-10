import SwiftUI

private func serverMessage(_ error: Error) -> String {
    if let e = error as? ServerError, let text = e.errorDescription { return text }
    if error is URLError { return ServerError.unreachable.errorDescription ?? error.localizedDescription }
    return error.localizedDescription
}

// MARK: - List

/// Settings -> Integrations -> Media servers.
struct MediaServersView: View {
    @Environment(MediaServerStore.self) private var servers

    var body: some View {
        List {
            Section {
                ForEach(servers.accounts) { account in row(account) }
                    .onDelete { offsets in
                        let ids = offsets.map { servers.accounts[$0].id }
                        ids.forEach { servers.remove($0) }
                    }
                NavigationLink { AddJellyfinView() } label: { Label("Add Jellyfin server", systemImage: "plus.circle") }
                NavigationLink { AddPlexView() } label: { Label("Add Plex account", systemImage: "plus.circle") }
            } header: { Text("Servers") } footer: {
                Text("Titles in your own libraries show up as sources, ahead of your add-ons, whenever you open a movie or episode they have. Switch a server off to stop using it without signing out; touch and hold it to hide its rows from Home or remove it.")
            }
        }
        .navigationTitle("Media servers")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func row(_ a: MediaServerAccount) -> some View {
        HStack(spacing: 12) {
            Image(systemName: a.kind.symbol).frame(width: 28).foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(a.name).font(.body.weight(.semibold))
                Text(a.kind == .plex ? "Plex" : "Jellyfin · \(a.host)").font(.footnote).foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("Use \(a.name)", isOn: Binding(get: { a.enabled }, set: { servers.setEnabled(a.id, $0) })).labelsHidden()
        }
        .contextMenu {
            Button { servers.setShowOnHome(a.id, !a.showOnHome) } label: {
                Label(a.showOnHome ? "Hide from Home" : "Show on Home", systemImage: a.showOnHome ? "eye.slash" : "eye")
            }
            Button(role: .destructive) { servers.remove(a.id) } label: { Label("Remove", systemImage: "trash") }
        }
    }
}

// MARK: - Jellyfin

struct AddJellyfinView: View {
    @Environment(MediaServerStore.self) private var servers
    @Environment(ThemeStore.self) private var theme
    @Environment(\.dismiss) private var dismiss
    @State private var address = ""
    @State private var user = ""
    @State private var password = ""
    @State private var busy = false
    @State private var error: String?
    @State private var quick: JellyfinAPI.QuickConnect?
    @State private var task: Task<Void, Never>?

    var body: some View {
        Form {
            Section {
                TextField("Server address", text: $address)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
            } header: { Text("Server") } footer: {
                Text("For example 192.168.1.20:8096 or jellyfin.example.com.")
            }

            if let quick {
                Section {
                    Text(quick.code).font(.system(size: 34, weight: .bold, design: .monospaced)).textSelection(.enabled)
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("Waiting for approval…").font(.footnote).foregroundStyle(.secondary)
                    }
                    Button("Cancel", role: .cancel) { cancel() }
                } header: { Text("Quick Connect") } footer: {
                    Text("On a device that is already signed in to Jellyfin, open the user menu, choose Quick Connect and enter this code.")
                }
            } else {
                Section {
                    TextField("Username", text: $user).textInputAutocapitalization(.never).autocorrectionDisabled()
                    SecureField("Password", text: $password)
                    Button { signIn() } label: {
                        Text(busy ? "Signing in…" : "Sign in").font(.body.weight(.semibold)).foregroundStyle(theme.onAccent)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(busy || address.isEmpty || user.isEmpty)
                } header: { Text("Account") }

                Section {
                    Button("Use Quick Connect instead") { startQuickConnect() }.disabled(busy || address.isEmpty)
                } footer: {
                    Text("No password needed; you approve the sign-in from another device. Quick Connect has to be switched on in the server's dashboard.")
                }
            }

            if let error {
                Section { Label(error, systemImage: "xmark.octagon.fill").font(.footnote).foregroundStyle(.red) }
            }
        }
        .navigationTitle("Jellyfin")
        .navigationBarTitleDisplayMode(.inline)
        .scrollDismissesKeyboard(.interactively)
        .onDisappear { task?.cancel() }
    }

    private func cancel() {
        task?.cancel()
        quick = nil
        busy = false
    }

    private func signIn() {
        guard !busy else { return }
        busy = true; error = nil
        task = Task {
            defer { busy = false }
            do {
                let (base, info) = try await JellyfinAPI.probe(address)
                let session = try await JellyfinAPI.signIn(base: base, username: user.trimmingCharacters(in: .whitespaces), password: password)
                servers.addJellyfin(name: info.name, base: base, session: session)
                dismiss()
            } catch is CancellationError {
            } catch { self.error = serverMessage(error) }
        }
    }

    private func startQuickConnect() {
        guard !busy else { return }
        busy = true; error = nil
        task = Task {
            defer { busy = false; quick = nil }
            do {
                let (base, info) = try await JellyfinAPI.probe(address)
                let code = try await JellyfinAPI.quickConnectStart(base: base)
                quick = code
                // Two seconds apart, for up to five minutes.
                for _ in 0..<150 {
                    try await Task.sleep(for: .seconds(2))
                    if try await JellyfinAPI.quickConnectCheck(base: base, secret: code.secret) {
                        let session = try await JellyfinAPI.quickConnectFinish(base: base, secret: code.secret)
                        servers.addJellyfin(name: info.name, base: base, session: session)
                        dismiss()
                        return
                    }
                }
                self.error = "Quick Connect timed out. Try again."
            } catch is CancellationError {
            } catch { self.error = serverMessage(error) }
        }
    }
}

// MARK: - Plex

struct AddPlexView: View {
    @Environment(MediaServerStore.self) private var servers
    @Environment(ThemeStore.self) private var theme
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var pin: PlexAPI.Pin?
    @State private var accountToken: String?
    @State private var found: [PlexAPI.ServerInfo] = []
    @State private var selected: Set<String> = []
    @State private var busy = false
    @State private var error: String?
    @State private var task: Task<Void, Never>?

    var body: some View {
        Form {
            if accountToken == nil {
                signInSection
            } else {
                serverSection
            }
            if let error {
                Section { Label(error, systemImage: "xmark.octagon.fill").font(.footnote).foregroundStyle(.red) }
            }
        }
        .navigationTitle("Plex")
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear { task?.cancel() }
    }

    private var signInSection: some View {
        Section {
            if let pin {
                Text(pin.code).font(.system(size: 34, weight: .bold, design: .monospaced)).textSelection(.enabled)
                if let url = pin.authURL {
                    Button { openURL(url) } label: { Label("Open Plex", systemImage: "safari") }.buttonStyle(.bordered)
                }
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Waiting for you to sign in…").font(.footnote).foregroundStyle(.secondary)
                }
                Button("Cancel", role: .cancel) { task?.cancel(); self.pin = nil; busy = false }
            } else {
                Button { signIn() } label: {
                    Label(busy ? "Starting…" : "Sign in with Plex", systemImage: "link").font(.body.weight(.semibold))
                        .foregroundStyle(theme.onAccent)
                }
                .buttonStyle(.borderedProminent)
                .disabled(busy)
            }
        } header: { Text("Account") } footer: {
            Text("You sign in on Plex's own page, so your password never goes through this app. Come back here afterwards and your servers are listed.")
        }
    }

    private var serverSection: some View {
        Section {
            if found.isEmpty {
                Text("This account has no Plex servers.").foregroundStyle(.secondary)
            }
            ForEach(found) { s in
                Toggle(isOn: Binding(get: { selected.contains(s.id) },
                                     set: { on in if on { selected.insert(s.id) } else { selected.remove(s.id) } })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(s.name).font(.body.weight(.semibold))
                        Text(s.owned ? "Yours" : "Shared with you").font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
            if !found.isEmpty {
                Button { addSelected() } label: {
                    Text(busy ? "Connecting…" : "Add selected").font(.body.weight(.semibold)).foregroundStyle(theme.onAccent)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(busy || selected.isEmpty)
            }
        } header: { Text("Servers") }
    }

    private func signIn() {
        guard !busy else { return }
        busy = true; error = nil
        task = Task {
            defer { busy = false; pin = nil }
            do {
                let p = try await PlexAPI.createPin()
                pin = p
                if let url = p.authURL { openURL(url) }
                // Two seconds apart, for up to ten minutes.
                for _ in 0..<300 {
                    try await Task.sleep(for: .seconds(2))
                    var token: String?
                    do { token = try await PlexAPI.checkPin(p) }
                    catch ServerError.expired { throw ServerError.expired }
                    catch is CancellationError { throw CancellationError() }
                    catch { token = nil }               // a dropped connection mid-wait: keep polling
                    if let token {
                        accountToken = token
                        found = try await PlexAPI.servers(token: token)
                        selected = Set(found.map(\.id))
                        return
                    }
                }
                self.error = "Sign-in timed out. Try again."
            } catch is CancellationError {
            } catch { self.error = serverMessage(error) }
        }
    }

    private func addSelected() {
        guard let accountToken, !busy else { return }
        busy = true; error = nil
        task = Task {
            defer { busy = false }
            var failed: [String] = []
            for s in found where selected.contains(s.id) {
                let ranked = s.connections.sorted(by: PlexAPI.preferred)
                guard let best = await PlexAPI.reachable(ranked).first else { failed.append(s.name); continue }
                servers.addPlex(name: s.name, serverID: s.id, base: best.uri,
                                alternates: ranked.map(\.uri).filter { $0 != best.uri },
                                token: s.token ?? accountToken)
            }
            if failed.isEmpty { dismiss() }
            else { error = "Couldn't reach \(failed.joined(separator: ", ")). Check that the server is on and try again." }
        }
    }
}
