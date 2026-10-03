import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

// Fixtures replace application state and external effects only. The script extracts the exact
// production bottomBar factories, every editor section/tooltip body, and concrete view bodies.
// GlassStyle, Theme, ThemeManager and SkipSegments compile from their production files.
@propertyWrapper
struct ProbeValue<Value> {
    final class Storage { var value: Value; init(_ value: Value) { self.value = value } }
    private let storage: Storage
    init(wrappedValue: Value) { storage = Storage(wrappedValue) }
    var wrappedValue: Value {
        get { storage.value }
        nonmutating set { storage.value = newValue }
    }
    var projectedValue: Binding<Value> {
        Binding(get: { storage.value }, set: { storage.value = $0 })
    }
}

struct PlaybackMeta { var libraryId = "tt-probe"; var season: Int? = 1; var episode: Int? = 2 }
enum ProbePanel: String { case speed, subtitles, audio, video, quality, sources, episodes, chapters, sleep, playerSettings }
final class ProbeEffects {
    var events: [String] = []
    var seeks: [Double] = []
    func seek(to time: Double) { seeks.append(time) }
}
struct ProbeCoordinator { var player: ProbeEffects? }
final class ProbeThumbnails {
    var image: Int?
    var shown: [Double] = []
    var clears = 0
    func show(time: Double) { shown.append(time) }
    func clear() { clears += 1 }
}

struct PlayerScreen {
    let timePosClock: TimePosClock = {
        let clock = TimePosClock()
        clock.position = 25
        return clock
    }()
    let effects = ProbeEffects()
    let scrubThumbnails = ProbeThumbnails()
    var coordinator: ProbeCoordinator { ProbeCoordinator(player: effects) }
    var hideTask: Task<Void, Never>? = nil
    @ProbeValue var isLive = false
    var isPaused = false
    var controlsVisible = true
    var isLocked = false
    @ProbeValue var duration = 2_700.0
    var currentTime: Double {
        get { timePosClock.position }
        nonmutating set { timePosClock.position = newValue }
    }
    @ProbeValue var scrubbing = false
    @ProbeValue var scrubTarget = 30.0
    @ProbeValue var hoverPreviewTime: Double? = nil
    @ProbeValue var hoverPreviewRatio: CGFloat? = nil
    @ProbeValue var showExternalChooser = false
    var bufferedTime = 60.0
    var chapterFractions = [0.1, 0.5, 0.9]
    var skipSegments = [SkipSegment(kind: .intro, start: 0, end: 60),
                        SkipSegment(kind: .credits, start: 2_600, end: 2_700)]
    var endsAtClock: String? = "Ends at 22:30"
    var speed = 1.0
    var audioTracks: [Int] = [1]
    var hasMultipleQualities = true
    var hasAlternateSources = true
    var isEpisodePlaybackContext = true
    var hasChapters = true
    var sleepArmed = false
    var sleepLabel = "Sleep"
    var curMeta: PlaybackMeta? = PlaybackMeta()
    @ProbeValue var showSkipDBEdit = false
    @ProbeValue var skipDBEditStart = 10.0
    @ProbeValue var skipDBEditEnd = 30.0
    @ProbeValue var skipDBEditType = SkipDBSubmitView.SegmentType.intro
    @ProbeValue var skipDBShowEndTime = true
    @ProbeValue var skipDBSubmitResult: Bool? = nil
    @ProbeValue var skipDBSubmitError: String? = nil
    @ProbeValue var skipDBPreviewing = false
    var skipDBSubmitting = false
    var skipDBSubmittedKeys: Set<String> = []
    var skipDBIntroEstimateMs: Int? = 60_000
    func timeString(_ time: Double) -> String { "\(Int(time))" }
    func speedLabel(_ speed: Double) -> String { "\(speed)x" }
    func issueSeek(to time: Double, reason: String) { effects.seek(to: time); effects.events.append(reason) }
    func reportSeek(_ time: Double) { effects.events.append("report:\(time)") }
    func scheduleHide() { effects.events.append("hide") }
    func openPanel(_ panel: ProbePanel) { effects.events.append(panel.rawValue) }
    func grabFrame() { effects.events.append("grab") }
    func viewerPlay() { effects.events.append("play") }
    func restartFromBeginning() { effects.events.append("restart") }
    func seedSkipDBEditor() { effects.events.append("seed-editor") }
    func engageLock() { effects.events.append("lock") }
    func doSkipDBSubmit(meta: PlaybackMeta) async { effects.events.append("submit") }
    func trickplayPopup(time: Double) -> some View { Text("\(time)") }
    func trickplayBubbleOffset(sliderWidth: CGFloat) -> CGFloat { 0 }
}

@MainActor
enum PlayerBottomBarConstructionProbe {
    #if !os(macOS)
    static var window: UIWindow?
    #endif

    static func host<V: View>(_ view: V, width: CGFloat = 720, height: CGFloat = 260) {
        #if os(macOS)
        let host = NSHostingView(rootView: view)
        host.frame = CGRect(x: 0, y: 0, width: width, height: height)
        host.layoutSubtreeIfNeeded()
        #else
        let controller = UIHostingController(rootView: view)
        let window = window ?? UIWindow(frame: CGRect(x: 0, y: 0, width: width, height: 400))
        self.window = window
        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.view.frame = CGRect(x: 0, y: 0, width: width, height: height)
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
        #endif
    }

    static func run() {
        precondition(Thread.isMainThread)
        var cases = 0
        for duration in [0.0, 2_700.0] {
            for scrubbing in [false, true] {
                for editor in [false, true] {
                    for live in [false, true] {
                        for optionalPanels in [false, true] {
                            var screen = PlayerScreen()
                            screen.duration = duration
                            screen.scrubbing = scrubbing
                            screen.showSkipDBEdit = editor
                            screen.isLive = live
                            screen.audioTracks = optionalPanels ? [1] : []
                            screen.hasMultipleQualities = optionalPanels
                            screen.hasAlternateSources = optionalPanels
                            screen.isEpisodePlaybackContext = optionalPanels
                            screen.hasChapters = optionalPanels
                            let bar = screen.bottomBar
                            let type = String(reflecting: Swift.type(of: bar.body))
                            for leaf in ["PlayerLiveIndicator", "PlayerBottomTimeline", "PlayerSkipEditorLayout", "PlayerTransportToolbar"] {
                                precondition(type.contains(leaf), "missing nominal boundary: \(leaf)")
                            }
                            precondition(!type.contains("PlayerControlButton"), "button type leaked through toolbar boundary")
                            precondition(!type.contains("PlayerSeekSliderSurface"), "slider type leaked through timeline boundary")
                            precondition((bar.editor != nil) == editor)
                            precondition((bar.toolbar.audio != nil) == optionalPanels)
                            precondition((bar.toolbar.quality != nil) == optionalPanels)
                            precondition((bar.toolbar.sources != nil) == optionalPanels)
                            precondition((bar.toolbar.episodes != nil) == optionalPanels)
                            precondition((bar.toolbar.chapters != nil) == optionalPanels)
                            for width: CGFloat in [320, 390, 844, 1_024] {
                                host(bar, width: width)
                            }
                            screen.timePosClock.position = 25
                            host(screen.bottomBar)
                            cases += 1
                        }
                    }
                }
            }
        }
        // Exercise actual production editor closures even if a platform postpones child layout.
        for type in SkipDBSubmitView.SegmentType.allCases {
            for showEnd in [false, true] {
                for status in 0..<3 {
                    var screen = PlayerScreen()
                    screen.showSkipDBEdit = true
                    screen.skipDBEditType = type
                    screen.skipDBShowEndTime = showEnd
                    screen.skipDBSubmitting = status == 1
                    screen.skipDBSubmitResult = status == 2 ? true : nil
                    screen.skipDBSubmitError = status == 0 ? "Probe submit error" : nil
                    screen.skipDBSubmittedKeys = ["tt-probe:1:2:\(type.rawValue)"]
                    let editor = screen.bottomSkipEditor!
                    host(editor.typeControls()); host(editor.timeControls()); host(editor.actions())
                    host(screen.bottomBar)
                    cases += 1
                }
            }
        }
        verifyCallbacks()
        verifySeekStylesAndAdjustment()
        verifyPinchPolicy()
        verifyOptionsAndTouchLayouts()
        print("PASS \(cases) production full bottom-bar/editor constructions and layouts on main thread")
        print("PASS production toolbar routing, seek/scrub/hover callbacks and nominal metadata boundaries")
        print("PASS all 14 real seek styles, live preference changes, adjustable seek, touch layouts and pinch policy")
        print("LIMIT: service fixtures do not test media playback; runtime coverage is only this executable's OS")
    }

    static func verifySeekStylesAndAdjustment() {
        let saved = UserDefaults.standard.object(forKey: SeekBarStyle.storageKey)
        defer {
            if let saved { UserDefaults.standard.set(saved, forKey: SeekBarStyle.storageKey) }
            else { UserDefaults.standard.removeObject(forKey: SeekBarStyle.storageKey) }
        }
        let screen = PlayerScreen()
        func slider(width: CGFloat = 320, animated: Bool = true) -> PlayerStyledSeekSlider {
            let track = screen.bottomTimeline.track(CGSize(width: width, height: 44))
            return PlayerStyledSeekSlider(clock: screen.timePosClock,
                scrubbing: track.$scrubbing, scrubTarget: track.$scrubTarget,
                duration: track.duration, bufferedTime: track.bufferedTime,
                width: width, accent: track.accent, animated: animated,
                onScrubChanged: track.onScrubChanged, onEditingChanged: track.onEditingChanged)
        }
        precondition(SeekBarStyle.allCases.count == 14)
        for style in SeekBarStyle.allCases {
            UserDefaults.standard.set(style.rawValue, forKey: SeekBarStyle.storageKey)
            for width: CGFloat in [320, 390, 1_024] {
                let seek = slider(width: width)
                precondition(seek.selectedStyle == style && seek.artwork.style == style)
                host(seek, width: width, height: 44)
                let paused = slider(width: width, animated: false)
                precondition(!paused.artwork.animated)
                host(paused, width: width, height: 44)
            }
        }
        UserDefaults.standard.set("wave", forKey: SeekBarStyle.storageKey)
        let livePreference = slider()
        precondition(livePreference.selectedStyle == .wave)
        UserDefaults.standard.set("minimal", forKey: SeekBarStyle.storageKey)
        precondition(livePreference.selectedStyle == .minimal, "live seek preference was cached")
        UserDefaults.standard.set("unknown-style", forKey: SeekBarStyle.storageKey)
        precondition(slider().selectedStyle == .classic)
        screen.timePosClock.position = 100
        let seek = slider()
        seek.adjust(forward: true)
        seek.adjust(forward: false)
        precondition(screen.effects.seeks == [110, 100])
        precondition(screen.effects.events == ["scrub", "report:110.0", "hide", "scrub", "report:100.0", "hide"])
        precondition(screen.scrubThumbnails.shown == [110, 100])
        precondition(!screen.scrubbing)
        precondition(PlayerSeekInteractionPolicy.target(x: -40, width: 320, duration: 100) == 0)
        precondition(PlayerSeekInteractionPolicy.target(x: 160, width: 320, duration: 100) == 50)
        precondition(PlayerSeekInteractionPolicy.target(x: 400, width: 320, duration: 100) == 100)
        precondition(PlayerSeekInteractionPolicy.target(x: .nan, width: 320, duration: 100) == nil)
        precondition(PlayerSeekInteractionPolicy.target(x: 10, width: 20, duration: 100) == nil)
        for duration in [0, -1, Double.nan, Double.infinity] {
            precondition(PlayerSeekInteractionPolicy.target(x: 10, width: 320, duration: duration) == nil)
            precondition(PlayerSeekInteractionPolicy.adjusted(20, duration: duration, forward: true) == nil)
        }
        precondition(PlayerSeekInteractionPolicy.adjusted(5, duration: 100, forward: false) == 0)
        precondition(PlayerSeekInteractionPolicy.adjusted(95, duration: 100, forward: true) == 100)
        precondition(PlayerSeekInteractionPolicy.animates(requested: true, scrubbing: false, reduceMotion: false))
        precondition(!PlayerSeekInteractionPolicy.animates(requested: true, scrubbing: false, reduceMotion: true))
        precondition(!PlayerSeekInteractionPolicy.animates(requested: true, scrubbing: true, reduceMotion: false))
        precondition(!PlayerSeekInteractionPolicy.animates(requested: false, scrubbing: false, reduceMotion: false))
    }

    static func verifyPinchPolicy() {
        for current in ["original", "fill", "stretch"] {
            for scale: CGFloat in [0.7, 0.92, 1, 1.08, 1.4, .nan, .infinity, -1] {
                for enabled in [false, true] {
                    for locked in [false, true] {
                        for panelOpen in [false, true] {
                            let mode = PlayerVideoSizeGesturePolicy.mode(scale: scale, current: current,
                                enabled: enabled, locked: locked, panelOpen: panelOpen)
                            if !enabled || locked || panelOpen || !scale.isFinite || scale <= 0 || scale == 1 {
                                precondition(mode == nil)
                            } else if scale > 1 {
                                precondition(mode == (current == "fill" ? nil : "fill"))
                            } else {
                                precondition(mode == (current == "original" ? nil : "original"))
                            }
                        }
                    }
                }
            }
        }
    }

    static func verifyOptionsAndTouchLayouts() {
        var screen = PlayerScreen()
        screen.curMeta = PlaybackMeta(libraryId: "tt1234567", season: 1, episode: 2)
        let options = screen.touchOptionsActions
        precondition(options.map(\.id) == ["restart", "aspect", "sleep", "grab", "editor", "lock", "settings", "external"])
        options.forEach { $0.action() }
        precondition(screen.effects.events == ["restart", "video", "sleep", "grab", "seed-editor", "lock", "playerSettings"])
        precondition(screen.showSkipDBEdit && screen.showExternalChooser)
        screen.isLive = true
        precondition(!screen.touchOptionsActions.contains { ["restart", "editor"].contains($0.id) })
        screen.isLive = false
        screen.showSkipDBEdit = false
        for width: CGFloat in [320, 390, 844, 1_024] {
            host(ProbeTouchChrome(screen: screen), width: width, height: width > 500 ? 390 : 700)
        }
        host(ProbeTouchChrome.options(screen: screen), width: 300, height: 380)
    }

    static func verifyCallbacks() {
        let screen = PlayerScreen()
        let toolbar = screen.bottomTransportToolbar
        let buttons = [toolbar.speed, toolbar.subtitles, toolbar.audio!, toolbar.aspect, toolbar.quality!,
                       toolbar.sources!, toolbar.episodes!, toolbar.chapters!, toolbar.grab, toolbar.sleep]
        precondition(buttons.map(\.title) == ["Speed", "Subtitles", "Audio", "Aspect", "Quality", "Sources", "Episodes", "Chapters", "Grab", "Sleep"])
        buttons.forEach { $0.action() }
        precondition(screen.effects.events == ["speed", "subtitles", "audio", "video", "quality", "sources", "episodes", "chapters", "grab", "sleep"])
        screen.effects.events = []
        let track = screen.bottomTimeline.track(CGSize(width: 720, height: 24))
        track.onHoverPreviewChanged(0.5)
        precondition(screen.hoverPreviewTime == 1_350 && screen.hoverPreviewRatio == 0.5)
        precondition(screen.scrubThumbnails.shown.last == 1_350)
        track.onEditingChanged(true)
        precondition(screen.scrubbing && screen.scrubTarget == 25)
        precondition(screen.hoverPreviewTime == nil && screen.hoverPreviewRatio == nil)
        track.onScrubChanged(75)
        precondition(screen.scrubThumbnails.shown.last == 75)
        track.scrubTarget = 75
        precondition(screen.scrubTarget == 75, "production binding disconnected")
        track.onEditingChanged(false)
        precondition(!screen.scrubbing && screen.currentTime == 75)
        precondition(screen.effects.seeks == [75])
        precondition(screen.effects.events == ["scrub", "report:75.0", "hide"])
        precondition(screen.scrubThumbnails.clears == 1)
        track.onHoverPreviewChanged(nil)
        precondition(screen.hoverPreviewTime == nil && screen.scrubThumbnails.clears == 2)
        var activeScreen = PlayerScreen()
        activeScreen.speed = 1.5; activeScreen.sleepArmed = true
        precondition(activeScreen.bottomTransportToolbar.speed.active)
        precondition(activeScreen.bottomTransportToolbar.speed.title == "1.5x")
        precondition(activeScreen.bottomTransportToolbar.sleep.active)
        precondition(activeScreen.bottomTransportToolbar.sleep.icon == "moon.zzz.fill")
        activeScreen.showSkipDBEdit = true; activeScreen.curMeta = nil
        precondition(activeScreen.bottomSkipEditor == nil)
    }
}

/// Screenshot/layout fixture: all interactive child views are the exact production declarations.
/// Only the background and external-service callbacks are fixtures.
struct ProbeTouchChrome: View {
    let screen: PlayerScreen
    static func options(screen: PlayerScreen) -> PlayerTouchOptionsPanel {
        PlayerTouchOptionsPanel(actions: screen.touchOptionsActions,
            volume: { AnyView(Slider(value: .constant(0.7)).frame(minHeight: 44)) },
            routePicker: { AnyView(Label("AirPlay", systemImage: "airplay.video").frame(height: 44)) },
            dismiss: {})
    }
    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.12, green: 0.16, blue: 0.19), .black],
                startPoint: .topLeading, endPoint: .bottomTrailing).ignoresSafeArea()
            VStack(spacing: 0) {
                PlayerTouchHeader(title: "A Long Movie Title · Episode 2", metadata: "4K  ·  HDR  ·  EAC3 6ch",
                    close: PlayerTouchIconButton(icon: "chevron.down", label: "Close player", action: {}),
                    pictureInPicture: { AnyView(PlayerTouchIconButton(icon: "pip.enter", label: "Picture in Picture", action: {})) },
                    aspect: PlayerTouchAspectButton(mode: "original", toggle: {}, select: { _ in }),
                    fullscreen: PlayerTouchIconButton(icon: "arrow.up.left.and.arrow.down.right", label: "Fullscreen", action: {}),
                    options: PlayerTouchOptionsButton(presented: .constant(false),
                        content: { Self.options(screen: screen) }, onVisibilityChanged: { _ in }))
                Spacer()
                PlayerTouchTransport(paused: false, live: false, seekStep: "10",
                    previous: PlayerTouchIconButton(icon: "backward.end.fill", label: "Previous episode", action: {}),
                    next: PlayerTouchIconButton(icon: "forward.end.fill", label: "Next episode", action: {}),
                    backward: {}, forward: {}, toggle: {})
                Spacer()
                screen.bottomBar
            }
        }
    }
}

#if os(macOS)
@main
struct PlayerSeekTimelineConstructionTests {
    @MainActor static func main() {
        _ = NSApplication.shared
        PlayerBottomBarConstructionProbe.run()
    }
}
#else
final class PlayerBottomBarProbeDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        DispatchQueue.main.async {
            PlayerBottomBarConstructionProbe.run()
            if ProcessInfo.processInfo.environment["PLAYER_PROBE_SCREENSHOT"] == "1" {
                UserDefaults.standard.set("wave", forKey: SeekBarStyle.storageKey)
                let screen = PlayerScreen()
                screen.timePosClock.position = 900
                PlayerBottomBarConstructionProbe.host(ProbeTouchChrome(screen: screen),
                    width: UIScreen.main.bounds.width, height: UIScreen.main.bounds.height)
            } else {
                exit(0)
            }
        }
        return true
    }
}
@main
struct PlayerSeekTimelineConstructionTests {
    static func main() {
        UIApplicationMain(CommandLine.argc, CommandLine.unsafeArgv, nil, NSStringFromClass(PlayerBottomBarProbeDelegate.self))
    }
}
#endif
