//
//  AdsKitClient+Types — value types shared between the interface client and the
//  splash-time reducer.
//
//  These were nested inside `AdsBootstrap` before the client refactor. Pulling
//  them up to module scope lets `AdsKitClient` carry them across the
//  interface/live boundary without forcing live callers to spell out
//  `AdsBootstrap.Config` everywhere. `AdsBootstrap` keeps typealiases for
//  back-compat with existing consumers.
//

import Foundation
import UMPClient

/// Splash-time bootstrap config. Pass `nil` to skip a step; pass a value to run
/// it. Mirrors `LaunchConfiguration` in `AdsKitConfigure` (inhabited = run, nil
/// = skip).
public struct BootstrapConfig: Sendable {
    public enum SplashAd: Sendable {
        case appOpen(String)
        case interstitial(String)
        case none
    }

    public let ump: UMPConfig?
    public let splashAd: SplashAd
    public let preloads: @Sendable () async -> Void
    public let enableRevenueBridge: Bool
    public let enableResumeAdHandler: Bool
    /// Read on each willEnterForeground — not captured — so in-session upgrades
    /// are respected.
    public let isPremium: @Sendable () -> Bool

    public init(
        ump: UMPConfig? = UMPConfig(),
        splashAd: SplashAd = .none,
        preloads: @escaping @Sendable () async -> Void = {},
        enableRevenueBridge: Bool = true,
        enableResumeAdHandler: Bool = true,
        isPremium: @escaping @Sendable () -> Bool = { false }
    ) {
        self.ump = ump
        self.splashAd = splashAd
        self.preloads = preloads
        self.enableRevenueBridge = enableRevenueBridge
        self.enableResumeAdHandler = enableResumeAdHandler
        self.isPremium = isPremium
    }

    /// Convenience constructor mirroring `LaunchConfiguration.fromInfoPlist()`.
    ///
    /// Reads from `Info.plist`:
    /// - `AdsKitSplashAdUnitID` (String) — splash ad unit ID.
    /// - `AdsKitSplashAdKind` (String) — `"appOpen"` or `"interstitial"` (case-insensitive).
    ///
    /// `splashAd = .none` when the keys are missing, empty, or unrecognized.
    public static func fromInfoPlist(
        isPremium: @escaping @Sendable () -> Bool = { false },
        preloads: @escaping @Sendable () async -> Void = {}
    ) -> BootstrapConfig {
        let unitID = Bundle.main.object(forInfoDictionaryKey: "AdsKitSplashAdUnitID") as? String ?? ""
        let kind = (Bundle.main.object(forInfoDictionaryKey: "AdsKitSplashAdKind") as? String)?.lowercased() ?? ""

        let splashAd: SplashAd
        switch (unitID.isEmpty ? nil : unitID, kind) {
        case let (id?, "appopen"):
            splashAd = .appOpen(id)
        case let (id?, "interstitial"):
            splashAd = .interstitial(id)
        default:
            splashAd = .none
        }

        return BootstrapConfig(
            ump: UMPConfig(),
            splashAd: splashAd,
            preloads: preloads,
            enableRevenueBridge: true,
            enableResumeAdHandler: true,
            isPremium: isPremium
        )
    }
}

/// Discrete steps of the splash-time pipeline. Drives both UI (e.g. a progress
/// indicator on splash) and telemetry (the `phase` field on
/// `adskit_bootstrap_failed`).
public enum BootstrapPhase: Equatable, Sendable, CustomStringConvertible {
    case idle
    case requestingATT
    case preloading
    case requestingUMP
    case installingRevenueBridge
    case installingResumeAdHandler
    case showingSplashAd
    case done
    case failed(reason: String)

    public var description: String {
        switch self {
        case .idle: return "idle"
        case .requestingATT: return "requestingATT"
        case .preloading: return "preloading"
        case .requestingUMP: return "requestingUMP"
        case .installingRevenueBridge: return "installingRevenueBridge"
        case .installingResumeAdHandler: return "installingResumeAdHandler"
        case .showingSplashAd: return "showingSplashAd"
        case .done: return "done"
        case let .failed(reason): return "failed(\(reason))"
        }
    }
}

/// Output of `AdsKitClient.runBootstrap`. Carries the values the reducer needs
/// to keep on State (or to forward to analytics) after the pipeline finishes.
public struct BootstrapResult: Equatable, Sendable {
    public let splashAdShown: Bool
    public let consent: UMPConsentStatus

    public init(splashAdShown: Bool, consent: UMPConsentStatus) {
        self.splashAdShown = splashAdShown
        self.consent = consent
    }
}
