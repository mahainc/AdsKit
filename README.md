# AdsKit — Complete Guide

A TCA-first umbrella over five ad/analytics dependency clients. One SPM entry, one `import` per file, one `AdsBootstrap` reducer to wire it all up.

---

## Table of contents

1. [What you get](#what-you-get)
2. [Install](#install)
3. [Five-minute quick start](#five-minute-quick-start)
4. [Core concepts](#core-concepts)
5. [App startup with `AdsBootstrap`](#app-startup-with-adsbootstrap)
6. [Showing ads](#showing-ads)
7. [Remote Config](#remote-config)
8. [UMP consent](#ump-consent)
9. [Adjust tracking](#adjust-tracking)
10. [Analytics](#analytics)
11. [Native ads — `NativeAdFeature`](#native-ads--nativeadfeature)
12. [Testing](#testing)
13. [Cancellation & error handling](#cancellation--error-handling)
14. [Migrating from legacy `AdMobModule`](#migrating-from-legacy-admobmodule)
15. [Troubleshooting](#troubleshooting)

See also: [ARCHITECTURE.md](./ARCHITECTURE.md) for call graphs and state-ownership maps.

---

## What you get

Five sibling packages, re-exported through one umbrella:

| Package | Responsibility |
|---|---|
| **MobileAdsClient** | Show / preload / placement-aware ads (AdMob via `ads_swift`) + revenue bridge (`installRevenueBridge()`) |
| **RemoteConfigClient** | Firebase Remote Config fetch + actor cache + `AsyncStream<AdConfig>` |
| **UMPClient** | Google UMP consent flow |
| **AdjustClient** | Adjust SDK init + event / revenue tracking |
| **AnalyticClient** | Firebase Analytics + Crashlytics (typed `AnalyticValue` params) |

Every client:
- is a `@DependencyClient` struct of `@Sendable` async closures
- exposes `testValue`, `previewValue`, and named mocks (`.happyPath`, `.adsDisabled`, `.alwaysObtained`, `.noop`)
- has its own `…Live` target that isolates the underlying SDK import

---

## Install

Add one dependency to your app's `Package.swift`:

```swift
dependencies: [
    .package(path: "../AdsKit"),     // or a git URL, once published
],
targets: [
    .target(
        name: "YourApp",
        dependencies: [
            .product(name: "AdsKitLive", package: "AdsKit"),   // app target: Live impls
        ]
    ),
    .testTarget(
        name: "YourAppTests",
        dependencies: [
            .product(name: "AdsKit", package: "AdsKit"),       // tests: interfaces only, SDK-free
        ]
    )
]
```

**Rule of thumb:** `AdsKit` in test / preview / pure-UI targets, `AdsKitLive` exactly once in the app target.

### Firebase setup (required)

`RemoteConfigClient` and `AnalyticClient` need Firebase initialised before first use. Do it in `AppDelegate`:

```swift
import FirebaseCore

class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ app: UIApplication, didFinishLaunchingWithOptions _: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        FirebaseApp.configure()    // or configure(options:) for Dev/Prod split
        return true
    }
}
```

---

## Five-minute quick start

```swift
import SwiftUI
import ComposableArchitecture
import AdsKit            // interfaces
import AdsKitLive        // wires Live values (import once)

@main
struct YourApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            SplashView(
                store: Store(initialState: AdsBootstrap.State()) { AdsBootstrap() }
            )
        }
    }
}

struct SplashView: View {
    @Bindable var store: StoreOf<AdsBootstrap>

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 16) {
                ProgressView().tint(.white)
                Text(store.phase.description).foregroundStyle(.white.opacity(0.7))
            }
        }
        .task {
            store.send(.start(AdsBootstrap.Config(
                adjust: AdjustConfig(
                    appToken: "YOUR_ADJUST_APP_TOKEN",
                    environment: .production,
                    revenueEventToken: "YOUR_REVENUE_EVENT_TOKEN"
                ),
                appOpenUnitID: "ca-app-pub-…/appopen",
                splashInterstitialUnitID: "ca-app-pub-…/splash"
            )))
        }
        .onChange(of: store.phase) { _, new in
            if new == .done {
                // navigate to home
            }
        }
    }
}
```

That's it. The reducer runs ATT → UMP → Remote Config → Adjust → Revenue bridge → preload → splash interstitial → done, one phase at a time, cancellable and testable.

---

## Core concepts

### `@_exported import`

`import AdsKit` brings every interface symbol (`MobileAdsClient`, `UMPConsentStatus`, `AdjustConfig`, `AnalyticValue`, `AdsBootstrap`, `NativeAdFeature`, …) into scope without five individual imports.

`import AdsKitLive` additionally registers `DependencyKey.liveValue` for each client. Import it once in the app entry point; other files only need `import AdsKit`.

### Interface vs. Live split

`AdsKit` target pulls **no SDKs** — it's pure Swift + TCA. Safe to depend on from test targets, SwiftUI previews, or modules that don't need the underlying AdMob / Firebase / Adjust / UMP binaries.

`AdsKitLive` adds the SDK-bound implementations. Depending on it transitively pulls Firebase, GoogleMobileAds, UMP, Adjust, and `ads_swift`.

### Accessing a client

```swift
struct MyFeature: Reducer {
    @Dependency(\.mobileAdsClient) var mobileAdsClient
    @Dependency(\.remoteConfigClient) var remoteConfigClient
    @Dependency(\.umpClient) var umpClient
    @Dependency(\.adjustClient) var adjustClient
    @Dependency(\.analyticClient) var analyticClient
    // …
}
```

---

## App startup with `AdsBootstrap`

A TCA reducer that sequences the full initialization. State is observable so the splash view can render progress.

### Phases

```
idle → requestingATT → requestingUMP → fetchingRemoteConfig
     → initializingAdjust → installingRevenueBridge
     → preloading → showingSplashInterstitial → done
```

Or terminally: `.failed(reason:)`.

### Config options

```swift
AdsBootstrap.Config(
    adjust: AdjustConfig(appToken: "...", environment: .production),
    ump: UMPConfig(),                                 // see "UMP consent" for QA overrides
    appOpenUnitID: "ca-app-pub-…/appopen",           // nil to skip preload
    splashInterstitialUnitID: "ca-app-pub-…/splash", // nil to skip splash interstitial
    enableUMP: true,                // false = skip UMP (e.g. non-EU-only app)
    enableAdjust: true,             // false = skip Adjust.initSdk
    enableRevenueBridge: true,      // false = don't register AdRevenueDelegate
    useTolerantFetch: true          // false = surface RC fetch errors via .didFail
)
```

### Observing progress

`State.phase` is observable — bind it to the UI:

```swift
Text(store.phase.description)   // "fetchingRemoteConfig" etc.
ProgressView(value: progress(for: store.phase), total: 1.0)
```

### Cancellation

If the user leaves the splash mid-flow:

```swift
.onDisappear { store.send(.cancel) }
```

`.cancel` stops the in-flight effect without changing state. `.didFail` transitions to `.failed(reason:)` AND cancels remaining work.

---

## Showing ads

### By raw ad unit ID

Use when you already know the unit ID:

```swift
@Dependency(\.mobileAdsClient) var mobileAdsClient

try await mobileAdsClient.showAd(.interstitial("ca-app-pub-…/xyz"))
try await mobileAdsClient.showAd(.appOpen("ca-app-pub-…/open"))
try await mobileAdsClient.showAd(.rewarded("ca-app-pub-…/reward"))

await mobileAdsClient.preloadAd(.interstitial("ca-app-pub-…/xyz"))
```

### By placement

Let Remote Config resolve the unit ID + apply fallback rules:

```swift
try await mobileAdsClient.showPlacement(.interRecorder, [])
await mobileAdsClient.preloadPlacement(.interRecorder)

let rewarded: Bool = await mobileAdsClient.showRewardPlacement(.watchAds)
// `true` also when ads are globally disabled (premium flow grants the reward).
```

Placement enums (`AdPlacement`, `RewardPlacement`, `NativeAllPlacement`) map 1-to-1 to Remote Config fields. Use `.remoteConfigKey` if you need the string name.

### `Effect.showPlacement` — TCA-native

```swift
case .closeTapped:
    return .showPlacement(.interRecorder) { send in
        await send(.didClose)
    }
```

Handles ATT + show in one line. Errors propagate to the optional `catch` closure.

### `Effect.reward`

```swift
case .unlockTapped:
    return .reward(.watchAds,
        onReward: { send in await send(.unlocked) },
        onDismissWithoutReward: { send in await send(.rewardSkipped) }
    )
```

### With rules

`AdRule` lets you gate an ad on async conditions (premium check, cooldown, feature flag). Evaluated with priority ordering + early-exit on failure:

```swift
let notPremium = MobileAdsClient.AdRule(name: "free-user", priority: 10) {
    !subscriptionClient.isPremium()
}
let cooldownOK = MobileAdsClient.AdRule(name: "cooldown", priority: 5) {
    await coolDownExpired()
}

try await mobileAdsClient.showPlacement(.interRecorder, [notPremium, cooldownOK])
```

---

## Remote Config

### One-shot read

```swift
let config: RemoteConfigClient.AdConfig = try await remoteConfigClient.adConfig()
if config.useSplashOpen { /* show app-open on splash */ }

let enabled = try await remoteConfigClient.enableAllAds()
```

Typed accessors: `adConfig`, `nativeAllConfig`, `rewardAllConfig`, `enableAllAds`. All are cached after first fetch; `fetchAndActivate()` invalidates the cache and re-yields to subscribers.

### Reactive subscription

For state that needs to react to server-side toggles:

```swift
@Reducer struct HomeFeature {
    enum Action { case task; case configDidUpdate(RemoteConfigClient.AdConfig) }
    @Dependency(\.remoteConfigClient) var remoteConfigClient

    var body: some ReducerOf<Self> {
        Reduce { state, action in
            switch action {
            case .task:
                return .run { send in
                    for await config in remoteConfigClient.adConfigUpdates() {
                        await send(.configDidUpdate(config))
                    }
                }
            case let .configDidUpdate(config):
                state.showsTopButton = config.showTopButton
                return .none
            }
        }
    }
}
```

The stream yields the currently-cached `AdConfig` on subscribe, then re-emits on every Firebase push AND on every manual `fetchAndActivate()`.

### Tolerant vs. strict fetch

```swift
// Strict — throws on network failure, offline, etc.
try await remoteConfigClient.fetchAndActivate()

// Tolerant — swallows errors, logs in DEBUG, falls back to cached/default values.
await remoteConfigClient.fetchAndActivateOrUseCache()
```

---

## UMP consent

### Basic usage

```swift
@Dependency(\.umpClient) var umpClient

let status = try await umpClient.requestConsentIfNeeded(UMPConfig())
// status: .unknown / .required / .notRequired / .obtained

let now = await umpClient.consentStatus()
let canShowAds = await umpClient.canRequestAds()

await umpClient.reset()   // clears cached consent — useful in debug builds
```

`requestConsentIfNeeded(_:)` requests consent info from Google's UMP backend, loads the form if one is available, and presents it when the user's status is `.required` or `.unknown`. It's a no-op for `.notRequired` (non-EEA) and `.obtained` (cached). Diagnostic `[UMP]` logs are printed for every step — visible in Xcode console or via **Console.app** streaming from the device.

### UMPConfig — QA overrides

`UMPConfig` has three fields, all defaulting to production-safe values:

```swift
UMPConfig(
    forceConsentFormForQA: false,   // dev hammer: force .EEA for ALL devices
    testDeviceIdentifiers: [],      // scalpel: force .EEA for listed UUIDs only
    taggedForUnderAgeOfConsent: false
)
```

The live implementation applies a three-tier waterfall:

1. **`forceConsentFormForQA == true`** → `DebugSettings.geography = .EEA` for every device. Use this to verify the splash UMP→ATT flow on a TestFlight/Ad Hoc Release from a non-EEA country. **Must be `false` before App Store submission** — a `true` value tells Google's UMP backend every user is in the EEA, which AdMob will reject for unregistered real devices.
2. **`testDeviceIdentifiers` non-empty** → `DebugSettings.geography = .EEA` + `testDeviceIdentifiers = …`. Scoped override — harmless for shipped builds (only listed UUIDs are affected). Get a device's identifier from the Xcode console on first run — the UMP SDK prints a line like:
   ```
   <UMP SDK>To enable debug mode for this device, set: UMPDebugSettings.testDeviceIdentifiers = @[ @"33BE2250-B412-4F74-9932-76A46CA59CB2" ]
   ```
   Paste the quoted UUID into the array.
3. **`#if DEBUG` fallback** → Debug builds force `.EEA` with no test-device list. Simulators are auto-registered as UMP test devices, so they always see the form.
4. **Release with both overrides off** → `debugSettings` stays `nil`, UMP uses real IP geography (non-EEA → no form; EEA → real consent sheet).

Pass QA configuration through `AdsBootstrap`:

```swift
AdsBootstrap.Config(
    adjust: …,
    ump: UMPConfig(
        testDeviceIdentifiers: ["0942ACDB-517B-4DEA-AD2A-49E0F13BFB7B"]
    ),
    …
)
```

### AdMob Console prerequisites

UMP's `ConsentForm.load` asks Google's backend for the form published for your AdMob app ID (`GADApplicationIdentifier` in Info.plist). **If no GDPR message is published there, UMP returns `formStatus = .unavailable` and no form ever appears** — no code change fixes that, it's AdMob Console configuration:

1. https://apps.admob.com → **Privacy & messaging** → **GDPR**.
2. Find your app (ID must match Info.plist's `GADApplicationIdentifier` exactly).
3. **Create message** → English at minimum, include "Consent" + "Manage options" buttons, default ad partners.
4. **Publish** (must say **Published**, not Draft).
5. Wait 10–15 min for Google's CDN.

Verify via Console.app after a test run:
```
🔍 [UMP] post-update consentStatus=2 formStatus=1 canRequestAds=true
```
`formStatus=1` = `.available` → form will present. `formStatus=2` = `.unavailable` → message not published.

### UMP ↔ ATT timing

`AdsBootstrap` runs **ATT first** (via `MobileAdsClient.requestTrackingAuthorizationIfNeeded()`), **UMP second**. In EEA/test-device paths, UMP presents a modal consent sheet — the modal stabilises the window, so iOS immediately flushes the ATT alert queued from the earlier call once UMP dismisses. Visible sequence: **UMP sheet → tap Consent → ATT alert**. In non-EEA, UMP is a fast no-op (network check only); the queued ATT alert surfaces whenever the next stable window appears (typically after the splash interstitial). Both flows end up with both permissions before the user reaches the first app screen.

### Info.plist requirements (app-side)

Two keys must be present in the consumer app's Info.plist:

```xml
<key>NSUserTrackingUsageDescription</key>
<string>We use this to show you relevant ads and measure ad performance</string>
<key>GADApplicationIdentifier</key>
<string>ca-app-pub-XXXXXXXXXXXXXXXX~XXXXXXXXXX</string>
```

- `NSUserTrackingUsageDescription` is **required by Apple** for any app that calls ATT. Missing key = the alert silently fails AND App Store rejects. The string is the subtitle shown in the system prompt.
- `GADApplicationIdentifier` must match the AdMob app you've published a GDPR message for. Wrong ID = `formStatus=.unavailable` forever.

### Raw enum values (for reading `[UMP]` logs)

```swift
ConsentStatus:
    .unknown     = 0
    .notRequired = 1   // Non-EEA, no form needed
    .required    = 2   // EEA, form must be shown
    .obtained    = 3   // User has answered

FormStatus:
    .unknown     = 0
    .available   = 1   // Form loaded, ready to present
    .unavailable = 2   // No message published / CDN not propagated
```

### Pre-release checklist

Before every App Store submission, run through:

- [ ] `UMPConfig.forceConsentFormForQA` is `false` everywhere it's constructed.
- [ ] `UMPConfig.testDeviceIdentifiers` is empty for production shipping (dev devices removed).
- [ ] AdMob Console has a **Published** GDPR message for the production `GADApplicationIdentifier`.
- [ ] `NSUserTrackingUsageDescription` is present in the final Info.plist (localize per language if your app is localized).
- [ ] Deleted + reinstalled on a real EEA-VPN device → UMP sheet → ATT alert → ads serve.

### Testing matrix

| Scenario | How | Expected |
|---|---|---|
| Simulator Debug | Xcode run | `#if DEBUG` forces `.EEA`. UMP sheet → ATT alert. |
| Physical Debug, registered | `UMPConfig(testDeviceIdentifiers: [idfv])` | Same as simulator. |
| Physical Release, registered | Same `UMPConfig` + Release archive | UMP sheet → ATT alert. Proves code works. |
| Real EEA user | Actual EU IP | UMP sheet → ATT alert. |
| Real non-EEA user | Actual non-EU IP | No UMP sheet, ATT alert only (after splash interstitial). |

Delete + reinstall the app between test runs — iOS persists ATT status and UMP cache across reinstalls otherwise.

---

## Adjust tracking

Initialize once, typically in `AdsBootstrap`:

```swift
await adjustClient.initialize(
    AdjustConfig(
        appToken: "YOUR_APP_TOKEN",
        environment: .production,     // or .sandbox in DEBUG
        logLevel: .info,              // .verbose for debugging
        revenueEventToken: "YOUR_REVENUE_EVENT_TOKEN"    // optional
    )
)
```

Track custom events:

```swift
await adjustClient.trackEvent("abc123", [
    "source": "push_notification",
    "tier": "free",
])
```

Revenue tracking is wired automatically via `MobileAdsClient.installRevenueBridge()` — you don't call `trackRevenue` by hand.

Push tokens:

```swift
func application(_ app: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken data: Data) {
    Task { await adjustClient.setDeviceToken(data) }
}
```

---

## Analytics

Event + screen tracking with typed params:

```swift
@Dependency(\.analyticClient) var analyticClient

// AnalyticValue is ExpressibleBy…Literal for every primitive type
await analyticClient.trackScreen("Home", ["source": "deeplink"])
await analyticClient.trackEvent("purchase", [
    "product_id": "pro.yearly",
    "price": 29.99,                  // Double literal
    "items": 3,                      // Int literal
    "gifted": false,                 // Bool literal
])

await analyticClient.setUserID(userID)
await analyticClient.log("reached checkout")
await analyticClient.recordError(error, ["step": "apply_coupon"])
```

Screen names + event names are passed as plain strings — consumers typically keep their own `enum Screen: String` and call `Screen.home.rawValue`.

---

## Native ads — `NativeAdFeature`

A TCA reducer + SwiftUI view for inserting native ads into a list once the item count crosses a threshold. Race-free by construction.

```swift
import MobileAdsClientUI   // or: import AdsKitLive

@Reducer struct PhotoList {
    @ObservableState struct State: Equatable {
        var items: IdentifiedArrayOf<Photo> = []
        var nativeAd = NativeAdFeature.State(placement: .nativeAppearance)
    }
    enum Action {
        case itemsLoaded([Photo])
        case nativeAd(NativeAdFeature.Action)
    }
    var body: some ReducerOf<Self> {
        Scope(state: \.nativeAd, action: \.nativeAd) {
            NativeAdFeature(minItemsToShowAd: 6)
        }
        Reduce { state, action in
            switch action {
            case let .itemsLoaded(items):
                state.items = IdentifiedArray(uniqueElements: items)
                return .send(.nativeAd(.updateItemCount(state.items.count)))
            case .nativeAd:
                return .none
            }
        }
    }
}

// View side:
ForEach(store.items) { photo in PhotoRow(photo: photo) }
NativePlacementView(
    store: store.scope(state: \.nativeAd, action: \.nativeAd),
    style: .homeAd
)
```

States: `idle → isLoading → hasLoadedViewModel (adUnitID set)` or `→ .disabled` (flag off in Remote Config).

---

## Testing

### Swap clients with named mocks

```swift
import Testing
import ComposableArchitecture
import AdsKit          // SDK-free — perfect for tests

@MainActor
@Test("HomeFeature shows ad after rules pass")
func showsAd() async {
    let store = TestStore(initialState: HomeFeature.State()) { HomeFeature() }
        withDependencies: {
            $0.mobileAdsClient = .testValue       // no-op defaults
            $0.remoteConfigClient = .happyPath    // returns enabled ads
            $0.umpClient = .alwaysObtained
            $0.analyticClient = .noop
        }
    // drive reducer
}
```

### Spy specific closures

```swift
let called = LockIsolated<MobileAdsClient.AdPlacement?>(nil)
$0.mobileAdsClient.showPlacement = { placement, _ in
    called.setValue(placement)
}
```

### Drive a custom stream

```swift
let (stream, continuation) = AsyncStream<RemoteConfigClient.AdConfig>.makeStream()
$0.remoteConfigClient.adConfigUpdates = { stream }

continuation.yield(.init(showAllAds: true))
continuation.yield(.init(showAllAds: false))
continuation.finish()
```

### Named mocks cheat sheet

| Mock | Package | Behaviour |
|---|---|---|
| `.testValue` | every client | All closures return sensible defaults; no SDK contact |
| `.previewValue` | every client | Same, with small delays for preview realism |
| `.happyPath` | RemoteConfigClient | Returns defaults + a one-shot `adConfigUpdates` yield |
| `.adsDisabled` | RemoteConfigClient, MobileAdsClient | `showAllAds == false`, disables native, still grants reward |
| `.alwaysObtained` | UMPClient | Consent always `.obtained` |
| `.alwaysRequired` | UMPClient | Consent always `.required` (blocks ads) |
| `.noop` | AnalyticClient, AdjustClient, RevenueClient | Absorbs every call silently |

### Test a feature end-to-end

```swift
@MainActor
@Test("bootstrap happy path")
func bootstrap() async {
    let store = TestStore(initialState: AdsBootstrap.State()) { AdsBootstrap() }
        withDependencies: {
            $0.mobileAdsClient = .testValue
            $0.remoteConfigClient = .happyPath
            $0.umpClient = .alwaysObtained
            $0.adjustClient = .noop
            $0.analyticClient = .noop
        }

    await store.send(.start(.init(adjust: .init(appToken: "", environment: .sandbox)))) {
        $0.phase = .requestingATT
    }
    await store.receive(\.advance) { $0.phase = .requestingUMP }
    // …
}
```

---

## Cancellation & error handling

### Cancelling bootstrap

```swift
store.send(.cancel)   // stops the effect; state untouched
```

### Strict mode — fail fast on Remote Config error

```swift
AdsBootstrap.Config(
    adjust: ...,
    useTolerantFetch: false   // RC fetch errors → .didFail
)
```

Then observe:

```swift
.onChange(of: store.phase) { _, phase in
    if case let .failed(reason) = phase {
        // show error banner, retry, etc.
    }
}
```

### Ad show errors

`showAd` / `showPlacement` are `async throws`. Common failures:

```swift
do {
    try await mobileAdsClient.showPlacement(.interRecorder, [])
} catch let MobileAdsClient.AdError.adNotReady {
    // no preloaded ad in the pool; skip or retry later
} catch {
    // network / SDK error
}
```

---

## Migrating from legacy `AdMobModule`

If you have files still using `AdUtil`, `RemoteConfigManager.shared`, `UMPManager.shared`, `AdjustManager.shared`, or `AnalyticsService.shared`, add `AdsKitCompat` to migrate file-by-file:

```swift
.product(name: "AdsKitCompat", package: "AdsKit")
```

Then in each legacy file:

```swift
import AdsKitCompat    // adds deprecation warnings

// Old code still compiles — Xcode shows deprecation warnings pointing to the new API.
AdUtil.showInter(adUnitID: cfg.id) { /* done */ }
RemoteConfigManager.shared.fetchAndActivate { /* done */ }
AdjustManager.shared.initialize(appToken: "...")
UMPManager.shared.requestConsentIfNeeded()
AnalyticsService.shared.trackScreen("Home")
```

Once all call sites are migrated, drop `AdsKitCompat` and the legacy imports — you're done.

Full old → new API table: [swift-ios-guide/MIGRATION.md](../swift-ios-guide/MIGRATION.md).

---

## Troubleshooting

### "Firebase app has not been configured"

Call `FirebaseApp.configure()` in `AppDelegate.didFinishLaunching` **before** any `remoteConfigClient` / `analyticClient` access.

### Ads never load in simulator

AdMob requires a device or simulator with network. Use Google's test ad unit IDs in DEBUG builds:
- Interstitial: `ca-app-pub-3940256099942544/4411468910`
- Rewarded: `ca-app-pub-3940256099942544/1712485313`

### UMP form doesn't appear

In order of likelihood, check:

1. **No GDPR message published in AdMob Console.** Look for `🔍 [UMP] post-update … formStatus=2` in the log — `formStatus=2` means `.unavailable`. Fix: create and **Publish** a GDPR message in AdMob Console → Privacy & messaging → GDPR for the app whose ID matches your Info.plist's `GADApplicationIdentifier`. Wait 10–15 min for CDN.
2. **Non-EEA device without an override.** `consentStatus=1` (`.notRequired`) is the log signature. Fix: pass `UMPConfig(testDeviceIdentifiers: [idfv])` (register your device's UMP UUID — the SDK prints it to console on first run) or temporarily `UMPConfig(forceConsentFormForQA: true)`.
3. **Cached consent from a prior run.** `consentStatus=3` (`.obtained`) means the user already consented. Fix: `await umpClient.reset()` before `requestConsentIfNeeded(_:)`, or delete + reinstall the app on device.
4. **Persisted ATT `.denied` blocking the second prompt.** If ATT status is already decided, iOS never re-prompts — only relevant to ATT, not UMP itself, but commonly mistaken for a UMP failure. Fix: delete + reinstall (not just the Settings toggle, which only clears ATT).

See the [UMP consent](#ump-consent) section for the full QA-override waterfall and testing matrix.

### "Macro … was changed since a previous approval" (Xcode)

Pass `-skipMacroValidation` to `xcodebuild` or click "Trust & Enable" in Xcode's macro-approval dialog.

### `ConsentStatus` is ambiguous

`UMPClient` exposes `UMPConsentStatus` (not `ConsentStatus`) precisely to avoid a collision with Google's `UserMessagingPlatform.ConsentStatus`. Use `UMPConsentStatus` everywhere.

### Revenue events aren't appearing in Adjust / Analytics

Ensure `AdsBootstrap.Config.enableRevenueBridge == true` AND `enableAdjust == true`, and that `AdjustClient.initialize` is called before any ad shows. The bridge is idempotent (safe to call multiple times).

### Reducer tests fail with "Expected state to change but no change occurred"

Your `.receive(\.action) { $0.someField = value }` closure must match the reducer's actual mutation. If the reducer doesn't change state for that action, drop the trailing closure.

### Swift 6 strict concurrency warnings on ad callbacks

`@preconcurrency import GoogleMobileAds` and `@preconcurrency import ads_swift` elide Sendable checks at the SDK boundary. In your own code, extract primitives (`Double`, `String`) eagerly before spawning `Task { }` to keep the async body Sendable-clean.

---

## Further reading

- [ARCHITECTURE.md](./ARCHITECTURE.md) — internal call graphs, state ownership, concurrency model
- [swift-ios-guide/MIGRATION.md](../swift-ios-guide/MIGRATION.md) — full legacy → new API mapping
- [swift-ios-guide/Ads/Templates/](../swift-ios-guide/Ads/Templates/) — AppDelegate, Splash, AI integration prompts
- [Example/SampleApp/](./Example/SampleApp/) — minimal SPM consumer that exercises every surface
