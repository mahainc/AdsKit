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
  - IDFA linker requirement: the host app must force-load the `APMPlatformIdentitySupport` symbol from `GoogleAppMeasurementIdentitySupport` so IDFA logging works (otherwise Firebase logs `I-ACS044003 / IDFA will not be accessible`). See Installation — as of **v0.2.2** this lives in the host app's linker flags, not the package.

## Installation

Pin by version — both products resolve normally:

```swift
.package(url: "https://github.com/mahainc/AdsKit.git", from: "0.4.0"),
```

- `AdsKit` on feature targets (and test/preview targets — it's SDK-free).
- `AdsKitLive` on the app target only.

> **IDFA linker flag (required when using `AdsKitLive`).** Add the following to the
> **host app target's** `Other Linker Flags` (`OTHER_LDFLAGS`). It force-loads
> `APMPlatformIdentitySupport.o` out of `GoogleAppMeasurementIdentitySupport`; without
> it the linker dead-strips the archive and Firebase logs `I-ACS044003 / IDFA will not
> be accessible`:
>
> ```
> -Xlinker -u -Xlinker _OBJC_CLASS_$_APMPlatformIdentitySupport
> ```
>
> Prior to **v0.2.2** this lived inside `AdsKitLive` as a `.unsafeFlags` linker setting,
> which forced consumers to pin by `revision:` (SPM forbids version-resolving a product
> whose target closure contains unsafe flags). Moving the flag to the host app makes
> `AdsKitLive` version-pinnable.

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

### Lifecycle signals

Bootstrap emits actions the host can observe to drive its own UI or side-effects without inferring lifecycle from internal `Phase` ordering:

- **`.attResolved`** *(since v0.4.0)* — sent the moment the ATT prompt resolves, right after `requestTrackingAuthorizationIfNeeded()` returns and **before** the UMP step. Use this to propagate the tracking decision (e.g. flip a mediation SDK's advertiser-tracking flag). It carries no payload — read `ATTrackingManager.trackingAuthorizationStatus` yourself — so the SDK-free `AdsKit` target stays free of the `AppTrackingTransparency` framework.

  ```swift
  // In your host reducer that scopes Bootstrap:
  case .bootstrap(.attResolved):
      let granted = ATTrackingManager.trackingAuthorizationStatus == .authorized
      return .run { _ in await mediationPrivacyClient.setAdvertiserTrackingEnabled(granted) }
  ```

  > Prior to v0.4.0 there was no post-ATT signal — hosts that keyed off `.advance(.preloading)` silently never fired, because `.start` sets `.preloading` by direct mutation and never sends it as an `.advance`.

- **`.consentResolved(UMPConsentStatus)`** — sent after the UMP form completes (when `enableUMP` and the `umpGate` allow it). Use it to gate GDPR-conditional SDKs (analytics collection, etc.).

### `configureGate`

`Config.configureGate` is awaited **between ATT and UMP** so the Configure-side Adjust → revenue-bridge chain (started by `AdsKit.configure(...)`) lands before the launch ad fires — otherwise the ad's paid-impression event can race an un-installed bridge and be dropped. It also returns the per-step `ConfigureOutcome` that Bootstrap stamps into its success telemetry.

*Since v0.4.0* the default is `{ await ConfigureCoordinator.shared.awaitChain() }`, so a host that constructs a raw `Config` is correct out of the box — no need to reach for AdsKitLive's `.live(...)` factory just to avoid losing the wait. `awaitChain()` returns the current (empty) snapshot when `configure(...)` was never called, so tests and previews are unaffected.

  > Prior to v0.4.0 the default was a no-op `{ ConfigureOutcome() }`. Feature modules can't import AdsKitLive (where `.live(...)` lives), so a raw `Config.init` silently skipped the revenue-chain wait and shipped empty `configure_*` telemetry. The new default closes that trap; passing `configureGate:` explicitly still works and documents intent at the call site.

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
