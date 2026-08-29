// Focused executable harness for inline drawable capture format admission.
//
//   xcrun swiftc -swift-version 5 -strict-concurrency=complete -suppress-warnings \
//     -target arm64-apple-macos14.0 -sdk "$(xcrun --sdk macosx --show-sdk-path)" \
//     -o .lane-build/previews-subtitles/metal-capture-pixel-format-tests \
//     app/Sources/Player/MetalLayer.swift app/Tests/MetalCapturePixelFormatPolicyTests.swift \
//     && .lane-build/previews-subtitles/metal-capture-pixel-format-tests

import Metal
import MetalPerformanceShaders

@main
private enum MetalCapturePixelFormatPolicyTests {
    static func main() {
        let hdrAndWideFormats: [MTLPixelFormat] = [
            .rgb10a2Unorm, .bgr10a2Unorm, .bgra10_xr, .bgra10_xr_srgb, .rgba16Float
        ]
        precondition(
            hdrAndWideFormats.allSatisfy(MetalLayer.inlineDrawableCapturePixelFormatAllowed),
            "MoltenVK HDR and wide-color drawable formats must remain capturable"
        )
        precondition(
            MetalLayer.inlineDrawableCapturePixelFormatAllowed(.bgra8Unorm),
            "the SDR capture path must remain admitted"
        )
        precondition(
            !MetalLayer.inlineDrawableCapturePixelFormatAllowed(.r8Unorm),
            "an unvetted drawable format must fail closed"
        )
        validateCaptureScale(formats: hdrAndWideFormats)
        print("Metal capture pixel-format policy: PASS")
    }

    private static func validateCaptureScale(formats: [MTLPixelFormat]) {
        guard let device = MTLCreateSystemDefaultDevice(), device.supportsFamily(.apple3),
              let queue = device.makeCommandQueue() else {
            print("Metal capture pixel-format scale proof: SKIP (Apple3+ Metal device unavailable)")
            return
        }
        let scaler = MPSImageBilinearScale(device: device)
        for format in formats {
            let sourceDescriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: format,
                width: 64,
                height: 36,
                mipmapped: false
            )
            sourceDescriptor.usage = [.shaderRead]
            sourceDescriptor.storageMode = .private
            let destinationDescriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: format,
                width: 32,
                height: 18,
                mipmapped: false
            )
            destinationDescriptor.usage = [.shaderRead, .shaderWrite]
            destinationDescriptor.storageMode = .shared
            guard let source = device.makeTexture(descriptor: sourceDescriptor),
                  let destination = device.makeTexture(descriptor: destinationDescriptor),
                  let commandBuffer = queue.makeCommandBuffer() else {
                preconditionFailure("capture textures must allocate for pixel format \(format.rawValue)")
            }
            scaler.encode(
                commandBuffer: commandBuffer,
                sourceTexture: source,
                destinationTexture: destination
            )
            commandBuffer.commit()
            commandBuffer.waitUntilCompleted()
            precondition(
                commandBuffer.status == .completed,
                "MPS capture scale must complete for pixel format \(format.rawValue)"
            )
        }
        print("Metal capture pixel-format scale proof: PASS (\(formats.count) formats)")
    }
}
