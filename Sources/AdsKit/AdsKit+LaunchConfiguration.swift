import AdjustClient
import AnalyticClient
import Foundation

extension AdsKit {

    public struct LaunchConfiguration: Sendable {

        public enum Firebase: Sendable, Equatable {
            /// Read `<plistName>.plist` from `Bundle.main` and configure with its options.
            case plistName(String)
            /// Configure with the default `GoogleService-Info.plist` lookup.
            case defaultPlist
        }

        public enum Facebook: Sendable, Equatable {
            case enabled
            case disabled
        }

        public var firebase: Firebase?
        public var facebook: Facebook
        public var adjust: AdjustClient.Config?
        public var analytics: AnalyticConfig?
        public var enableRevenueBridge: Bool

        public init(
            firebase: Firebase? = nil,
            facebook: Facebook = .enabled,
            adjust: AdjustClient.Config? = nil,
            analytics: AnalyticConfig? = AnalyticConfig(),
            enableRevenueBridge: Bool = true
        ) {
            self.firebase = firebase
            self.facebook = facebook
            self.adjust = adjust
            self.analytics = analytics
            self.enableRevenueBridge = enableRevenueBridge
        }

        /// Convenience constructor for hosts that wire AdsKit by Info.plist convention:
        /// - Firebase: `.plistName("\(firebasePlistPrefix)-Debug")` in DEBUG, `"-Release"` otherwise.
        /// - Facebook: `.enabled` (no-op if `FacebookCore` is not linked).
        /// - Adjust: reads `AdjustAppToken` + `AdjustRevenueEventToken` from `Info.plist`;
        ///   `.sandbox` in DEBUG, `.production` otherwise. Skipped when the token is missing/empty.
        public static func fromInfoPlist(
            firebasePlistPrefix: String = "GoogleService-Info",
            enableRevenueBridge: Bool = true
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
            let adjust: AdjustClient.Config? = appToken.isEmpty
                ? nil
                : AdjustClient.Config(
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
                enableRevenueBridge: enableRevenueBridge
            )
        }
    }
}
