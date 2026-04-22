//
//  AdsKitLive — umbrella re-export of the five ad-stack live implementations.
//
//  Depend on this from the app target exactly once: it wires `DependencyKey.liveValue`
//  for every client and transitively pulls in Firebase / Adjust / GoogleMobileAds /
//  ads_swift / UserMessagingPlatform.
//

@_exported import AdsKit
@_exported import MobileAdsClientLive
@_exported import MobileAdsClientUI
@_exported import RemoteConfigClientLive
@_exported import UMPClientLive
@_exported import AdjustClientLive
@_exported import AnalyticClientLive
