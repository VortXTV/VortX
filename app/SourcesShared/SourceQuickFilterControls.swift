import SwiftUI

/// List-only controls; Quality playback choices and Audio ranking remain where they already live.
struct SourceQuickFilterControls: View {
    let selection: SourceQuickFilterPolicy.Selection
    let change: @MainActor (SourceQuickFilterPolicy.Selection) -> Void
    @State private var showRange = false
    @State private var showCodec = false

    var body: some View {
        HStack(spacing: Theme.Space.sm) {
            Button {
                var next = selection; next.confirmedCacheOnly.toggle(); change(next)
            } label: {
                Label(selection.confirmedCacheOnly ? "Cache: Confirmed" : "Cache: All", systemImage: "bolt")
            }
            .buttonStyle(ChipButtonStyle(selected: selection.confirmedCacheOnly))
            .accessibilityHint("Shows only sources confirmed cached by your account. No new cache check is requested.")
            Button { showRange = true } label: {
                Text("Reported range: \(selection.range?.rawValue ?? "All")")
            }
            .buttonStyle(ChipButtonStyle(selected: selection.range != nil))
            .confirmationDialog("Provider-reported video range", isPresented: $showRange, titleVisibility: .visible) {
                Button("All ranges") { var next = selection; next.range = nil; change(next) }
                ForEach(SourceQuickFilterPolicy.Range.allCases, id: \.self) { value in
                    Button(value.rawValue) { var next = selection; next.range = value; change(next) }
                }
            }
            Button { showCodec = true } label: {
                Text("Reported codec: \(selection.codec?.rawValue ?? "All")")
            }
            .buttonStyle(ChipButtonStyle(selected: selection.codec != nil))
            .confirmationDialog("Provider-reported video codec", isPresented: $showCodec, titleVisibility: .visible) {
                Button("All codecs") { var next = selection; next.codec = nil; change(next) }
                ForEach(SourceQuickFilterPolicy.Codec.allCases, id: \.self) { value in
                    Button(value.rawValue) { var next = selection; next.codec = value; change(next) }
                }
            }
            if selection.isActive {
                Button("Reset quick filters") { change(.init()) }
                    .buttonStyle(ChipButtonStyle())
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Source list filters")
    }
}

struct SourceQuickFilterHelp: View {
    var body: some View {
        Text("List only; Play and Quality are unchanged. Cache reflects the last successful account check, not guaranteed availability. Range and codec are provider-reported, not verified. Unknown is not SDR or uncached.")
            .font(Theme.Typography.label)
            .foregroundStyle(Theme.Palette.textTertiary)
    }
}
