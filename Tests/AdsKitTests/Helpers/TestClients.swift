import MobileAdsClient
import RemoteConfigClient
import UMPClient

extension MobileAdsClient {
    /// All closures no-op; `shouldShowAd` returns the supplied flag.
    static func bootstrapTest(adReady: Bool = true) -> Self {
        .init(
            requestTrackingAuthorizationIfNeeded: { },
            shouldShowAd: { _, _ in adReady },
            showAd: { _ in },
            preloadAd: { _ in },
            showRewardedAd: { _ in true },
            installRevenueBridge: { },
            showNativeFullScreen: { _ in }
        )
    }
}

extension RemoteConfigClient {
    /// Bootstrap only needs `fetchAndActivateOrUseCache` — wired to no-op.
    static let bootstrapNoop: Self = {
        var client = Self()
        client.fetchAndActivateOrUseCache = { }
        return client
    }()
}

extension UMPClient {
    /// Throws on `requestConsentIfNeeded` — Bootstrap should catch and fall back to `.unknown`.
    static let alwaysThrows: Self = .init(
        requestConsentIfNeeded: { _ in throw TestError.umpFailed },
        consentStatus:          { .unknown },
        canRequestAds:          { false },
        reset:                  { }
    )

    /// Suspends `requestConsentIfNeeded` indefinitely so cancellation tests can
    /// trigger `.cancel` while the bootstrap effect is parked.
    static let neverReturns: Self = .init(
        requestConsentIfNeeded: { _ in
            try await Task.sleep(nanoseconds: 60_000_000_000)   // 60s — long enough that .cancel always lands first
            return .obtained
        },
        consentStatus:          { .unknown },
        canRequestAds:          { false },
        reset:                  { }
    )
}

enum TestError: Error, Equatable {
    case umpFailed
}
