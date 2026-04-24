//
//  AdsKitCompat.swift
//
//  Deprecated shims that mimic the legacy `swift-ios-guide/Ads/AdMobModule/` API
//  (AdUtil, RemoteConfigManager.shared, AdjustManager.shared, UMPManager.shared,
//  AnalyticsService.shared) while forwarding to the new TCA dependency clients.
//
//  Usage: `import AdsKitCompat` in files mid-migration. You'll get deprecation
//  warnings pointing at the new API. Once the file is migrated, drop the import.
//

import Foundation
import AdsKit
import ComposableArchitecture

// MARK: - AdUtil shim

@available(*, deprecated, message: "Use `@Dependency(\\.mobileAdsClient)` and call `.showPlacement` / `.preloadPlacement` / `.showAd` / `.preloadAd` instead.")
public enum AdUtil {
    @available(*, deprecated, message: "Use `try await mobileAdsClient.showAd(.interstitial(adUnitID))` inside an async context or `Effect.showPlacement(.interRecorder)` in a reducer.")
    public static func showInter(adUnitID: String, onDone: @escaping @Sendable () -> Void) {
        @Dependency(\.mobileAdsClient) var client
        Task {
            try? await client.showAd(.interstitial(adUnitID))
            onDone()
        }
    }

    @available(*, deprecated, message: "Use `await mobileAdsClient.preloadAd(.interstitial(adUnitID))`.")
    public static func preloadInter(adUnitID: String) {
        @Dependency(\.mobileAdsClient) var client
        Task { await client.preloadAd(.interstitial(adUnitID)) }
    }

    @available(*, deprecated, message: "Use `try await mobileAdsClient.showAd(.appOpen(adUnitID))`.")
    public static func showOpen(adUnitID: String, onDone: @escaping @Sendable () -> Void) {
        @Dependency(\.mobileAdsClient) var client
        Task {
            try? await client.showAd(.appOpen(adUnitID))
            onDone()
        }
    }

    @available(*, deprecated, message: "Use `await mobileAdsClient.preloadAd(.appOpen(adUnitID))`.")
    public static func preloadOpen(adUnitID: String) {
        @Dependency(\.mobileAdsClient) var client
        Task { await client.preloadAd(.appOpen(adUnitID)) }
    }

    @available(*, deprecated, message: "Use `let ok = await mobileAdsClient.showRewardPlacement(.watchAds)` or Effect.reward(.watchAds).")
    public static func showReward(adUnitID: String, onDone: @escaping @Sendable (Bool) -> Void) {
        @Dependency(\.mobileAdsClient) var client
        Task {
            do {
                try await client.showAd(.rewarded(adUnitID))
                onDone(true)
            } catch {
                onDone(false)
            }
        }
    }

    @available(*, deprecated, message: "Use `await mobileAdsClient.preloadAd(.rewarded(adUnitID))`.")
    public static func preloadReward(adUnitID: String) {
        @Dependency(\.mobileAdsClient) var client
        Task { await client.preloadAd(.rewarded(adUnitID)) }
    }
}

// MARK: - RemoteConfigManager shim

@available(*, deprecated, message: "Use `@Dependency(\\.remoteConfigClient)` and call `.adConfig()` / `.fetchAndActivate()` directly.")
public enum RemoteConfigManager {
    @available(*, deprecated, message: "Use `@Dependency(\\.remoteConfigClient)` instead of a singleton.")
    public static let shared = RemoteConfigManager.self

    @available(*, deprecated, message: "Use `try await remoteConfigClient.adConfig().showAllAds`.")
    public static func enableAllAds() async -> Bool {
        @Dependency(\.remoteConfigClient) var rc
        return (try? await rc.adConfig().showAllAds) ?? false
    }

    @available(*, deprecated, message: "Use `try await remoteConfigClient.adConfig()`.")
    public static func adConfig() async -> RemoteConfigClient.AdConfig {
        @Dependency(\.remoteConfigClient) var rc
        return (try? await rc.adConfig()) ?? RemoteConfigClient.AdConfig()
    }

    @available(*, deprecated, message: "Use `await remoteConfigClient.fetchAndActivateOrUseCache()` (swallows errors) or `try await remoteConfigClient.fetchAndActivate()`.")
    public static func fetchAndActivate(completed: @escaping @Sendable () -> Void) {
        @Dependency(\.remoteConfigClient) var rc
        Task {
            await rc.fetchAndActivateOrUseCache()
            completed()
        }
    }
}

// MARK: - UMPManager shim

@available(*, deprecated, message: "Use `@Dependency(\\.umpClient)` and call `.requestConsentIfNeeded()`.")
public enum UMPManager {
    @available(*, deprecated, message: "Use `@Dependency(\\.umpClient)` instead of a singleton.")
    public static let shared = UMPManager.self

    @available(*, deprecated, message: "Use `try await umpClient.requestConsentIfNeeded()`.")
    public static func requestConsentIfNeeded() async {
        @Dependency(\.umpClient) var client
        _ = try? await client.requestConsentIfNeeded()
    }
}

// MARK: - AdjustManager shim

@available(*, deprecated, message: "Use `@Dependency(\\.adjustClient)` and call `.initialize(AdjustConfig(...))` / `.trackEvent(...)`.")
public enum AdjustManager {
    @available(*, deprecated, message: "Use `@Dependency(\\.adjustClient)` instead of a singleton.")
    public static let shared = AdjustManager.self

    @available(*, deprecated, message: "Use `await adjustClient.initialize(AdjustConfig(appToken: ..., environment: ...))`.")
    public static func initialize(appToken: String, sandbox: Bool = false, revenueEventToken: String? = nil) {
        @Dependency(\.adjustClient) var client
        Task {
            await client.initialize(
                AdjustConfig(
                    appToken: appToken,
                    environment: sandbox ? .sandbox : .production,
                    revenueEventToken: revenueEventToken
                )
            )
        }
    }

    @available(*, deprecated, message: "Use `await adjustClient.trackEvent(eventToken, params)`.")
    public static func trackEvent(eventToken: String, parameters: [String: String] = [:]) {
        @Dependency(\.adjustClient) var client
        Task { await client.trackEvent(eventToken, parameters) }
    }
}

// MARK: - AnalyticsService shim

@available(*, deprecated, message: "Use `@Dependency(\\.analyticClient)` and pass typed `AnalyticValue` params.")
public enum AnalyticsService {
    @available(*, deprecated, message: "Use `@Dependency(\\.analyticClient)` instead of a singleton.")
    public static let shared = AnalyticsService.self

    @available(*, deprecated, message: "Use `await analyticClient.trackScreen(name, params)`.")
    public static func trackScreen(_ name: String) {
        @Dependency(\.analyticClient) var client
        Task { await client.trackScreen(name, [:]) }
    }

    @available(*, deprecated, message: "Use `await analyticClient.trackEvent(name, params)` with `AnalyticValue` params.")
    public static func track(_ name: String, parameters: [String: String]? = nil) {
        @Dependency(\.analyticClient) var client
        let mapped: [String: AnalyticValue] = (parameters ?? [:]).mapValues { .string($0) }
        Task { await client.trackEvent(name, mapped) }
    }

    @available(*, deprecated, message: "Use `await analyticClient.setUserID(id)`.")
    public static func setUserID(_ id: String) {
        @Dependency(\.analyticClient) var client
        Task { await client.setUserID(id) }
    }

    @available(*, deprecated, message: "Use `await analyticClient.log(msg)`.")
    public static func log(_ message: String) {
        @Dependency(\.analyticClient) var client
        Task { await client.log(message) }
    }

    @available(*, deprecated, message: "Use `await analyticClient.recordError(error, userInfo)` with typed `AnalyticValue` values.")
    public static func recordError(_ error: any Error & Sendable, userInfo: [String: String]? = nil) {
        @Dependency(\.analyticClient) var client
        let mapped: [String: AnalyticValue]? = userInfo?.mapValues { .string($0) }
        Task { await client.recordError(error, mapped) }
    }
}
