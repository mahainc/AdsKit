//
//  AdsKit — umbrella re-export of the five ad-stack interfaces.
//
//  Consumer modules typically need all five clients together (splash flow, feature
//  view that shows an interstitial and logs an analytics event, etc.). Depending on
//  `AdsKit` and writing a single `import AdsKit` pulls every interface without
//  requiring five `.product(...)` entries in the consumer's Package.swift.
//
//  This target is SDK-free — depend on it from test / preview targets to write mocks
//  against the `@Dependency(\.…)` keys without pulling Firebase/Adjust/GoogleMobileAds.
//

@_exported import MobileAdsClient
@_exported import RemoteConfigClient
@_exported import UMPClient
@_exported import AdjustClient
@_exported import AnalyticClient

/// Single namespace for AdsKit's public API.
/// - SDK-free members (the `Bootstrap` reducer) live in this target.
/// - SDK-bound members (`configure(...)`, deep-link forwarders, `LaunchConfiguration`)
///   are added by `AdsKitLive` as extensions on this enum.
public enum AdsKit {}
