//
//  Bootstrap.swift
//
//  Touches every public surface of the umbrella so any symbol breakage would
//  surface as a compile error during CI. Not a runtime app — compiles only.
//

import AdsKit            // re-exports MobileAdsClient + RemoteConfigClient + UMPClient + AdjustClient + AnalyticClient
import AdsKitLive        // wires all DependencyKey.liveValue
import ComposableArchitecture
import SwiftUI

@MainActor
public enum Bootstrap {

    /// Demo of the TCA `AdsBootstrap` reducer wired against the Live umbrella.
    public static func makeStore() -> StoreOf<AdsBootstrap> {
        Store(initialState: AdsBootstrap.State()) { AdsBootstrap() }
    }

    /// Demo of direct client usage (without the bootstrap reducer).
    public static func directBootstrap() async {
        @Dependency(\.mobileAdsClient) var mobileAdsClient
        @Dependency(\.remoteConfigClient) var remoteConfigClient
        @Dependency(\.umpClient) var umpClient
        @Dependency(\.adjustClient) var adjustClient
        @Dependency(\.analyticClient) var analyticClient

        await mobileAdsClient.requestTrackingAuthorizationIfNeeded()
        _ = try? await umpClient.requestConsentIfNeeded(UMPConfig())
        await remoteConfigClient.fetchAndActivateOrUseCache()
        await adjustClient.initialize(AdjustConfig(appToken: "", environment: .sandbox))
        await mobileAdsClient.installRevenueBridge()

        for await config in remoteConfigClient.adConfigUpdates() {
            await analyticClient.trackEvent("ad_config_update", [
                "showAllAds": .bool(config.showAllAds),
                "interval": .int(config.intervalShowInter),
            ])
        }
    }

    /// Demo of the Effect helpers (runWithAdCheck, showPlacement, reward).
    public static func effectDemo() -> Effect<String> {
        Effect<String>.reward(.watchAds,
            onReward: { send in await send("rewarded") },
            onDismissWithoutReward: { send in await send("dismissed") }
        )
    }

    /// Demo of the NativePlacementView wired to a NativeAdFeature store.
    public static func nativeAd() -> some View {
        NativePlacementView(
            store: Store(initialState: NativeAdFeature.State(placement: .nativeAppearance)) {
                NativeAdFeature(minItemsToShowAd: 6)
            }
        )
    }
}
