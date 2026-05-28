//
//  AdsKitConfigure — single launch-time orchestrator for the host app.
//
//  Call `AdsKit.configure(application:launchOptions:)` exactly once from
//  `application(_:didFinishLaunchingWithOptions:)`. Fans out to Firebase
//  (synchronous), Facebook (synchronous, canImport-gated), Adjust SDK init
//  chained with `installRevenueBridge` + `installResumeAdHandler` (one
//  background Task — ordering preserved), and Remote Config priming
//  (separate background Task).
//
//  ATT, UMP, ad preloads, and the splash ad remain in `AdsKit.Bootstrap` —
//  they are user-visible flows that belong on the splash screen, not at launch.
//
//  The `AdsKit` namespace itself is declared in the SDK-free `AdsKit` target so
//  preview / test code can reach `AdsKit.Bootstrap` without linking Firebase /
//  Adjust / GoogleMobileAds. This file extends it with the live launch surface.
//
//  Filter traces in Console.app with `subsystem:com.mahainc.AdsKit`.
//

import AdjustClient
@preconcurrency import AdjustSdk
import AdsKit
import AnalyticClient
import ComposableArchitecture
import MobileAdsClient
import OSLog
import RemoteConfigClient
import UIKit

#if canImport(FacebookCore)
import FacebookCore
#endif

extension AdsKit {

    @MainActor private static var hasConfigured = false

    /// Awaits the Adjust → revenue-bridge → resume-ad-handler chain started by
    /// `configure(...)` and returns the per-step outcome. Wire into
    /// `Bootstrap.Config.configureGate` so Bootstrap can record the outcome
    /// on State and preloaded ads observe the revenue bridge.
    ///
    /// Returns a default `ConfigureOutcome()` (all `nil`s) if `configure(...)`
    /// has never been called. Use `chainState()` to distinguish that case from
    /// "ran with no-ops" when the distinction matters.
    public static func adRevenueChainReady() async -> AdsKit.ConfigureOutcome {
        await ConfigureCoordinator.shared.awaitChain()
    }

    /// Current lifecycle of the Adjust chain — `notStarted` before any
    /// `configure(...)` call, `running` while the chain Task is in-flight,
    /// `completed(outcome)` once the chain Task returns.
    public static func chainState() async -> AdsKit.ChainState {
        await ConfigureCoordinator.shared.currentChainState()
    }

    /// Single launch-time entry point. Idempotent — subsequent successful calls
    /// are no-ops; a failed call leaves `hasConfigured` false so the caller can
    /// retry after fixing the underlying problem.
    ///
    /// Order:
    ///   1. Firebase.configure (synchronous; required before Analytics/RemoteConfig)
    ///      ↳ On failure (missing plist), `configure(...)` aborts before any
    ///        other step runs.
    ///   2. Facebook activateApp (synchronous; canImport(FacebookCore)-gated)
    ///   3. Analytics.initialize (fire-and-forget Task; must run after Firebase)
    ///   4. Adjust.initialize → installRevenueBridge
    ///      (single chained background Task; per-step outcomes accumulate on a
    ///      static and are returned by `adRevenueChainReady()`)
    ///   5. Remote Config prime (fire-and-forget Task.detached)
    ///
    /// Telemetry:
    ///   - `adskit_configure_success` — emitted at end of synchronous portion.
    ///     Reports *dispatch*, i.e. which background Tasks were kicked off.
    ///   - `adskit_configure_chain_completed` — emitted from inside the chained
    ///     Task once all enabled steps' awaits return. Reports per-step booleans.
    ///   - `adskit_configure_error` — Firebase plist-missing only.
    ///
    /// ATT, UMP, ad preloads, and the splash ad continue to run in `AdsKit.Bootstrap`.
    @MainActor
    public static func configure(
        application: UIApplication,
        launchOptions: [UIApplication.LaunchOptionsKey: Any]?,
        _ configuration: LaunchConfiguration = .fromInfoPlist()
    ) {
        guard !hasConfigured else {
            Logger.adsKitConfigure.debug("already configured, skipping")
            return
        }

        Logger.adsKitConfigure.info("start")
        @Dependency(\.firebaseConfigurator) var firebaseConfigurator
        @Dependency(\.facebookConfigurator) var facebookConfigurator
        let firebaseResult = AdsKit.resolveFirebaseOutcome(
            configuration.firebase,
            using: firebaseConfigurator
        )
        if firebaseResult.isSkipped {
            Logger.adsKitConfigure.debug("firebase — skipped (nil configuration)")
        }
        // Persist the firebase outcome on the coordinator off-main; the value
        // is captured for the @MainActor-side abort decision below.
        Task { await ConfigureCoordinator.shared.setFirebase(firebaseResult) }
        if firebaseResult.isFailed, case .plistName(let name)? = configuration.firebase {
            emitFirebasePlistMissingTelemetry(plistName: name)
        }
        guard !firebaseResult.isFailed else {
            Logger.adsKitConfigure.fault(
                "aborting — Firebase configuration failed; downstream init skipped"
            )
            // Leave hasConfigured = false so the host can retry after fixing the plist.
            return
        }
        hasConfigured = true

        let firebaseReady = firebaseResult.isSucceeded
        let facebookStatus: AdsKit.StepStatus
        if case .enabled = configuration.facebook {
            facebookConfigurator.activate(application, launchOptions)
            facebookStatus = .succeeded
        } else {
            Logger.adsKitConfigure.info("facebook — disabled")
            facebookStatus = .skipped
        }
        Task { await ConfigureCoordinator.shared.setFacebook(facebookStatus) }
        initializeAnalytics(configuration.analytics, firebaseReady: firebaseReady)
        startAdjustChain(
            configuration.adjust,
            enableRevenueBridge: configuration.enableRevenueBridge
        )
        Logger.adsKitConfigure.info("done (sync portion)")

        // Telemetry: emit one success event capturing which SDKs were dispatched.
        // Fire-and-forget so a slow analytics backend never blocks launch.
        let firebaseConfigured = configuration.firebase != nil
        let facebookEnabled: Bool = {
            if case .enabled = configuration.facebook { return true } else { return false }
        }()
        let adjustDispatched = configuration.adjust != nil
        let analyticsDispatched = configuration.analytics != nil
        let revenueBridgeEnabled = configuration.enableRevenueBridge
        @Dependency(\.analyticClient) var analyticClient
        Task {
            // Firebase reserves the `firebase_` param-name prefix and silently
            // drops anything starting with it (logs I-ACS013008). Use a non-reserved
            // form so the param survives into the Firebase Analytics report.
            await analyticClient.trackEvent("adskit_configure_success", [
                "configured_firebase": .bool(firebaseConfigured),
                "facebook_enabled": .bool(facebookEnabled),
                "adjust_dispatched": .bool(adjustDispatched),
                "analytics_dispatched": .bool(analyticsDispatched),
                "revenue_bridge_enabled": .bool(revenueBridgeEnabled),
            ])
            Logger.adsKitConfigure.notice("telemetry: adskit_configure_success emitted")
        }
    }

    /// Forwards custom-URL-scheme opens to Facebook (return value) and to Adjust
    /// (fire-and-forget — Adjust handles deep links independently of the host's
    /// open-URL return value). Without this, Adjust attribution for paid links
    /// using the app's URL scheme breaks.
    ///
    /// Returns `true` if Facebook handled the URL; otherwise `false`. Safe to
    /// call when `FacebookCore` is not linked — returns `false`.
    @MainActor
    public static func application(
        _ app: UIApplication,
        open url: URL,
        options: [UIApplication.OpenURLOptionsKey: Any]
    ) -> Bool {
        if let deeplink = ADJDeeplink(deeplink: url) {
            Adjust.processDeeplink(deeplink)
        }
        #if canImport(FacebookCore)
        if ApplicationDelegate.shared.application(app, open: url, options: options) {
            return true
        }
        #endif
        return false
    }

    /// Forwards Universal Link activations to Adjust. Call from
    /// `application(_:continue:restorationHandler:)` (UIKit) or from
    /// `scene(_:continue:)` / `scene(_:willConnectTo:options:)`'s
    /// `userActivities` on cold launch. Returns `true` if a `webpageURL` was
    /// present and forwarded — host may still chain its own deep-link routing.
    @MainActor
    @discardableResult
    public static func application(
        _ app: UIApplication,
        continue userActivity: NSUserActivity
    ) -> Bool {
        guard
            userActivity.activityType == NSUserActivityTypeBrowsingWeb,
            let url = userActivity.webpageURL,
            let deeplink = ADJDeeplink(deeplink: url)
        else {
            return false
        }
        Adjust.processDeeplink(deeplink)
        return true
    }

    // MARK: - Private

    private static func emitFirebasePlistMissingTelemetry(plistName: String) {
        @Dependency(\.analyticClient) var analyticClient
        Task {
            await analyticClient.trackEvent("adskit_configure_error", [
                "reason": "firebase_plist_missing",
                "plist_name": .string(plistName),
            ])
            Logger.adsKitConfigure.notice("telemetry: adskit_configure_error emitted (firebase_plist_missing)")
        }
    }

    private static func initializeAnalytics(_ config: AnalyticConfig?, firebaseReady: Bool) {
        guard let config else {
            Logger.adsKitConfigure.info("analytics — skipped (no config)")
            Task { await ConfigureCoordinator.shared.setAnalytics(.skipped) }
            return
        }
        // AnalyticClient is Firebase Analytics-backed; instantiating it before
        // FirebaseApp.configure() succeeds is undefined and may crash. Skip
        // cleanly so the host can still bring up Adjust / Facebook in isolation.
        guard firebaseReady else {
            Logger.adsKitConfigure.notice("analytics — skipped (Firebase not configured)")
            Task {
                await ConfigureCoordinator.shared.setAnalytics(
                    .failed(reason: "Firebase not configured")
                )
            }
            return
        }
        Logger.adsKitConfigure.info(
            "analytics — initialize dispatched (collectionEnabled=\(config.collectionEnabled, privacy: .public), userID=\(config.userID ?? "nil", privacy: .public), properties=\(config.userProperties.count, privacy: .public))"
        )
        @Dependency(\.analyticClient) var analyticClient
        Task {
            await analyticClient.initialize(config)
            await ConfigureCoordinator.shared.setAnalytics(.succeeded)
            Logger.adsKitConfigure.info("analytics — initialize completed")
        }
    }

    /// Single chained Task: Adjust init → installRevenueBridge.
    /// `installRevenueBridge` forwards paid events to Adjust, so it must observe a
    /// ready Adjust SDK — hence the chain rather than parallel Tasks. The
    /// app-open resume handler is installed by the host app (AdsKit no longer
    /// owns the Remote Config schema that drives its policy).
    ///
    /// Idempotent: routed through `ConfigureCoordinator.ensureChainStarted(_:)`,
    /// so a second `configure(...)` call observes the existing chain Task
    /// instead of spawning a duplicate.
    @MainActor
    private static func startAdjustChain(
        _ adjust: AdjustClient.Config?,
        enableRevenueBridge: Bool
    ) {
        if let adjust {
            Logger.adsKitConfigure.info(
                "adjust — initialize dispatched (env=\(String(describing: adjust.environment), privacy: .public), token=\(adjust.appToken.prefix(4), privacy: .public)…)"
            )
        } else {
            Logger.adsKitConfigure.info("adjust — skipped (no token)")
        }
        @Dependency(\.adjustClient) var adjustClient
        @Dependency(\.mobileAdsClient) var mobileAdsClient
        @Dependency(\.analyticClient) var analyticClient
        Task { [adjustClient, mobileAdsClient, analyticClient] in
            let coordinator = AdsKit.ConfigureCoordinator.shared
            await coordinator.ensureChainStarted {
                let snapshot = await coordinator.snapshot()
                let startedAt = Date()
                var adjustInitialized = false
                var revenueBridgeInstalled = false

                // TODO: AdjustClient / MobileAdsClient calls below are non-throwing,
                // so the StepStatus we record is always `.succeeded` once the await
                // returns. Wrap in do/catch once upstream APIs throw and surface
                // `.failed(reason:)` with the underlying error.
                if let adjust, snapshot.adjust != .succeeded {
                    await adjustClient.initialize(adjust)
                    adjustInitialized = true
                    await coordinator.setAdjust(.succeeded)
                    Logger.adsKitConfigure.info("adjust — initialize completed")
                } else if adjust == nil {
                    await coordinator.setAdjust(.skipped)
                }
                if enableRevenueBridge, snapshot.revenueBridge != .succeeded {
                    Logger.adsKitConfigure.info("revenue bridge — install dispatched")
                    await mobileAdsClient.installRevenueBridge()
                    revenueBridgeInstalled = true
                    await coordinator.setRevenueBridge(.succeeded)
                    Logger.adsKitConfigure.info("revenue bridge — install completed")
                } else if !enableRevenueBridge {
                    await coordinator.setRevenueBridge(.skipped)
                }

                let durationMs = Int(Date().timeIntervalSince(startedAt) * 1000)
                // `was_noop` distinguishes a successful chain (all true) from a retry
                // where every step was already done in a prior call (all false because
                // the snapshot guard skipped them). Without this flag a dashboard
                // sees two `false`s and misreads it as total failure.
                let wasNoop = !adjustInitialized && !revenueBridgeInstalled
                await analyticClient.trackEvent("adskit_configure_chain_completed", [
                    "duration_ms": .int(durationMs),
                    "adjust_initialized": .bool(adjustInitialized),
                    "revenue_bridge_installed": .bool(revenueBridgeInstalled),
                    "was_noop": .bool(wasNoop),
                ])
                Logger.adsKitConfigure.notice(
                    "telemetry: adskit_configure_chain_completed emitted (duration_ms=\(durationMs), was_noop=\(wasNoop))"
                )
                return await coordinator.snapshot()
            }
        }
    }

}
