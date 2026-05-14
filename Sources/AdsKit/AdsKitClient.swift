//
//  AdsKitClient — TCA dependency façade for everything that happens AFTER
//  `AdsKit.configure(application:launchOptions:)` runs in AppDelegate.
//
//  Why a façade: feature tests used to override five separate clients
//  (mobileAdsClient, umpClient, adjustClient, analyticClient,
//  remoteConfigClient) for any test that touched the ad stack. This client
//  collapses the surface so a single `withDependencies { $0.adsKitClient = ... }`
//  swaps the whole post-init pipeline.
//
//  The shape is deliberately manual (no `@DependencyClient` macro) so the
//  `AdsKit` interface target stays free of a `DependenciesMacros` product
//  dependency. The TestDependencyKey conformance below mimics what the macro
//  generates: a `testValue` whose closures are inert no-ops, so unit tests
//  override only the operations they exercise.
//

import ComposableArchitecture
import Foundation
import MobileAdsClient
import UMPClient
import UIKit

public struct AdsKitClient: Sendable {

    /// Splash-time pipeline. The reducer calls this with a closure that
    /// forwards each phase to the TCA store so UI can observe progress.
    /// Returns `BootstrapResult` so the caller can emit telemetry / surface
    /// the resolved consent status.
    public var runBootstrap: @Sendable (
        _ config: BootstrapConfig,
        _ onPhase: @Sendable (BootstrapPhase) async -> Void
    ) async -> BootstrapResult

    /// Forward `application(_:open:options:)` to Adjust (deep link attribution)
    /// and Facebook (open-URL handling). Returns `true` if Facebook handled
    /// the URL — Adjust is fire-and-forget regardless of the return value.
    public var processOpenURL: @MainActor @Sendable (
        _ url: URL,
        _ application: UIApplication,
        _ options: [UIApplication.OpenURLOptionsKey: Any]
    ) -> Bool

    /// Forward Universal Link activations to Adjust. Returns `true` if a
    /// `webpageURL` was present and forwarded — host may still chain its own
    /// deep-link routing. `@discardableResult` cannot apply to stored
    /// closures, so call sites that don't care: `_ = adsKitClient.processUserActivity(...)`.
    public var processUserActivity: @MainActor @Sendable (
        _ userActivity: NSUserActivity,
        _ application: UIApplication
    ) -> Bool

    /// Runtime ad show — features call this instead of reaching past to
    /// `MobileAdsClient` directly, so tests stub it through `adsKitClient`.
    public var showAd: @Sendable (_ ad: MobileAdsClient.AdType) async throws -> Void

    /// Runtime gate — pairs with `showAd` to auto-load the actor cache.
    public var shouldShowAd: @Sendable (
        _ ad: MobileAdsClient.AdType,
        _ rules: [MobileAdsClient.AdRule]
    ) async -> Bool

    public init(
        runBootstrap: @escaping @Sendable (BootstrapConfig, @Sendable (BootstrapPhase) async -> Void) async -> BootstrapResult = { _, _ in
            BootstrapResult(splashAdShown: false, consent: .unknown)
        },
        processOpenURL: @escaping @MainActor @Sendable (URL, UIApplication, [UIApplication.OpenURLOptionsKey: Any]) -> Bool = { _, _, _ in false },
        processUserActivity: @escaping @MainActor @Sendable (NSUserActivity, UIApplication) -> Bool = { _, _ in false },
        showAd: @escaping @Sendable (MobileAdsClient.AdType) async throws -> Void = { _ in },
        shouldShowAd: @escaping @Sendable (MobileAdsClient.AdType, [MobileAdsClient.AdRule]) async -> Bool = { _, _ in false }
    ) {
        self.runBootstrap = runBootstrap
        self.processOpenURL = processOpenURL
        self.processUserActivity = processUserActivity
        self.showAd = showAd
        self.shouldShowAd = shouldShowAd
    }
}

extension AdsKitClient: TestDependencyKey {
    /// Inert no-ops. Tests override only the operations they exercise.
    public static let testValue = AdsKitClient()
    public static let previewValue = AdsKitClient()
}

extension DependencyValues {
    public var adsKitClient: AdsKitClient {
        get { self[AdsKitClient.self] }
        set { self[AdsKitClient.self] = newValue }
    }
}
