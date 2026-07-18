// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AdsKit",
    platforms: [
        .iOS(.v16)
    ],
    products: [
        .singleTargetLibrary("AdsKit"),
        .singleTargetLibrary("AdsKitLive"),
    ],
    dependencies: [
        .package(url: "https://github.com/mahainc/MobileAdsClient.git", from: "1.3.0"),
        .package(url: "https://github.com/mahainc/RemoteConfigClient.git", from: "0.1.0"),
        .package(url: "https://github.com/mahainc/UMPClient.git", from: "1.0.1"),
        .package(url: "https://github.com/mahainc/AdjustClient.git", from: "1.0.2"),
        .package(url: "https://github.com/mahainc/AnalyticClient.git", from: "1.1.0"),
        .package(url: "https://github.com/firebase/firebase-ios-sdk.git", from: "12.13.0"),
        .package(url: "https://github.com/facebook/facebook-ios-sdk.git", "17.0.0"..<"19.0.0"),
        .package(url: "https://github.com/pointfreeco/swift-composable-architecture.git", from: "1.25.5"),
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
                .product(name: "ComposableArchitecture", package: "swift-composable-architecture"),
            ]
        ),
        .target(
            name: "AdsKitLive",
            dependencies: [
                .product(name: "MobileAdsClientLive", package: "MobileAdsClient"),
                .product(name: "MobileAdsClientUI", package: "MobileAdsClient"),
                .product(name: "NativeAdClientLive", package: "MobileAdsClient"),
                .product(name: "RemoteConfigClientLive", package: "RemoteConfigClient"),
                .product(name: "UMPClientLive", package: "UMPClient"),
                .product(name: "AdjustClientLive", package: "AdjustClient"),
                .product(name: "AnalyticClientLive", package: "AnalyticClient"),
                .product(name: "FirebaseCore", package: "firebase-ios-sdk"),
                .product(name: "FirebaseAnalyticsIdentitySupport", package: "firebase-ios-sdk"),
                .product(name: "FacebookCore", package: "facebook-ios-sdk"),
                "AdsKit",
            ]
            // NOTE: AdsKitLive previously carried a `.unsafeFlags` linker setting
            // (`-u _OBJC_CLASS_$_APMPlatformIdentitySupport`) to force-load
            // `APMPlatformIdentitySupport.o` out of GoogleAppMeasurementIdentitySupport
            // (otherwise the linker dead-strips it and Firebase logs I-ACS044003 /
            // "IDFA will not be accessible"). Unsafe flags forbid consuming this
            // product via a semver requirement, so that flag now lives in the host
            // app's Other Linker Flags instead, keeping AdsKitLive version-pinnable.
        ),
        .testTarget(
            name: "AdsKitTests",
            dependencies: [
                "AdsKit",
                .product(name: "ComposableArchitecture", package: "swift-composable-architecture"),
            ]
        ),
    ]
)

extension Product {
    static func singleTargetLibrary(_ name: String) -> Product {
        .library(name: name, targets: [name])
    }
}
