#if os(iOS) && !CINEMA_UI_SMOKE_RENDERER
import SwiftUI

import UIKit
@preconcurrency import GoogleCast

/// Use Google's supplied Cast button at the top level. Its normal SDK action presents discovery,
/// network permission and the device/control dialog. The additional target captures explicit media
/// intent; it never exports a URL merely because the button is mounted or discovery resumes.
struct GoogleCastActionButton: UIViewRepresentable {
    let enabled: Bool
    let action: () -> Void
    @MainActor final class Coordinator: NSObject {
        var action: () -> Void
        init(action: @escaping () -> Void) { self.action = action }
        @objc func tapped() { action() }
    }
    func makeCoordinator() -> Coordinator { Coordinator(action: action) }
    func makeUIView(context: Context) -> GCKUICastButton {
        let button = GCKUICastButton(frame: CGRect(x: 0, y: 0, width: 44, height: 44))
        button.tintColor = .white
        button.accessibilityLabel = "Google Cast"
        button.addTarget(context.coordinator, action: #selector(Coordinator.tapped), for: .touchUpInside)
        button.isEnabled = enabled
        return button
    }
    func updateUIView(_ button: GCKUICastButton, context: Context) {
        context.coordinator.action = action
        button.isEnabled = enabled
    }
}

struct GoogleCastPlaybackOverlay: View {
    @ObservedObject var manager: GoogleCastManager
    let close: () -> Void
    @State private var seekTarget = 0.0
    @State private var scrubbing = false
    var body: some View {
        if manager.state.owned {
            ScrollView {
            VStack(spacing: 24) {
                HStack {
                    Button("Close player", action: close).frame(minHeight: 44)
                    Spacer()
                    GoogleCastActionButton(enabled: true, action: {}).frame(width: 44, height: 44)
                    Button("Stop casting") { manager.stopCasting() }.frame(minHeight: 44)
                }
                Spacer()
                Image(systemName: "tv.and.wifisignal").font(.system(size: 52))
                Text("Playing on \(manager.state.device)").font(.title2)
                if manager.state.suspended {
                    Text("Reconnecting to receiver…").font(.body)
                } else {
                    HStack(spacing: 32) {
                        Button { manager.seek(to: max(0, manager.state.position - 10)) } label: {
                            Image(systemName: "gobackward.10").font(.largeTitle).frame(width: 60, height: 60)
                        }.accessibilityLabel("Skip back 10 seconds")
                        Button { manager.togglePause() } label: {
                            Image(systemName: manager.state.paused ? "play.fill" : "pause.fill")
                                .font(.largeTitle).frame(width: 60, height: 60)
                        }.accessibilityLabel(manager.state.paused ? "Play" : "Pause")
                        Button { manager.seek(to: manager.state.position + 10) } label: {
                            Image(systemName: "goforward.10").font(.largeTitle).frame(width: 60, height: 60)
                        }.accessibilityLabel("Skip forward 10 seconds")
                    }
                    if manager.state.duration > 0 {
                        Slider(value: Binding(get: { scrubbing ? seekTarget : manager.state.position }, set: { seekTarget = $0 }),
                               in: 0...max(1, manager.state.duration), onEditingChanged: { editing in
                            if editing { seekTarget = manager.state.position }
                            scrubbing = editing
                            if !editing { manager.seek(to: seekTarget) }
                        }).accessibilityLabel("Receiver playback position")
                    }
                }
                Text("\(Int(min(604800, max(0, manager.state.position.isFinite ? manager.state.position : 0)))) / \(Int(min(604800, max(0, manager.state.duration.isFinite ? manager.state.duration : 0)))) seconds")
                    .monospacedDigit().accessibilityLabel("Receiver progress")
                Spacer()
            }
            .padding(24).frame(maxWidth: .infinity, minHeight: 280)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black).foregroundStyle(.white)
            .buttonStyle(.plain)
        }
    }
}
#endif
