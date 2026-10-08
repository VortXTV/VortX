import Combine
import Foundation

#if CINEMA_UI_SMOKE_RENDERER
/// Compile-only replacement for the dormant community-provider contributor.
///
/// The isolated renderer deliberately excludes the QuickJS C interpreter and its network-capable runtime.
/// `SourceIndexClient` and `SourceListModel` still name this optional contributor in their public signatures,
/// so this inert equivalent preserves those signatures without ever constructing `JSProviderStore`, loading
/// cached providers, or opening a network path. The fixture never supplies one; its values remain empty.
@MainActor
final class JSProviderSource: ObservableObject {
    @Published private(set) var groups: [CoreStreamSourceGroup] = []
    @Published private(set) var settlementEpoch = 0
    private(set) var epoch = 0
    private(set) var publishedTarget: SourceIndexIdentity.PublicationTarget?

    init() {
        preconditionFailure("Cinema UI renderer must not construct JSProviderSource")
    }

    func refresh(call: AuxiliarySourcePipeline.Call) {
        preconditionFailure("Cinema UI renderer must not refresh JSProviderSource")
    }

    func settlementState(for resolution: SourceIndexIdentity.TargetResolution) -> SourceContributorSettlement {
        preconditionFailure("Cinema UI renderer must not query JSProviderSource")
    }

    func merged(
        into groups: [CoreStreamSourceGroup],
        call: AuxiliarySourcePipeline.Call
    ) -> [CoreStreamSourceGroup] {
        preconditionFailure("Cinema UI renderer must not merge an instance JSProviderSource")
    }

    nonisolated static func merge(
        authorizedBy authorization: SourceIndexIdentity.MergeAuthorization?,
        _ extra: [CoreStreamSourceGroup],
        into groups: [CoreStreamSourceGroup]
    ) -> [CoreStreamSourceGroup] {
        groups
    }
}
#endif
