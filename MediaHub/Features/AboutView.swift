import SwiftUI

/// What the app is, and the third-party components and services it relies on, with their licences.
struct AboutView: View {
    static var versionString: String {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0"
        return "v\(v)"
    }

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 10) {
                        Text("Pear.").font(.system(size: 28, weight: .bold, design: .rounded))
                        Text(Self.versionString).font(.footnote).foregroundStyle(.secondary)
                    }
                    Text("Pear. brings what you watch into one place: your library and watch history, trending and Explore pages, recommendations, and the streams from the add-ons you install, all in a native iOS player with Picture in Picture, subtitles and skip-intro buttons. Everything is saved per profile and stays on your device unless you connect a service.")
                        .font(.callout).foregroundStyle(.secondary)
                    Text("Pear. doesn't host, provide or index any media. Sources come only from the add-ons and links you choose to add.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }

            Section {
                component("AetherEngine", role: "Video player engine (FFmpeg demuxing, VideoToolbox decoding).",
                          license: "LGPL, with an App Store exception for the engine's own code",
                          url: "https://github.com/superuser404notfound/AetherEngine")
                component("FFmpeg and codecs", role: "Bundled with AetherEngine as dynamic frameworks. Built without GPL or version-3 options.",
                          license: "FFmpeg LGPL-2.1-or-later · dav1d BSD-2-Clause · zimg WTFPL · libzvbi LGPL-2.0-or-later",
                          url: "https://github.com/superuser404notfound/FFmpegBuild",
                          note: "Pear. uses FFmpeg. Full licence texts and the source of the exact build are in the FFmpegBuild repository.")
                component("librqbit", role: "Rust BitTorrent engine behind optional peer-to-peer streams (off by default).",
                          license: "Apache-2.0",
                          url: "https://github.com/ikatson/rqbit",
                          note: "Also uses UniFFI (MPL-2.0) for the Swift bridge, plus Tokio and Hyper (MIT).")
            } header: { Text("Open-source components") }

            Section {
                component("TMDB", role: "Metadata, posters, trending, recommendations, trailers and logos.",
                          license: "Used under the TMDB API terms of use",
                          url: "https://www.themoviedb.org",
                          note: "This product uses the TMDB API but is not endorsed or certified by TMDB.")
                component("TheTVDB", role: "Extra episode artwork and title logos.",
                          license: "Used under the TheTVDB API terms of use",
                          url: "https://thetvdb.com",
                          note: "Metadata provided by TheTVDB. Pear. is not affiliated with TheTVDB.")
                component("MDBList", role: "IMDb, Rotten Tomatoes, Metacritic and Letterboxd ratings, and your lists.",
                          license: "Used under the MDBList terms of service",
                          url: "https://mdblist.com",
                          note: "Pear. is not affiliated with MDBList.")
                component("Simkl", role: "Sign-in, library, watch history and sync.",
                          license: "Used under the Simkl API terms of use",
                          url: "https://simkl.com",
                          note: "Pear. is not affiliated with or endorsed by Simkl.")
            } header: { Text("Services") } footer: {
                Text("Service names and logos belong to their owners. These services are not open source: they're accessed through their public APIs, under their own terms.")
            }
        }
        .navigationTitle("About")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func component(_ name: String, role: String, license: String, url: String, note: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(name).font(.headline)
            Text(role).font(.subheadline).foregroundStyle(.secondary)
            Text(license).font(.footnote.weight(.semibold))
            if let note { Text(note).font(.footnote).foregroundStyle(.secondary) }
            if let u = URL(string: url) {
                Link(destination: u) { Label(u.host() ?? url, systemImage: "arrow.up.right.square") }
                    .font(.footnote)
            }
        }
        .padding(.vertical, 4)
    }
}
