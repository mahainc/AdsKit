# AdsKit

A **facade package** that bundles the five ad-stack dependency clients used across Maha apps — `MobileAdsClient`, `RemoteConfigClient`, `UMPClient`, `AdjustClient`, `AnalyticClient` — behind one umbrella import plus a TCA `Bootstrap` reducer that orchestrates ATT → preload → UMP consent → launch ad → done.

This is not a single `@DependencyClient` — it's a re-export layer + an orchestration layer. Consumer apps depend on AdsKit (and AdsKitLive on the app target) instead of wiring all five clients individually.

## Layout

- **`AdsKit`** — SDK-free umbrella:
  - `@_exported import` of all 5 client interfaces — one `import AdsKit` gives you `@Dependency(\.mobileAdsClient)`, `@Dependency(\.umpClient)`, etc.
  - `public enum AdsKit {}` namespace.
  - `AdsKit.Bootstrap` reducer — TCA `@Reducer` that walks the splash sequence (ATT request → preload → UMP consent → launch ad → done) with explicit `Phase` enum states.
  - `AdsKit.ConfigureOutcome` value type for surfacing per-SDK configure results.
  - **Safe to import from test / preview targets** — pulls no Firebase / Adjust / GoogleMobileAds binaries.

- **`AdsKitLive`** — SDK-bound:
  - `AdsKit.configure(...)` static (single-call SDK bootstrap: FirebaseApp.configure, AnalyticClient.initialize, MobileAds.start, Adjust SDK init, FBSDK init).
  - Deep-link forwarders (Adjust + Facebook).
  - `LaunchConfiguration` value type for app-launch wiring.
  - Linker workaround: forces `APMPlatformIdentitySupport` symbol from `GoogleAppMeasurementIdentitySupport` so IDFA logging works (otherwise Firebase logs `I-ACS044003 / IDFA will not be accessible`).

## Installation

`AdsKitLive` vends an **unsafe linker flag** (the `APMPlatformIdentitySupport` IDFA
force-link, see below). SPM forbids consuming any product whose target closure contains
unsafe flags via a version requirement, so `AdsKitLive` is **only resolvable by `revision:`
or `branch:`** — `from:` / version ranges fail with *"the target 'AdsKitLive' in product
'AdsKitLive' contains unsafe build flags"*. The SDK-free `AdsKit` umbrella has no unsafe
flags and resolves normally.

Because one package can declare only one requirement per URL, pin the **revision** (the
commit the release tag points at) so both products resolve:

```swift
// Pin the revision the desired release tag points at (here: v0.2.1).
.package(
    url: "https://github.com/mahainc/AdsKit.git",
    revision: "<commit sha of v0.2.1>"
),
```

- `AdsKit` on feature targets (and test/preview targets — it's SDK-free).
- `AdsKitLive` on the app target only.

> If your app never adds `AdsKitLive` (interface-only usage), you may instead pin
> `AdsKit` by version: `.package(url: "…/AdsKit.git", from: "0.2.0")`.

## Usage

```swift
import AdsKit
import AdsKitLive
import ComposableArchitecture

@main
struct MyApp: App {
    init() {
        Task { @MainActor in
            await AdsKit.configure(
                LaunchConfiguration(
                    firebase: .default,
                    adjust: .init(appToken: "abc123", environment: .production),
                    mobileAds: .init(),
                    ump: .init()
                )
            )
        }
    }

    var body: some Scene {
        WindowGroup {
            SplashView(
                store: Store(initialState: AdsKit.Bootstrap.State()) {
                    AdsKit.Bootstrap()
                }
            )
        }
    }
}
```

`AdsKit.Bootstrap` walks the standard splash flow:

```
idle → requestingATT → preloading → requestingUMP → showingLaunchAd → done
                                                              ↓
                                                       failed(reason)
```

The host app owns the policy for resume ads, frequency capping, and gating — Bootstrap only handles the cold-start sequence.

## Deep links

```swift
.onOpenURL { url in
    AdsKit.handleDeepLink(url)   // forwards to Adjust + FBSDK as needed
}
```

## Testing

Because `AdsKit` re-exports the interfaces, override individual clients on a `TestStore`:

```swift
let store = TestStore(initialState: AdsKit.Bootstrap.State()) {
    AdsKit.Bootstrap()
} withDependencies: {
    $0.mobileAdsClient.preloadInterstitial = { }
    $0.umpClient.requestConsentIfNeeded = { _ in .obtained }
    $0.analyticClient.trackEvent = { _, _ in }
}
```

## Dependencies

Internal:
- `MobileAdsClient` from 1.0.3
- `RemoteConfigClient` from 0.1.0
- `UMPClient` from 1.0.1
- `AdjustClient` from 1.0.2
- `AnalyticClient` from 1.1.0

External:
- `firebase-ios-sdk` from 12.13.0 (FirebaseCore + FirebaseAnalyticsIdentitySupport)
- `facebook-ios-sdk` from 17.0.0 (FacebookCore)

## Platform support

- iOS 16+

## License

MIT — see [LICENSE](./LICENSE).
