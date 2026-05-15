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
import FirebaseCore
import MobileAdsClient
import OSLog
import RemoteConfigClient
import UIKit

#if canImport(FacebookCore)
import FacebookCore
#endif

extension AdsKit {

    public struct LaunchConfiguration: Sendable {

        public enum Firebase: Sendable {
            /// Read `<plistName>.plist` from `Bundle.main` and configure with its options.
            case plistName(String)
            /// Configure with the default `GoogleService-Info.plist` lookup.
            case defaultPlist
        }

        public enum Facebook: Sendable {
            case enabled
            case disabled
        }

        public var firebase: Firebase?
        public var facebook: Facebook
        public var adjust: AdjustConfig?
        public var analytics: AnalyticConfig?
        public var enableRevenueBridge: Bool
        public var enableResumeAdHandler: Bool
        /// Read on each willEnterForeground — not captured — so in-session upgrades are respected.
        public var isPremium: @Sendable () -> Bool

        public init(
            firebase: Firebase? = nil,
            facebook: Facebook = .enabled,
            adjust: AdjustConfig? = nil,
            analytics: AnalyticConfig? = AnalyticConfig(),
            enableRevenueBridge: Bool = true,
            enableResumeAdHandler: Bool = true,
            isPremium: @escaping @Sendable () -> Bool = { false }
        ) {
            self.firebase = firebase
            self.facebook = facebook
            self.adjust = adjust
            self.analytics = analytics
            self.enableRevenueBridge = enableRevenueBridge
            self.enableResumeAdHandler = enableResumeAdHandler
            self.isPremium = isPremium
        }

        /// Convenience constructor for hosts that wire AdsKit by Info.plist convention:
        /// - Firebase: `.plistName("\(firebasePlistPrefix)-Debug")` in DEBUG, `"-Release"` otherwise.
        /// - Facebook: `.enabled` (no-op if `FacebookCore` is not linked).
        /// - Adjust: reads `AdjustAppToken` + `AdjustRevenueEventToken` from `Info.plist`;
        ///   `.sandbox` in DEBUG, `.production` otherwise. Skipped when the token is missing/empty.
        public static func fromInfoPlist(
            firebasePlistPrefix: String = "GoogleService-Info",
            enableRevenueBridge: Bool = true,
            enableResumeAdHandler: Bool = true,
            isPremium: @escaping @Sendable () -> Bool = { false }
        ) -> LaunchConfiguration {
            #if DEBUG
            let plistName = "\(firebasePlistPrefix)-Debug"
            let adjustEnvironment: AdjustClient.Environment = .sandbox
            #else
            let plistName = "\(firebasePlistPrefix)-Release"
            let adjustEnvironment: AdjustClient.Environment = .production
            #endif

            let appToken = Bundle.main.object(forInfoDictionaryKey: "AdjustAppToken") as? String ?? ""
            let revenueToken = Bundle.main.object(forInfoDictionaryKey: "AdjustRevenueEventToken") as? String
            #if DEBUG
            let adjustLogLevel: AdjustClient.LogLevel = .verbose
            #else
            let adjustLogLevel: AdjustClient.LogLevel = .warn
            #endif
            let adjust: AdjustConfig? = appToken.isEmpty
                ? nil
                : AdjustConfig(
                    appToken: appToken,
                    environment: adjustEnvironment,
                    logLevel: adjustLogLevel,
                    revenueEventToken: revenueToken?.isEmpty == true ? nil : revenueToken
                )

            return LaunchConfiguration(
                firebase: .plistName(plistName),
                facebook: .enabled,
                adjust: adjust,
                analytics: AnalyticConfig(),
                enableRevenueBridge: enableRevenueBridge,
                enableResumeAdHandler: enableResumeAdHandler,
                isPremium: isPremium
            )
        }
    }

    @MainActor private static var hasConfigured = false
    @MainActor private static var adRevenueChainTask: Task<Void, Never>?
    @MainActor private static var outcome = AdsKit.ConfigureOutcome()

    /// Awaits the Adjust → revenue-bridge → resume-ad-handler chain started by
    /// `configure(...)` and returns the per-step outcome. Wire into
    /// `Bootstrap.Config.configureGate` so Bootstrap can record the outcome
    /// on State and preloaded ads observe the revenue bridge.
    @MainActor
    public static func adRevenueChainReady() async -> AdsKit.ConfigureOutcome {
        await Self.adRevenueChainTask?.value
        return Self.outcome
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
    ///   4. Adjust.initialize → installRevenueBridge → installResumeAdHandler
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
        if hasConfigured && Self.outcome.noStepFailed {
            Logger.adsKitConfigure.debug("already configured (no failed steps), skipping")
            return
        }

        Logger.adsKitConfigure.info("start")
        if Self.outcome.firebase != true {
            Self.outcome.firebase = configureFirebase(configuration.firebase)
            guard Self.outcome.firebase != false else {
                Logger.adsKitConfigure.fault(
                    "aborting — Firebase configuration failed; downstream init skipped"
                )
                return
            }
        }
        hasConfigured = true

        let firebaseReady = Self.outcome.firebase == true
        configureFacebook(configuration.facebook, application: application, launchOptions: launchOptions)
        initializeAnalytics(configuration.analytics, firebaseReady: firebaseReady)
        startAdjustChain(
            configuration.adjust,
            enableRevenueBridge: configuration.enableRevenueBridge,
            enableResumeAdHandler: configuration.enableResumeAdHandler,
            isPremium: configuration.isPremium
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
        let resumeHandlerEnabled = configuration.enableResumeAdHandler
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
                "resume_handler_enabled": .bool(resumeHandlerEnabled),
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

    @MainActor
    private static func configureFirebase(_ firebase: LaunchConfiguration.Firebase?) -> Bool? {
        guard let firebase else {
            Logger.adsKitConfigure.debug("firebase — skipped (nil configuration)")
            return nil
        }
        switch firebase {
        case .defaultPlist:
            FirebaseApp.configure()
            Logger.adsKitConfigure.info("firebase — configured with default GoogleService-Info.plist")
            return true
        case .plistName(let name):
            guard
                let path = Bundle.main.path(forResource: name, ofType: "plist"),
                let options = FirebaseOptions(contentsOfFile: path)
            else {
                Logger.adsKitConfigure.fault("firebase — MISSING \(name, privacy: .public).plist in main bundle")
                // Telemetry: emit failure event so this is visible in dashboards
                // even when assertionFailure is a no-op in Release.
                @Dependency(\.analyticClient) var analyticClient
                Task {
                    await analyticClient.trackEvent("adskit_configure_error", [
                        "reason": "firebase_plist_missing",
                        "plist_name": .string(name),
                    ])
                    Logger.adsKitConfigure.notice("telemetry: adskit_configure_error emitted (firebase_plist_missing)")
                }
                assertionFailure("[AdsKit] Missing \(name).plist in main bundle")
                return false
            }
            FirebaseApp.configure(options: options)
            Logger.adsKitConfigure.info(
                "firebase — configured with \(name, privacy: .public).plist (projectID=\(options.projectID ?? "?", privacy: .public))"
            )
            return true
        }
    }

    @MainActor
    private static func configureFacebook(
        _ facebook: LaunchConfiguration.Facebook,
        application: UIApplication,
        launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) {
        guard case .enabled = facebook else {
            Logger.adsKitConfigure.info("facebook — disabled")
            return
        }
        #if canImport(FacebookCore)
        // Forward Info.plist values into FB SDK's in-memory settings BEFORE
        // `activateApp` runs its startup `logWarnings()` — the SDK reads the
        // backing field directly there, not the Info.plist, so without this
        // hand-off it warns "currently set to FALSE" even when the plist says TRUE.
        if let enabled = Bundle.main.object(forInfoDictionaryKey: "FacebookAdvertiserIDCollectionEnabled") as? Bool {
            Settings.shared.isAdvertiserIDCollectionEnabled = enabled
        }
        if let enabled = Bundle.main.object(forInfoDictionaryKey: "FacebookAutoLogAppEventsEnabled") as? Bool {
            Settings.shared.isAutoLogAppEventsEnabled = enabled
        }
        ApplicationDelegate.shared.application(
            application,
            didFinishLaunchingWithOptions: launchOptions
        )
        Logger.adsKitConfigure.info("facebook — activateApp dispatched (FacebookCore linked)")
        #else
        Logger.adsKitConfigure.info("facebook — FacebookCore not linked, skipped")
        #endif
    }

    private static func initializeAnalytics(_ config: AnalyticConfig?, firebaseReady: Bool) {
        guard let config else {
            Logger.adsKitConfigure.info("analytics — skipped (no config)")
            return
        }
        // AnalyticClient is Firebase Analytics-backed; instantiating it before
        // FirebaseApp.configure() succeeds is undefined and may crash. Skip
        // cleanly so the host can still bring up Adjust / Facebook in isolation.
        guard firebaseReady else {
            Logger.adsKitConfigure.notice("analytics — skipped (Firebase not configured)")
            return
        }
        Logger.adsKitConfigure.info(
            "analytics — initialize dispatched (collectionEnabled=\(config.collectionEnabled, privacy: .public), userID=\(config.userID ?? "nil", privacy: .public), properties=\(config.userProperties.count, privacy: .public))"
        )
        @Dependency(\.analyticClient) var analyticClient
        Task {
            await analyticClient.initialize(config)
            Logger.adsKitConfigure.info("analytics — initialize completed")
        }
    }

    /// Single chained Task: Adjust init → installRevenueBridge → installResumeAdHandler.
    /// `installRevenueBridge` forwards paid events to Adjust, so it must observe a
    /// ready Adjust SDK — hence the chain rather than parallel Tasks.
    @MainActor
    private static func startAdjustChain(
        _ adjust: AdjustConfig?,
        enableRevenueBridge: Bool,
        enableResumeAdHandler: Bool,
        isPremium: @escaping @Sendable () -> Bool
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
        let previousTask = Self.adRevenueChainTask
        Self.adRevenueChainTask = Task { [adjustClient, mobileAdsClient, analyticClient] in
            // Serialize concurrent retries: wait for any in-flight chain to land
            // its outcome writes before we snapshot.
            await previousTask?.value
            let snapshot = await MainActor.run { Self.outcome }

            let startedAt = Date()
            var adjustInitialized = false
            var revenueBridgeInstalled = false
            var resumeHandlerInstalled = false

            // TODO: AdjustClient / MobileAdsClient calls below are non-throwing,
            // so the `*_initialized` / `*_installed` booleans record only that
            // the await returned. Wrap in do/catch once upstream APIs throw.
            if let adjust, snapshot.adjust != true {
                await adjustClient.initialize(adjust)
                adjustInitialized = true
                await MainActor.run { Self.outcome.adjust = true }
                Logger.adsKitConfigure.info("adjust — initialize completed")
            }
            if enableRevenueBridge, snapshot.revenueBridge != true {
                Logger.adsKitConfigure.info("revenue bridge — install dispatched")
                await mobileAdsClient.installRevenueBridge()
                revenueBridgeInstalled = true
                await MainActor.run { Self.outcome.revenueBridge = true }
                Logger.adsKitConfigure.info("revenue bridge — install completed")
            }
            if enableResumeAdHandler, snapshot.resumeHandler != true {
                Logger.adsKitConfigure.info("resume ad handler — install dispatched")
                await mobileAdsClient.installResumeAdHandler(isPremium)
                resumeHandlerInstalled = true
                await MainActor.run { Self.outcome.resumeHandler = true }
                Logger.adsKitConfigure.info("resume ad handler — install completed")
            }

            let durationMs = Int(Date().timeIntervalSince(startedAt) * 1000)
            // `was_noop` distinguishes a successful chain (all true) from a retry
            // where every step was already done in a prior call (all false because
            // the snapshot guard skipped them). Without this flag a dashboard
            // sees three `false`s and misreads it as total failure.
            let wasNoop = !adjustInitialized && !revenueBridgeInstalled && !resumeHandlerInstalled
            await analyticClient.trackEvent("adskit_configure_chain_completed", [
                "duration_ms": .int(durationMs),
                "adjust_initialized": .bool(adjustInitialized),
                "revenue_bridge_installed": .bool(revenueBridgeInstalled),
                "resume_handler_installed": .bool(resumeHandlerInstalled),
                "was_noop": .bool(wasNoop),
            ])
            Logger.adsKitConfigure.notice(
                "telemetry: adskit_configure_chain_completed emitted (duration_ms=\(durationMs), was_noop=\(wasNoop))"
            )
        }
    }

}
