import Combine
import SwiftUI

// Signature stubs for scripts/test-for-you-views.sh. Each mirrors the real declaration the For You
// sources call (same names, labels, defaults and isolation), so the real views and store are type
// checked per platform SDK without building the app. Behavior is irrelevant here; only shapes matter.

final class ThemeManager: ObservableObject {}

enum Theme {
    enum Space {
        static let xs: CGFloat = 8, sm: CGFloat = 12, md: CGFloat = 20, lg: CGFloat = 32, xl: CGFloat = 48, xxl: CGFloat = 72
        static let screenEdge: CGFloat = 60
        static let screenInset: CGFloat = 20
        static let readableColumn: CGFloat = 760
    }
    enum Radius { static let card: CGFloat = 18 }
    enum Typography {
        static var sectionTitle: Font { .title2 }
        static var cardTitle: Font { .headline }
        static var body: Font { .body }
        static var label: Font { .caption }
    }
    enum Palette {
        static var canvas: Color { .black }
        static let textPrimary = Color.white, textSecondary = Color.gray, textTertiary = Color.gray
        static var accent: Color { .orange }
        static let danger = Color.red
    }
}

extension View {
    func eyebrowStyle(_ color: Color = Theme.Palette.textTertiary) -> some View { foregroundStyle(color) }
    func sectionTitleStyle() -> some View { font(Theme.Typography.sectionTitle) }
    func screenTitleStyle() -> some View { font(.largeTitle) }
    func vortxSettingsCard() -> some View { background(Color.gray) }
    func vortxCardButton(radius: CGFloat = Theme.Radius.card, accent: Color = Theme.Palette.accent) -> some View { buttonStyle(.bordered) }
}

struct ChipButtonStyle: ButtonStyle {
    var selected: Bool = false
    var profileTinted: Bool = false
    var accent: Color = Theme.Palette.accent
    var accentText: Color = Theme.Palette.accent
    func makeBody(configuration: Configuration) -> some View { configuration.label }
}

struct MetaPreview: Identifiable, Decodable, Hashable {
    let id: String
    let type: String
    let name: String
    let poster: String?
    let posterShape: String?
    let popularity: Double?
}

enum TMDBClient {
    struct PersonResult: Hashable, Identifiable, Sendable {
        let id: Int
        let name: String
        let profileURL: String?
        let department: String?
    }
    static func searchPeople(query: String, limit: Int = 20) async -> [PersonResult] { [] }
    static func ruleTitles(movieQuery: String?, tvQuery: String?, limit: Int = 20) async -> [MetaPreview] { [] }
    static func personTopTitles(id: Int, limit: Int = 20) async -> [MetaPreview] { [] }
}

struct UserProfile { var isKids = false }

final class ProfileStore: ObservableObject {
    static let shared = ProfileStore()
    @Published private(set) var activeID: UUID?
    var active: UserProfile? { nil }
}

@MainActor
final class VortXSyncManager: ObservableObject {
    static let shared = VortXSyncManager()
    @Published private(set) var isSignedIn = false
    static let credentialScopeDidChangeNote = Notification.Name("vortx.credentialScopeDidChange")
}

enum LibraryAutoAdd { static let watchlistChangedNote = Notification.Name("vortx.watchlistChanged") }

final class WatchedIndex: ObservableObject {
    static let shared = WatchedIndex()
    @Published private(set) var ids: Set<String> = []
}

#if VORTX_NATIVE_DATA_ENGINE
final class CoreBridge: ObservableObject {
    static let shared = CoreBridge()
    struct NativeWatchlistTarget {}
    struct NativeWatchlistActionAdmission {}
    @MainActor func nativeForYou() throws -> (profileID: UUID, interests: ForYouInterests?, collections: [SmartCollection]) {
        throw VortxNativeError.closed
    }
    @MainActor func captureNativeWatchlistActionAdmission() -> NativeWatchlistActionAdmission { .init() }
    @MainActor func prepareNativeWatchlistActionTarget(_ admission: NativeWatchlistActionAdmission) async -> NativeWatchlistTarget? { nil }
    @MainActor func setNativeForYouField(_ field: String, value: VortxJSON, target: NativeWatchlistTarget) async throws {}
    @MainActor func nativeWatchlistActionAdmissionIsCurrent(_ admission: NativeWatchlistActionAdmission) -> Bool { false }
    // Signature stand-ins for the native curation path (real bodies live in CoreBridge.swift).
    static let xperienceContextChangedNote = Notification.Name("vortx.xperienceContextChanged")
    struct NativeXperienceTarget {}
    struct XperiencePreparedExport {}
    @MainActor func captureNativeXperienceTarget() throws -> NativeXperienceTarget { throw VortxNativeError.closed }
    @MainActor func retireNativeXperienceTarget(_ target: NativeXperienceTarget) {}
    @MainActor func nativeXperienceTargetIsCurrent(_ target: NativeXperienceTarget) -> Bool { false }
    @MainActor func nativeCurationRegisters(target: NativeXperienceTarget) throws -> [String: VortxJSON] { [:] }
    @MainActor func prepareNativeXperienceExportBudget(target: NativeXperienceTarget) async throws -> XperiencePreparedExport { .init() }
    @MainActor func saveNativeCuration(_ edit: CurationNativeEdit, target: NativeXperienceTarget,
                                      validator: XperiencePreparedExport) async throws -> VortxJSON { .null }
    @MainActor func saveNativeLegacyCuration(_ edit: VortxNativeHostFieldEdit, target: NativeXperienceTarget,
                                            validator: XperiencePreparedExport) async throws -> VortxJSON { .null }
}
#endif

#if os(tvOS)
final class FocusedItemModel: ObservableObject {}
final class FocusedItemOwner: ObservableObject { let model = FocusedItemModel() }
enum PosterMenu { case none, catalog }
struct PosterCard: View {
    let title: String
    let poster: String?
    let type: String
    let id: String
    var isWatched: Bool = false
    var menu: PosterMenu = .none
    var onFocus: (() -> Void)? = nil
    var onDetails: (() -> Void)? = nil
    var body: some View { Text(title) }
}
struct RailHeader: View {
    var eyebrow: String? = nil
    let title: String
    var body: some View { Text(title) }
}
struct ExternalWatchlistRow: View {
    let eyebrow: String
    let title: String
    let items: [MetaPreview]
    var focusModel: FocusedItemModel? = nil
    var body: some View { Text(title) }
}
#endif

#if os(iOS)
struct RailItem: Identifiable {
    let id: String
    let type: String
    let name: String
    let poster: String?
    let progress: Double
}
struct PosterRail: View {
    let title: String
    var eyebrow: String? = nil
    let items: [RailItem]
    let onTap: (RailItem) -> Void
    var showWatchedBadges: Bool = false
    var body: some View { Text(title) }
}
#endif
