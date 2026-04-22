# AdsKit Architecture

A TCA-first umbrella over five underlying clients. The umbrella adds no runtime layer — `@_exported import` is compile-time only, so every call from a consumer dispatches directly to the sibling package that owns the SDK.

## Packages

```
AdsKit                  (umbrella, SDK-free)
├── AdsKit              → @_exported imports of the 5 interfaces
│                         + AdsBootstrap: Reducer
└── AdsKitLive          → @_exported imports of the 5 Live impls

MobileAdsClient         → show/preload/placement-aware ads (AdMob via ads_swift)
                          + revenue bridge (ads_swift AdRevenueDelegate → Adjust + Analytic)
                          + Effect.runWithAdCheck / showPlacement / reward
RemoteConfigClient      → Firebase Remote Config fetch + actor cache
                          + AsyncStream<AdConfig> for reactive state
UMPClient               → Google UMP consent flow
AdjustClient            → Adjust SDK init + event/revenue tracking
AnalyticClient          → Firebase Analytics + Crashlytics wrapper
                          + AnalyticValue (String/Int/Double/Bool params)
```

## Three flows

### 1. Cold-start bootstrap

The imperative `.task { await … }` chain is now a TCA reducer (`AdsBootstrap`) — each phase is observable state, fully TestStore-testable.

```
AdsBootstrap.start(Config)
  → state.phase = .requestingATT
  → effect:
       await mobileAdsClient.requestTrackingAuthorizationIfNeeded()
       send(.advance(.requestingUMP))
       try await umpClient.requestConsentIfNeeded()
       send(.consentResolved(status))
       send(.advance(.fetchingRemoteConfig))
       await remoteConfigClient.fetchAndActivateOrUseCache()
       send(.advance(.initializingAdjust))
       await adjustClient.initialize(config.adjust)
       send(.advance(.installingRevenueBridge))
       await mobileAdsClient.installRevenueBridge()
       send(.advance(.preloading))
       await mobileAdsClient.preloadAd(.appOpen(...))
       send(.advance(.showingSplashInterstitial))
       try? await mobileAdsClient.showAd(.interstitial(...))
       send(.advance(.done))
```

File: `AdsKit/Sources/AdsKit/AdsBootstrap.swift`.

### 2. Show interstitial by placement

| Step | File | Behaviour |
|---|---|---|
| 1. Call site | consumer app | `try await mobileAdsClient.showPlacement(.interRecorder, [])` or `Effect.showPlacement(.interRecorder)` |
| 2. Live closure | `MobileAdsClient/Sources/MobileAdsClientLive/Live.swift` | Calls `rules.allRulesSatisfied()`, then `PlacementBridge.show(interPlacement: .interRecorder)` |
| 3. Read Remote Config | `MobileAdsClient/Sources/MobileAdsClientLive/Live.swift` | `@Dependency(\.remoteConfigClient).adConfig()` |
| 4. Cache lookup | `RemoteConfigClient/Sources/RemoteConfigClientLive/Actor.swift` | Returns cached `AdConfig` or decodes `ad_config` JSON |
| 5. Resolve placement | `MobileAdsClient/Sources/MobileAdsClientLive/Live.swift` | `adUnitsConfig.interRecorder.id` + `interAll.extraKeys[placement.remoteConfigKey]` |
| 6. Show on MainActor | same | `ads_swift.AdsManager.shared.showInterstitialAd(adUnitID:, …)` |
| 7. Continuation | same | `VoidResumeOnce` guards double-resume from `onDismissed` + `onFailed` |

Fallback: if `interRecorder.enable == false` → returns silently. If `extraKeys["interRecorder"] == true` AND `interAll.opacity > 0` → uses the preloaded `interAll` unit instead. (The recorder-app JSON has no `interAll.extraKeys`, so the default is always "use interAll when it's preloaded".)

### 3. Revenue callback

```
ads_swift fires AdRevenueTracker.shared.delegate.didTrackAdRevenue(adValue, adUnit, adType)
  ↓
RevenueBridge (@MainActor, in MobileAdsClientLive/Live.swift)
  ↓ extract Sendable primitives (amount, currency, adTypeRaw) eagerly
  ↓ Task {
       await adjustClient.trackRevenue(AdjustRevenue(...))
          → ADJAdRevenue → Adjust.trackAdRevenue
          → optional Adjust.trackEvent(revenueEventToken) if configured
       await analyticClient.trackEvent("ad_revenue", [typed AnalyticValue dict])
          → Analytics.logEvent
    }
```

Concurrency: `didTrackAdRevenue` is `nonisolated` so ads_swift can call it from any thread. The `Task { ... }` captures only Sendable primitives — `AdValue` itself is not captured across the isolation boundary.

## Reactive flow — Remote Config changes

Consumers can subscribe to config updates rather than polling:

```swift
.run { send in
    for await config in remoteConfigClient.adConfigUpdates() {
        await send(.configDidUpdate(config))
    }
}
```

The actor yields the currently-cached `AdConfig` on subscribe, then re-emits every time Firebase pushes an update. Continuations are keyed by UUID and `onTermination` unregisters when the consumer's task cancels.

## State ownership map

| Concern | Where state lives | Isolation |
|---|---|---|
| Bootstrap phase | `AdsBootstrap.State.phase` | reducer (Sendable) |
| Consent status | `AdsBootstrap.State.consentStatus` + `UMPClient.consentStatus()` | reducer / no-op |
| Ad placement readiness | ads_swift `AdsManager.shared` (internal) | reference class; accessed via actor-wrapped closures |
| Remote Config cache | `RemoteConfigActor` | actor |
| Revenue delegate state | `RevenueBridge.shared.isInstalled` | `@MainActor` class |
| Adjust SDK session | `AdjustSdk.Adjust` (static) + `AdjustState` actor (our config capture) | actor for our state |
| Native ad slot | `NativeAdFeature.State` | reducer (Sendable) |

## Target minimums

All packages: Swift 6, iOS 16+.

- `AdsKit` / `RemoteConfigClient` / `AnalyticClient` interfaces are pure Swift — ideal for test targets.
- `AdsKitLive` transitively pulls: Firebase (Remote Config, Analytics, Crashlytics), GoogleMobileAds, UMP, Adjust, ads_swift. Never depend on it from a test target.

## Test story

| Scenario | Recommended approach |
|---|---|
| Unit test a feature reducer that shows an ad | `withDependencies { $0.mobileAdsClient = .testValue }` + spy closure |
| Test bootstrap sequence | `TestStore` with typed-mock clients (happyPath / noop / alwaysObtained) |
| Test Remote Config subscriber | inject `AsyncStream.makeStream()` as `adConfigUpdates` and yield + assert |
| Test reward flow | `$0.mobileAdsClient.showRewardPlacement = { _ in true }` spy |
| Integration smoke-test | `AdsKit/Example/SampleApp` iOS target + simulator |
