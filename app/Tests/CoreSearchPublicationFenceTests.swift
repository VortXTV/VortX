import Foundation

@main enum CoreSearchPublicationFenceTests {
    static func main() {
        let fence = CoreSearchPublicationFence()
        let old = fence.prepare("  first  ").token
        precondition(fence.capture(query: "first") == old)
        precondition(fence.capture(query: "other") == nil)
        precondition(!fence.prepare("first").changed)
        let replacement = fence.prepare("second").token
        precondition(!fence.accepts(old) && fence.accepts(replacement))
        precondition(fence.capture(query: "first") == nil) // before the new debounce dispatch
        let repeated = fence.prepare("first").token
        precondition(repeated != old && !fence.accepts(old)) // queued A cannot survive A -> B -> A
        _ = fence.prepare("")
        precondition(!fence.accepts(repeated) && fence.capture(query: nil) == nil)
        _ = fence.prepare("x")
        precondition(fence.capture(query: "x") == nil)
        let owner = fence.prepare("owner query").token
        fence.invalidate()
        precondition(!fence.accepts(owner) && fence.capture(query: "owner query") != owner)
        print("PASS search publication: trim, debounce gap, stale query, ABA, cleared/short text and owner reset")
    }
}
