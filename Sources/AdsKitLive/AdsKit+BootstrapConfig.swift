import AdsKit
import Foundation
import UMPClient

extension AdsKit.Bootstrap.Config {

    /// Live-wired convenience factory: pre-binds `configureGate` to
    /// `AdsKit.adRevenueChainReady()` so the splash flow's `preloads` step
    /// always waits for the Configure-side chain to install the revenue bridge.
    ///
    /// Use this from app targets that have linked `AdsKitLive`. The SDK-free
    /// `Config.init(...)` stays available for tests and previews where the
    /// default no-op gate is appropriate.
    public static func live(
        ump: UMPConfig = UMPConfig(),
        launchAd: LaunchAd = .none,
        preloads: @escaping @Sendable () async -> Void = {},
        enableUMP: Bool = true,
        launchAdLoadTimeout: TimeInterval = 2.0,
        primeRemoteConfig: Bool = true
    ) -> Self {
        .init(
            ump: ump,
            launchAd: launchAd,
            preloads: preloads,
            enableUMP: enableUMP,
            configureGate: { await AdsKit.adRevenueChainReady() },
            launchAdLoadTimeout: launchAdLoadTimeout,
            primeRemoteConfig: primeRemoteConfig
        )
    }
}
