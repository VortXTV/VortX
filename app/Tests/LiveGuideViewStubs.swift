import SwiftUI

// Extra signature stubs for scripts/test-live-guide-views.sh, on top of ForYouViewStubs.swift and
// NetworkShareViewStubs.swift. Each mirrors the real declaration's name and shape; behavior is irrelevant.

extension Theme.Palette { static let surface1 = Color.gray }

enum VortXEdgeAuth { static func sign(_ request: inout URLRequest) {} }

struct CoreMeta: Identifiable {
    let id: String
    let type: String
    let name: String
    let poster: String?
    let logo: String?
}

struct CoreBoardRow: Identifiable {
    let id: String
    let title: String
    let type: String
    let items: [CoreMeta]
    let engineIndex: Int
}

#if os(tvOS)
struct DetailView: View {
    let type: String
    let id: String
    var body: some View { Text(id) }
}
#endif
