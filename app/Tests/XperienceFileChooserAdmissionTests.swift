// Foundation admission tests; no native store or SwiftUI success is simulated.
// Compile this file together with app/SourcesShared/XperienceFileChooserAdmission.swift.
import Foundation

@main
private enum XperienceFileChooserAdmissionTests {
    static func main() {
        var failures = 0
        func require(_ condition: @autoclosure () -> Bool, _ message: String) {
            if condition() { print("PASS  \(message)") }
            else { failures += 1; print("FAIL  \(message)") }
        }
        let generationA = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let generationB = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let forged = XperienceFileChooserAdmission.Ticket(id: UUID(), generation: generationA)
        var admission = XperienceFileChooserAdmission()

        require(!admission.admit(forged, currentGeneration: generationA), "a read requires prior chooser activation")
        require(!admission.permitsPublication(forged, currentGeneration: generationA), "an inactive ticket cannot publish")
        let first = admission.begin(generation: generationA)
        require(!admission.permitsPublication(first, currentGeneration: generationA), "choosing is not reading")
        require(!admission.admit(first, currentGeneration: generationB), "a generation mismatch cannot admit")
        require(admission.admit(first, currentGeneration: generationA), "the exact activated ticket admits once")
        require(!admission.admit(first, currentGeneration: generationA), "duplicate success cannot schedule another read")
        require(admission.permitsPublication(first, currentGeneration: generationA), "the admitted original ticket can publish")
        require(!admission.permitsPublication(first, currentGeneration: generationB), "publication retains the original generation")
        require(admission.finish(first, currentGeneration: generationA), "read completion consumes its publication authority")
        require(!admission.permitsPublication(first, currentGeneration: generationA), "finished tickets cannot publish again")

        let oldA = admission.begin(generation: generationA)
        admission.invalidate()
        require(!admission.admit(oldA, currentGeneration: generationA), "disappearance invalidates an outstanding chooser")
        let intermediateB = admission.begin(generation: generationB)
        let currentA = admission.begin(generation: generationA)
        require(currentA.id != oldA.id, "returning to the same generation creates a new presentation identity")
        require(!admission.admit(oldA, currentGeneration: generationA), "A to B to A cannot resurrect an old success")
        require(!admission.cancel(oldA, currentGeneration: generationA), "an old failure cannot cancel a successor chooser")
        require(!admission.admit(intermediateB, currentGeneration: generationA), "the intermediate chooser also stays retired")
        require(admission.admit(currentA, currentGeneration: generationA), "the current A chooser remains usable")
        require(!admission.cancel(oldA, currentGeneration: generationA), "old cancellation cannot cancel a successor read")
        require(admission.permitsPublication(currentA, currentGeneration: generationA), "old failure leaves successor publication intact")
        admission.invalidate()
        require(!admission.permitsPublication(currentA, currentGeneration: generationA), "retirement revokes an already admitted read")
        require(!admission.finish(currentA, currentGeneration: generationA), "late completion cannot finish after retirement")

        let canceled = admission.begin(generation: generationB)
        require(admission.cancel(canceled, currentGeneration: generationB), "matching cancellation consumes the chooser")
        require(!admission.admit(canceled, currentGeneration: generationB), "a canceled chooser success cannot be admitted")
        require(!admission.cancel(canceled, currentGeneration: generationB), "duplicate cancellation is inert")

        if failures > 0 {
            FileHandle.standardError.write(Data("\n\(failures) chooser admission failure(s)\n".utf8))
            exit(1)
        }
        print("\nALL PASS")
    }
}
