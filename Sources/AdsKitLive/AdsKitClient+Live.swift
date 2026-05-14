//
//  AdsKitClient+Live — liveValue for the post-init façade.
//
//  Houses the splash-time orchestration (previously inline in
//  `AdsBootstrap.body`) and the deep-link forwarding (previously static on
//  the `AdsKit` enum). Both directions through the same dependency means
//  feature tests can stub the whole post-init surface with one override.
//
//  Lifetime: `liveValue` is constructed once per `DependencyValues` and reads
//  the underlying clients (`mobileAdsClient`, `umpClient`, `analyticClient`,
//  `adjustClient`) at call time via `@Dependency`. AppDelegate's
//  `AdsKit.configure(...)` initializes those underlying clients before any of
//  these closures run.
//

import AdsKit
import AdjustClient
@preconcurrency import AdjustSdk
import AnalyticClient
import ComposableArchitecture
import Foundation
import MobileAdsClient
import OSLog
import UIKit
import UMPClient

#if canImport(FacebookCore)
import FacebookCore
#endif

extension AdsKitClient: DependencyKey {
    public static var liveValue: AdsKitClient {
        AdsKitClient(
            runBootstrap: { config, onPhase in
                await BootstrapEngine.run(config: config, onPhase: onPhase)
            },
            processOpenURL: { url, app, options in
                if let deeplink = ADJDeeplink(deeplink: url) {
                    Adjust.processDeeplink(deeplink)
                }
                #if canImport(FacebookCore)
                if ApplicationDelegate.shared.application(app, open: url, options: options) {
                    return true
                }
                #endif
                return false
            },
            processUserActivity: { userActivity, _ in
                guard
                    userActivity.activityType == NSUserActivityTypeBrowsingWeb,
                    let url = userActivity.webpageURL,
                    let deeplink = ADJDeeplink(deeplink: url)
                else {
                    return false
                }
                Adjust.processDeeplink(deeplink)
                return true
            },
            showAd: { ad in
                @Dependency(\.mobileAdsClient) var mobileAdsClient
                try await mobileAdsClient.showAd(ad)
            },
            shouldShowAd: { ad, rules in
                @Dependency(\.mobileAdsClient) var mobileAdsClient
                return await mobileAdsClient.shouldShowAd(ad, rules)
            }
        )
    }
}

// MARK: - Bootstrap pipeline

/// File-private engine that runs the splash-time pipeline. Kept out of the
/// liveValue closure body to keep that closure scannable; the engine itself
/// reads underlying clients via `@Dependency` so call-time mocks compose.
private enum BootstrapEngine {

    static func run(
        config: BootstrapConfig,
        onPhase: @Sendable (BootstrapPhase) async -> Void
    ) async -> BootstrapResult {
        @Dependency(\.mobileAdsClient) var mobileAdsClient
        @Dependency(\.umpClient) var umpClient
        @Dependency(\.analyticClient) var analyticClient

        let startedAt = Date()
        let tracker = PhaseTracker()
        var splashAdShown = false
        var consent: UMPConsentStatus = .unknown

        do {
            try Task.checkCancellation()
            await mobileAdsClient.requestTrackingAuthorizationIfNeeded()

            await enter(.preloading, tracker: tracker, onPhase: onPhase)
            await config.preloads()

            if let umpConfig = config.ump {
                await enter(.requestingUMP, tracker: tracker, onPhase: onPhase)
                consent = await resolveConsent(umpConfig, umpClient: umpClient)
            }

            if config.enableRevenueBridge {
                await enter(.installingRevenueBridge, tracker: tracker, onPhase: onPhase)
                await mobileAdsClient.installRevenueBridge()
            }

            if config.enableResumeAdHandler {
                await enter(.installingResumeAdHandler, tracker: tracker, onPhase: onPhase)
                await mobileAdsClient.installResumeAdHandler(config.isPremium)
            }

            await enter(.showingSplashAd, tracker: tracker, onPhase: onPhase)
            splashAdShown = await runSplashAd(config.splashAd, mobileAdsClient: mobileAdsClient)

            await enter(.done, tracker: tracker, onPhase: onPhase)
            await emitSuccess(
                config: config,
                consent: consent,
                splashAdShown: splashAdShown,
                startedAt: startedAt,
                analyticClient: analyticClient
            )
            return BootstrapResult(splashAdShown: splashAdShown, consent: consent)
        } catch is CancellationError {
            Logger.adsKitBootstrap.debug("bootstrap cancelled")
            return BootstrapResult(splashAdShown: splashAdShown, consent: consent)
        } catch {
            Logger.adsKitBootstrap.error(
                "bootstrap failed at phase=\(tracker.phase.description, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
            await emitFailure(phase: tracker.phase, reason: error.localizedDescription, analyticClient: analyticClient)
            // Surface the failure to the reducer through the same phase stream.
            await onPhase(.failed(reason: error.localizedDescription))
            return BootstrapResult(splashAdShown: splashAdShown, consent: consent)
        }
    }

    private static func enter(
        _ phase: BootstrapPhase,
        tracker: PhaseTracker,
        onPhase: @Sendable (BootstrapPhase) async -> Void
    ) async {
        tracker.phase = phase
        Logger.adsKitBootstrap.info("phase=\(phase.description, privacy: .public)")
        await onPhase(phase)
    }

    private static func resolveConsent(
        _ config: UMPConfig,
        umpClient: UMPClient
    ) async -> UMPConsentStatus {
        do {
            return try await umpClient.requestConsentIfNeeded(config)
        } catch {
            Logger.adsKitBootstrap.notice(
                "UMP form failed, defaulting to .unknown: \(error.localizedDescription, privacy: .public)"
            )
            return .unknown
        }
    }

    /// `shouldShowAd` auto-loads into the actor cache that `showAd` reads from;
    /// `config.preloads` uses a different (legacy ads_swift) pool that `showAd`
    /// does not see, so without this gate the splash ad throws `.adNotReady`.
    private static func runSplashAd(
        _ splashAd: BootstrapConfig.SplashAd,
        mobileAdsClient: MobileAdsClient
    ) async -> Bool {
        let adType: MobileAdsClient.AdType? = {
            switch splashAd {
            case let .appOpen(id): return .appOpen(id)
            case let .interstitial(id): return .interstitial(id)
            case .none: return nil
            }
        }()
        guard let adType, await mobileAdsClient.shouldShowAd(adType, []) else {
            return false
        }
        do {
            try await mobileAdsClient.showAd(adType)
            return true
        } catch {
            Logger.adsKitBootstrap.notice(
                "splash show failed (non-fatal): \(error.localizedDescription, privacy: .public)"
            )
            return false
        }
    }

    private static func emitSuccess(
        config: BootstrapConfig,
        consent: UMPConsentStatus,
        splashAdShown: Bool,
        startedAt: Date,
        analyticClient: AnalyticClient
    ) async {
        let durationMs = Int(Date().timeIntervalSince(startedAt) * 1000)
        await analyticClient.trackEvent("adskit_bootstrap_success", [
            "duration_ms": .int(durationMs),
            "ump_dispatched": .bool(config.ump != nil),
            "revenue_bridge_dispatched": .bool(config.enableRevenueBridge),
            "resume_ad_handler_dispatched": .bool(config.enableResumeAdHandler),
            "splash_ad_shown": .bool(splashAdShown),
            "consent": .string(String(describing: consent)),
        ])
        Logger.adsKitBootstrap.notice(
            "telemetry: adskit_bootstrap_success emitted (duration_ms=\(durationMs), splash_ad_shown=\(splashAdShown))"
        )
    }

    private static func emitFailure(
        phase: BootstrapPhase,
        reason: String,
        analyticClient: AnalyticClient
    ) async {
        await analyticClient.trackEvent("adskit_bootstrap_failed", [
            "phase": .string(phase.description),
            "reason": .string(reason),
        ])
        Logger.adsKitBootstrap.notice(
            "telemetry: adskit_bootstrap_failed emitted (phase=\(phase.description, privacy: .public))"
        )
    }
}

/// Reference-typed phase tracker so the per-phase helpers can update the
/// running phase without taking an `inout BootstrapPhase` across `await`
/// boundaries.
private final class PhaseTracker: @unchecked Sendable {
    var phase: BootstrapPhase = .requestingATT
}
