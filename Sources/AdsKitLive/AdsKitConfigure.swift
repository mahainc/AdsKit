//
//  AdsKitConfigure — single launch-time orchestrator for the host app.
//
//  Call `AdsKit.configure(application:launchOptions:)` exactly once from
//  `application(_:didFinishLaunchingWithOptions:)`. Fans out to Firebase
//  (synchronous), Facebook (synchronous, canImport-gated), Adjust SDK init
//  (fire-and-forget Task), and Remote Config priming (background Task).
//
//  Post-init operations — ATT, UMP, ad preloads, the splash ad, deep-link
//  forwarding, runtime ad shows — live behind `@Dependency(\.adsKitClient)`
//  so a single test override swaps the whole pipeline. `AdsBootstrap` is the
//  TCA reducer wrapper over the client's splash-time pipeline.
//
//  Filter traces in Console.app with `subsystem:com.mahainc.AdsKit`.
//

import AdjustClient
import AnalyticClient
import ComposableArchitecture
import FirebaseCore
import OSLog
import RemoteConfigClient
import UIKit

#if canImport(FacebookCore)
import FacebookCore
#endif

public enum AdsKit {

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
        public var primeRemoteConfig: Bool

        public init(
            firebase: Firebase? = nil,
            facebook: Facebook = .enabled,
            adjust: AdjustConfig? = nil,
            analytics: AnalyticConfig? = AnalyticConfig(),
            primeRemoteConfig: Bool = true
        ) {
            self.firebase = firebase
            self.facebook = facebook
            self.adjust = adjust
            self.analytics = analytics
            self.primeRemoteConfig = primeRemoteConfig
        }

        /// Convenience constructor for hosts that wire AdsKit by Info.plist convention:
        /// - Firebase: `.plistName("\(firebasePlistPrefix)-Debug")` in DEBUG, `"-Release"` otherwise.
        /// - Facebook: `.enabled` (no-op if `FacebookCore` is not linked).
        /// - Adjust: reads `AdjustAppToken` + `AdjustRevenueEventToken` from `Info.plist`;
        ///   `.sandbox` in DEBUG, `.production` otherwise. Skipped when the token is missing/empty.
        public static func fromInfoPlist(
            firebasePlistPrefix: String = "GoogleService-Info",
            primeRemoteConfig: Bool = true
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
                primeRemoteConfig: primeRemoteConfig
            )
        }
    }

    @MainActor private static var hasConfigured = false

    /// Single launch-time entry point. Idempotent — subsequent calls are no-ops.
    ///
    /// Order:
    ///   1. Firebase.configure (synchronous; required before Analytics/RemoteConfig)
    ///   2. Facebook activateApp (synchronous; canImport(FacebookCore)-gated)
    ///   3. Analytics.initialize (fire-and-forget Task; must run after Firebase)
    ///   4. Adjust.initialize (fire-and-forget Task)
    ///   5. Remote Config prime (fire-and-forget Task.detached)
    ///
    /// ATT, UMP, ad preloads, and the splash ad continue to run in `AdsBootstrap`.
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
        hasConfigured = true

        Logger.adsKitConfigure.info("start")
        configureFirebase(configuration.firebase)
        configureFacebook(configuration.facebook, application: application, launchOptions: launchOptions)
        initializeAnalytics(configuration.analytics)
        initializeAdjust(configuration.adjust)
        primeRemoteConfig(configuration.primeRemoteConfig)
        Logger.adsKitConfigure.info("done (sync portion)")

        // Telemetry: emit one success event capturing which SDKs were dispatched.
        // Fire-and-forget so a slow analytics backend never blocks launch.
        let firebaseConfigured = configuration.firebase != nil
        let facebookEnabled: Bool = {
            if case .enabled = configuration.facebook { return true } else { return false }
        }()
        let adjustDispatched = configuration.adjust != nil
        let analyticsDispatched = configuration.analytics != nil
        let remoteConfigPrimed = configuration.primeRemoteConfig
        @Dependency(\.analyticClient) var analyticClient
        Task {
            // Firebase reserves the `firebase_` param-name prefix and silently
            // drops anything starting with it (logs I-ACS013008). Use a non-reserved
            // form so the param survives into the Firebase Analytics report.
            await analyticClient.trackEvent("adskit_configure_success", [
                "firebase_dispatched": .bool(firebaseConfigured),
                "facebook_dispatched": .bool(facebookEnabled),
                "adjust_dispatched": .bool(adjustDispatched),
                "analytics_dispatched": .bool(analyticsDispatched),
                "remote_config_dispatched": .bool(remoteConfigPrimed),
            ])
            Logger.adsKitConfigure.notice("telemetry: adskit_configure_success emitted")
        }
    }

    // MARK: - Private

    @MainActor
    private static func configureFirebase(_ firebase: LaunchConfiguration.Firebase?) {
        guard let firebase else {
            Logger.adsKitConfigure.debug("firebase — skipped (nil configuration)")
            return
        }
        switch firebase {
        case .defaultPlist:
            FirebaseApp.configure()
            Logger.adsKitConfigure.info("firebase — configured with default GoogleService-Info.plist")
        case .plistName(let name):
            guard
                let path = Bundle.main.path(forResource: name, ofType: "plist"),
                let options = FirebaseOptions(contentsOfFile: path)
            else {
                Logger.adsKitConfigure.error("firebase — MISSING \(name, privacy: .public).plist in main bundle")
                // Telemetry: emit failure event so this is visible in dashboards
                // even when assertionFailure is a no-op in Release.
                @Dependency(\.analyticClient) var analyticClient
                Task {
                    await analyticClient.trackEvent("adskit_configure_failed", [
                        "reason": "firebase_plist_missing",
                        "plist_name": .string(name),
                    ])
                    Logger.adsKitConfigure.notice("telemetry: adskit_configure_failed emitted (firebase_plist_missing)")
                }
                assertionFailure("[AdsKit] Missing \(name).plist in main bundle")
                return
            }
            FirebaseApp.configure(options: options)
            Logger.adsKitConfigure.info(
                "firebase — configured with \(name, privacy: .public).plist (projectID=\(options.projectID ?? "?", privacy: .public))"
            )
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

    private static func initializeAnalytics(_ config: AnalyticConfig?) {
        guard let config else {
            Logger.adsKitConfigure.info("analytics — skipped (no config)")
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

    private static func initializeAdjust(_ config: AdjustConfig?) {
        guard let config else {
            Logger.adsKitConfigure.info("adjust — skipped (no token)")
            return
        }
        Logger.adsKitConfigure.info(
            "adjust — initialize dispatched (env=\(String(describing: config.environment), privacy: .public), token=\(config.appToken.prefix(4), privacy: .public)…)"
        )
        @Dependency(\.adjustClient) var adjustClient
        Task {
            await adjustClient.initialize(config)
            Logger.adsKitConfigure.info("adjust — initialize completed")
        }
    }

    private static func primeRemoteConfig(_ enabled: Bool) {
        guard enabled else {
            Logger.adsKitConfigure.debug("remoteConfig — prime skipped")
            return
        }
        Logger.adsKitConfigure.info("remoteConfig — prime dispatched")
        @Dependency(\.remoteConfigClient) var remoteConfigClient
        Task.detached(priority: .utility) {
            await remoteConfigClient.fetchAndActivateOrUseCache()
            Logger.adsKitConfigure.info("remoteConfig — prime completed")
        }
    }
}
