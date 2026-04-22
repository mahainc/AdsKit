// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AdsKit",
    platforms: [
        .iOS(.v16)
    ],
    products: [
        /// Interfaces-only bundle. Depend on this from test targets and from any module
        /// that reads `@Dependency(\.mobileAdsClient)` etc. without needing SDK imports.
        .singleTargetLibrary("AdsKit"),
        /// Live bundle. Add this to the app target that actually runs the ad SDKs.
        .singleTargetLibrary("AdsKitLive"),
        /// Deprecated-typealias shims for gradual migration from `AdUtil` / `RemoteConfigManager.shared` /
        /// `AdjustManager.shared` / `UMPManager.shared` / `AnalyticsService.shared`.
        /// Add this only to files that still reference the legacy API; you'll get
        /// `@available(*, deprecated)` warnings pointing at the new dependency clients.
        .singleTargetLibrary("AdsKitCompat"),
    ],
    dependencies: [
        .package(path: "../MobileAdsClient"),
        .package(path: "../RemoteConfigClient"),
        .package(path: "../UMPClient"),
        .package(path: "../AdjustClient"),
        .package(path: "../AnalyticClient"),
    ],
    targets: [
        .target(
            name: "AdsKit",
            dependencies: [
                .product(name: "MobileAdsClient", package: "MobileAdsClient"),
                .product(name: "RemoteConfigClient", package: "RemoteConfigClient"),
                .product(name: "UMPClient", package: "UMPClient"),
                .product(name: "AdjustClient", package: "AdjustClient"),
                .product(name: "AnalyticClient", package: "AnalyticClient"),
            ]
        ),
        .target(
            name: "AdsKitCompat",
            dependencies: ["AdsKit"]
        ),
        .testTarget(
            name: "AdsKitTests",
            dependencies: ["AdsKit"]
        ),
        .target(
            name: "AdsKitLive",
            dependencies: [
                .product(name: "MobileAdsClientLive", package: "MobileAdsClient"),
                .product(name: "MobileAdsClientUI", package: "MobileAdsClient"),
                .product(name: "RemoteConfigClientLive", package: "RemoteConfigClient"),
                .product(name: "UMPClientLive", package: "UMPClient"),
                .product(name: "AdjustClientLive", package: "AdjustClient"),
                .product(name: "AnalyticClientLive", package: "AnalyticClient"),
                "AdsKit",
            ]
        ),
    ]
)

extension Product {
    static func singleTargetLibrary(_ name: String) -> Product {
        .library(name: name, targets: [name])
    }
}
