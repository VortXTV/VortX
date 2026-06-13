import SwiftUI

/// Native iOS root. Scaffold during the 0.3.0 iOS rebase: it stands up the bottom TabView shell
/// (the real surfaces fill in one at a time) and an engine status panel that doubles as the FFI
/// smoke check, so each build proves the shared engine boots and runs on iOS before a screen is
/// ported onto it.
struct iOSRootView: View {
    @EnvironmentObject private var account: StremioAccount
    @EnvironmentObject private var core: CoreBridge

    var body: some View {
        TabView {
            engineStatus
                .tabItem { Label("Home", systemImage: "house.fill") }
            Text("Discover").tabItem { Label("Discover", systemImage: "safari.fill") }
            Text("Library").tabItem { Label("Library", systemImage: "books.vertical.fill") }
            Text("Search").tabItem { Label("Search", systemImage: "magnifyingglass") }
            Text("Settings").tabItem { Label("Settings", systemImage: "gearshape.fill") }
        }
    }

    /// Engine + account status. Real Home rails replace this once the shared CoreBridge data is
    /// wired into a touch grid; for now it confirms the engine is live on iOS.
    private var engineStatus: some View {
        NavigationStack {
            List {
                Section("Engine") {
                    LabeledContent("stremio-core schema", value: "\(core.schemaVersion)")
                    LabeledContent("Account", value: account.isSignedIn ? (account.email ?? "Signed in") : "Signed out")
                    LabeledContent("Home rows", value: "\(core.boardRows.count)")
                    LabeledContent("Continue Watching", value: "\(core.continueWatching.count)")
                }
                if !core.boardRows.isEmpty {
                    Section("Catalogs") {
                        ForEach(core.boardRows.prefix(20)) { row in
                            Text(row.title)
                        }
                    }
                }
            }
            .navigationTitle("StremioX")
        }
    }
}
