import SwiftUI
import UIKit

/// Thin SwiftUI wrapper around `UIActivityViewController`, the system share sheet. Used to route a
/// captured stream URL to any installed app that accepts a video URL (or to Copy / AirDrop), as the
/// universal fallback when no first-class external player (Infuse, VLC) is detected.
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
