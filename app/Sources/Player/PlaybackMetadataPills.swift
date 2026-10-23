import SwiftUI

/// A read-only leaf at the existing metadata anchor. It adds no controls, focus targets or timers.
struct PlaybackMetadataPills: View {
    let pills: [PlaybackMetadataPill]
    var body: some View {
        HStack(spacing: 6) {
            ForEach(pills) { pill in
                HStack(spacing: 4) {
                    Image(systemName: pill.systemImage).accessibilityHidden(true)
                    Text(pill.text).lineLimit(1)
                }
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.white.opacity(0.15), lineWidth: 0.5))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(pill.accessibilityLabel)
            }
        }
        .allowsHitTesting(false)
    }
}
