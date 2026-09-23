import SwiftUI

// App shell only — all real behavior lives behind ContentView (UI layer)
// and Headless (data layer). Keep this file boring; it is the integration
// point both build agents converge on, so churn here breaks two people.
@main
struct BookmarkBizarreApp: App {

    @StateObject private var manager = LibraryManager()

    init() {
        // CLI smoke-test path: `BookmarkBizarre --import file.html` runs the
        // whole import pipeline and exits before any window exists. Must be
        // first so a headless run never pays for (or flashes) the UI.
        Headless.runIfNeeded()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(manager)
                .frame(minWidth: 960, minHeight: 620)
        }

        Settings {
            SettingsView()
        }
    }
}

/// One setting for now: where the VPN client lives. Stored as a plain path
/// in UserDefaults (BMZ.vpnClientPathKey) — the grid consults it when a
/// requires_vpn bookmark is opened.
struct SettingsView: View {
    @AppStorage(BMZ.vpnClientPathKey) private var vpnClientPath = ""

    var body: some View {
        Form {
            Section("VPN") {
                TextField("VPN client app path", text: $vpnClientPath,
                          prompt: Text("/Applications/Your VPN Client.app"))
                    .frame(width: 380)
                Text("Launched before opening any bookmark flagged as VPN-required. Leave empty to just open the page.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(20)
        .frame(width: 480)
    }
}
