import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// The system share sheet: route a captured stream URL to any app that accepts a video URL (or
/// Copy / AirDrop), the universal fallback when no first-class external player is detected. iOS
/// wraps UIActivityViewController; macOS wraps NSSharingServicePicker.
#if canImport(UIKit)
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
#elseif canImport(AppKit)
struct ShareSheet: NSViewRepresentable {
    let items: [Any]

    func makeNSView(context: Context) -> NSView {
        let host = NSView()
        // Present the picker once the host view is in a window.
        DispatchQueue.main.async {
            guard host.window != nil else { return }
            NSSharingServicePicker(items: items).show(relativeTo: host.bounds, of: host, preferredEdge: .minY)
        }
        return host
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
#endif
