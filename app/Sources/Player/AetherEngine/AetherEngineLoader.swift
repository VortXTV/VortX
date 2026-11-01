#if VORTX_AETHER_ENGINE
import Foundation
import os

/// Loads VortXAetherKit at runtime, only on a system AetherEngine supports. The apps embed the framework but never
/// link it: a linked framework loads at launch, and the engine's iOS 18 / macOS 15 symbols would stop the app
/// opening on the iOS 16 and macOS 14 systems it still supports. The framework is reached only through
/// `VortXAetherBridging`.
enum AetherEngineLoader {
    /// Set once a load attempt failed this launch, which retires the AetherEngine choice until relaunch.
    private static let loadFailed = OSAllocatedUnfairLock(initialState: false)
    /// The framework's player class from the one successful load this launch.
    @MainActor private static var playerClass: (any VortXAetherBridging.Type)?

    /// Whether this system runs AetherEngine and this build carries it. Never loads the framework.
    static var isSupported: Bool {
        guard #available(iOS 18, tvOS 18, macOS 15, *) else { return false }
        return frameworkURL != nil && !loadFailed.withLock { $0 }
    }

    /// A new player, loading the framework on first use. A framework that will not load, or an engine that will
    /// not start, retires the choice for this launch.
    @MainActor
    static func makePlayer() throws -> any VortXAetherBridging {
        do {
            let loaded = try playerClass ?? load()
            playerClass = loaded
            return try loaded.makePlayer()
        } catch {
            loadFailed.withLock { $0 = true }
            DiagnosticsLog.log("player", "AetherEngine unavailable: \(error.localizedDescription)")
            throw error
        }
    }

    @MainActor
    private static func load() throws(LoaderError) -> any VortXAetherBridging.Type {
        guard #available(iOS 18, tvOS 18, macOS 15, *) else { throw .unsupportedSystem }
        guard let url = frameworkURL, let bundle = Bundle(url: url) else { throw .missing }
        do {
            try bundle.loadAndReturnError()
        } catch {
            throw .loadFailed(error.localizedDescription)
        }
        guard let playerClass = bundle.classNamed("VortXAetherBridgePlayer") as? any VortXAetherBridging.Type else {
            throw .incompatible
        }
        return playerClass
    }

    private static var frameworkURL: URL? {
        guard let url = Bundle.main.privateFrameworksURL?.appendingPathComponent("VortXAetherKit.framework"),
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    enum LoaderError: LocalizedError {
        case unsupportedSystem, missing, incompatible
        case loadFailed(String)

        var errorDescription: String? {
            switch self {
            case .unsupportedSystem: return "AetherEngine needs iOS 18, tvOS 18 or macOS 15."
            case .missing: return "AetherEngine isn't part of this build."
            case .incompatible: return "This build's AetherEngine doesn't match the app."
            case .loadFailed(let reason): return "AetherEngine could not load: \(reason)"
            }
        }
    }
}
#endif
