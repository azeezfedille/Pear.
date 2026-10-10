import SwiftUI

/// "Connect to Simkl" with PIN login. One control, used by Integrations and by the Simkl page under "View profile".
/// MediaHub ships its own Simkl app, so nobody has to register one: tap Connect, enter the code on simkl.com/pin.
struct SimklConnectControls: View {
    @Environment(SimklStore.self) private var simkl
    @Environment(ThemeStore.self) private var theme
    @Environment(\.openURL) private var openURL
    /// On the Profile page: connected state is a status line + sync, with Disconnect left to Integrations.
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if simkl.isConnected {
                Label("Connected to Simkl", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    .font(compact ? .subheadline.weight(.semibold) : .body)
                if let e = simkl.syncError {
                    Label(e, systemImage: "exclamationmark.triangle.fill").font(.footnote).foregroundStyle(.orange)
                }
                HStack(spacing: 16) {
                    Button(simkl.isSyncing ? "Syncing…" : "Sync now") { Task { await simkl.sync(force: true) } }
                        .disabled(simkl.isSyncing)
                    if !compact { Button("Disconnect", role: .destructive) { simkl.disconnect() } }
                }
                .font(.subheadline)
            } else if let pin = simkl.pin {
                pinSteps(pin)
            } else {
                Button { simkl.connect() } label: {
                    Label("Connect to Simkl", systemImage: "link").font(.body.weight(.semibold))
                        .foregroundStyle(theme.onAccent)
                        .frame(maxWidth: compact ? .infinity : nil)
                }
                .buttonStyle(.borderedProminent)
                if let s = simkl.loginStatus { Text(s).font(.footnote).foregroundStyle(.secondary) }
            }
            if let e = simkl.loginError {
                Label(e, systemImage: "xmark.octagon.fill").font(.footnote).foregroundStyle(.red)
            }
        }
    }

    private func pinSteps(_ pin: DeviceAuthorization) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("1. Open this page on any device").font(.footnote).foregroundStyle(.secondary)
            if let u = URL(string: pin.verificationUrl) {
                Link(pin.verificationUrl, destination: u).font(.subheadline.weight(.semibold))
            } else { Text(pin.verificationUrl).font(.subheadline.weight(.semibold)) }
            Text("2. Enter this code").font(.footnote).foregroundStyle(.secondary)
            HStack {
                Text(pin.userCode).font(.system(size: 34, weight: .bold, design: .monospaced)).textSelection(.enabled)
                Spacer()
                Button { UIPasteboard.general.string = pin.userCode } label: { Image(systemName: "doc.on.doc") }
                    .buttonStyle(.borderless)
            }
            if let u = pin.completeURL ?? URL(string: pin.verificationUrl) {
                Button { openURL(u) } label: { Label("Open Simkl", systemImage: "safari") }
                    .buttonStyle(.bordered).font(.subheadline)
            }
            HStack(spacing: 8) {
                ProgressView()
                Text(simkl.loginStatus ?? "Waiting for authorisation…").font(.footnote).foregroundStyle(.secondary)
            }
            Button("Cancel", role: .cancel) { simkl.cancelLogin() }.font(.footnote)
        }
        .padding(.vertical, 4)
    }
}


/// The Simkl login as a page of its own, reached from "Simkl" under "View profile" in the profile sheet.
struct SimklLoginPage: View {
    @Environment(SimklStore.self) private var simkl

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                SimklConnectControls()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
                    .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                Text("Tap Connect to Simkl, then enter the code at simkl.com/pin. No account setup, keys or redirects needed. Your library syncs when the app opens and only downloads what changed.")
                    .font(.footnote).foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
            }
            .padding(16)
        }
        .scrollIndicators(.hidden)
        .navigationTitle("Simkl")
        .navigationBarTitleDisplayMode(.inline)
    }
}
