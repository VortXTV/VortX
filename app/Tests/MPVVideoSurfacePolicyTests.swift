import Foundation
import CoreGraphics

@main
enum MPVVideoSurfacePolicyTests {
    static func main() throws {
        var checks = 0
        func check(_ value: Bool, _ name: String) {
            precondition(value, name)
            checks += 1
            print("PASS \(name)")
        }
        for (bounds, scale) in [(CGSize(width: 1920, height: 1080), CGFloat(2)),
                                (CGSize(width: 390, height: 844), CGFloat(3)),
                                (CGSize(width: 960, height: 540), CGFloat(2))] {
            var policy = MPVVideoSurfacePolicy()
            check(policy.prepare(bounds: bounds, scale: scale) ==
                  CGSize(width: bounds.width * scale, height: bounds.height * scale), "pin valid pixels before init")
            check(!policy.consumeInitialRebuild(), "valid first layout never disables video")
            check(!policy.consumeInitialRebuild(), "repeat layout never disables video")
        }
        for bounds in [CGSize.zero, CGSize(width: 1, height: 100),
                       CGSize(width: CGFloat.infinity, height: 100), CGSize(width: CGFloat.nan, height: 100)] {
            var policy = MPVVideoSurfacePolicy()
            check(policy.prepare(bounds: bounds, scale: 2) == nil, "reject invalid surface")
            check(policy.consumeInitialRebuild(), "retain zero-size preview recovery")
            check(!policy.consumeInitialRebuild(), "zero-size preview recovery runs only once")
        }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("Sources/Player/MPVMetalViewController.swift"), encoding: .utf8)
        let prepare = source.range(of: "initialVideoSurface.prepare(")!
        let initCall = source.range(of: "        setupMpv()")!
        check(prepare.lowerBound < initCall.lowerBound, "pin actual drawable before mpv init and initial load")
        check(source.contains("if initialVideoSurface.consumeInitialRebuild()"), "runtime uses tested gate")
        check(!source.contains("didBuildInitialVideoOutput = false"), "scale change cannot re-arm destructive startup reset")
        print("MPVVideoSurfacePolicyTests: \(checks) passed")
    }
}
