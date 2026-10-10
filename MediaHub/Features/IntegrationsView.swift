import SwiftUI

/// Every external service in one place: API keys, the Simkl login, and what each one is used for.
struct IntegrationsView: View {
    @Environment(SimklStore.self) private var simkl
    @Environment(MediaServerStore.self) private var servers
    @AppStorage("mdblist.key") private var mdbKey = ""
    @AppStorage("tvdb.key") private var tvdbKey = ""
    @AppStorage("tvdb.pin") private var tvdbPin = ""
    @AppStorage("tmdb.key") private var tmdbKey = ""
    @AppStorage("skip.enabled") private var skipEnabled = true

    var body: some View {
        Form {
            Section {
                SecureField(TMDBClient.hasProxy ? "Your own TMDB key (optional)" : "TMDB API key", text: $tmdbKey)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                status(tmdbKey.isEmpty ? (TMDBClient.hasProxy ? "Built in" : nil) : "Using your key")
            } header: { Text("TMDB") } footer: {
                Text(TMDBClient.hasProxy
                     ? "Metadata, trending, Explore, recommendations, episode thumbnails, title logos and matching skip-intro timestamps. A TMDB key is built in, so you don't need one. If TMDB content ever fails to load, add your own free key from themoviedb.org/settings/api. This product uses the TMDB API but is not endorsed or certified by TMDB."
                     : "Metadata, trending, Explore, recommendations, episode thumbnails, title logos and matching skip-intro timestamps. Free key at themoviedb.org/settings/api. This product uses the TMDB API but is not endorsed or certified by TMDB.")
            }

            Section {
                SecureField("TVDB API key", text: $tvdbKey)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                SecureField("PIN (subscriber keys only)", text: $tvdbPin)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                status(tvdbKey.isEmpty ? nil : "Key set")
            } header: { Text("TheTVDB") } footer: {
                Text("Fills in missing episode thumbnails and title logos. Metadata provided by TheTVDB. Get a key at thetvdb.com/api-information.")
            }

            Section {
                SecureField("MDBList API key", text: $mdbKey)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                if !mdbKey.isEmpty { NavigationLink("Choose lists") { MDBListPicker() } }
                status(mdbKey.isEmpty ? nil : "Key set")
            } header: { Text("MDBList") } footer: {
                Text("IMDb, Rotten Tomatoes, Metacritic and Letterboxd ratings, and your lists on Home. Get a key at mdblist.com/preferences.")
            }

            simklSection

            Section {
                NavigationLink { MediaServersView() } label: {
                    HStack {
                        Label("Media servers", systemImage: "server.rack")
                        Spacer()
                        if !servers.accounts.isEmpty { Text("\(servers.accounts.count)").foregroundStyle(.secondary) }
                    }
                }
            } header: { Text("Jellyfin & Plex") } footer: {
                Text("Play what is already in your own libraries. Matching titles appear as sources on their detail page, and recently added titles can show on Home and in search.")
            }

            Section {
                Toggle("Skip intro, recap and credits", isOn: $skipEnabled)
            } header: { Text("TheIntroDB") } footer: {
                Text("Community-verified timestamps for intros, recaps, credits and previews. No account or key needed; titles are matched through TMDB.")
            }
        }
        .navigationTitle("Integrations")
        .navigationBarTitleDisplayMode(.inline)
        .scrollDismissesKeyboard(.interactively)
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") {
                    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                }
            }
        }
    }

    @ViewBuilder private func status(_ text: String?) -> some View {
        if let text { Label(text, systemImage: "checkmark.circle.fill").font(.footnote).foregroundStyle(.green) }
    }

    // MARK: Simkl (PIN login with MediaHub's own app: nothing to register, works inside LiveContainer)

    private var simklSection: some View {
        Section {
            SimklConnectControls()
        } header: { Text("Simkl") } footer: {
            Text("Tap Connect to Simkl, then enter the code at simkl.com/pin. No account setup, keys or redirects needed. Your library syncs when the app opens and only downloads what changed.")
        }
    }
}
