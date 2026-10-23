import Foundation

@main
enum TVWatchlistPresentationTests {
    static func main() throws {
        let profileA = UUID(), profileB = UUID(), firstA = UUID(), returnedA = UUID()
        let fence = TVWatchlistPresentationFence(owner: "account-a:epoch-1", profileID: profileA, generation: firstA)
        precondition(fence.allows(owner: "account-a:epoch-1", profileID: profileA, generation: firstA, nativeReady: true))
        precondition(!fence.allows(owner: "account-a:epoch-1", profileID: profileA, generation: firstA, nativeReady: false),
                     "A cached roster without native admission is loading, never authoritative empty.")
        precondition(!fence.allows(owner: "account-b:epoch-1", profileID: profileA, generation: firstA, nativeReady: true))
        precondition(!fence.allows(owner: "account-a:epoch-2", profileID: profileA, generation: firstA, nativeReady: true),
                     "A same-account sign-out/sign-in invalidates the old credential epoch.")
        precondition(!fence.allows(owner: "account-a:epoch-1", profileID: profileB, generation: firstA, nativeReady: true))
        precondition(!fence.allows(owner: "account-a:epoch-1", profileID: profileA, generation: returnedA, nativeReady: true),
                     "Profile A -> B -> A cannot publish the first A's suspended read.")
        precondition(!fence.allows(owner: "account-a:epoch-1", profileID: profileB, generation: returnedA, nativeReady: true),
                     "A retained card gesture cannot open profile B's identically keyed title using A's receipt.")
        precondition(!fence.allows(owner: "account-a:epoch-1", profileID: nil, generation: firstA, nativeReady: true))

        // Empty is meaningful only after the same receipt admits the native host read.
        let empty: [String] = []
        let held: [String]? = fence.allows(owner: "account-a:epoch-1", profileID: profileA,
                                           generation: firstA, nativeReady: false) ? empty : nil
        let ready: [String]? = fence.allows(owner: "account-a:epoch-1", profileID: profileA,
                                            generation: firstA, nativeReady: true) ? empty : nil
        precondition(held == nil && ready != nil && ready!.isEmpty)

        let view = try String(contentsOfFile: "app/SourcesTV/TVWatchlistView.swift", encoding: .utf8)
        let library = try String(contentsOfFile: "app/SourcesTV/LibraryView.swift", encoding: .utf8)
        let bridge = try String(contentsOfFile: "app/SourcesShared/CoreBridge.swift", encoding: .utf8)
        precondition(library.contains("NavigationLink { TVWatchlistView() }"))
        precondition(library.contains("TVDownloadsView()") && library.contains("smartFiltered(segmented(library.catalog))"))
        precondition(view.contains("loaded = try core.nativeWatchlist().map"))
        precondition(!view.contains("core.library") && !view.contains("profiles.libraryItems") && !view.contains("continueWatching"),
                     "Saved Library and Continue Watching cannot be unioned into app Watchlist.")
        let nativeRead = bridge.components(separatedBy: "func nativeWatchlist() throws")[1]
            .components(separatedBy: "struct NativeWatchlistTarget")[0]
        precondition(nativeRead.contains("VortxNativeWatchlist.entries(host: snapshot.host, profileID: profile)"),
                     "The destination must read the authoritative native host watchlist projection.")
        let load = view.components(separatedBy: "private func reload()")[1]
            .components(separatedBy: "private func openDetails")[0]
        let admission = load.range(of: "let admission = core.captureNativeWatchlistActionAdmission()")!
        let scheduled = load.range(of: "reloadTask = Task")!
        precondition(admission.lowerBound < scheduled.lowerBound)
        precondition(load.contains("await core.prepareNativeWatchlistActionTarget(admission)"))
        precondition(load.components(separatedBy: "core.nativeWatchlistTargetIsCurrent(prepared)").count == 3,
                     "The admitted native target must remain current on both sides of the host read.")
        precondition(load.contains("guard !Task.isCancelled, isVisible"))
        precondition(load.contains("generation: generation, nativeReady: true)"))
        precondition(view.contains("watchlistChangedNote") && view.contains("credentialScopeDidChangeNote"))
        precondition(view.contains(".onChange(of: profiles.activeID)") && view.contains(".onChange(of: core.revision)"))
        precondition(view.contains("core.nativeNavigationTargetIsCurrent(detailNativeTarget)"))
        precondition(view.contains("menu: .none") && view.contains("openDetails(entry, fence: fence)"),
                     "Watchlist cards retain the guarded detail route without Library mutation menus.")
        let card = view.components(separatedBy: "private func watchlistCard")[1]
            .components(separatedBy: "private func retireNavigationIfNeeded")[0]
        precondition(card.contains("let fence = displayedFence") && card.contains("let navigation = displayedNativeTarget"))
        precondition(card.contains("fence.allows(owner: CredentialScopeRegistry.shared.capture()"))
        precondition(!view.contains("removeFromLibrary") && !view.contains("setNativeWatchlist"))
        precondition(view.contains("Button { dismiss() }") && view.contains("DetailView(type: detail.type, id: detail.id)"))
        precondition(view.contains("var tvWatchlistIdentity: String { type + \":\" + id }"))
        print("PASS TV Watchlist: current native admission, held versus empty, account/profile/request ABA fences, authoritative host-only rows, notification reloads, typed card identity, guarded detail and Back route")
    }
}
