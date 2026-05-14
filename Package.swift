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
        .package(url: "https://github.com/mahainc/MobileAdsClient.git", branch: "master"),
        .package(url: "https://github.com/mahainc/RemoteConfigClient.git", branch: "master"),
        .package(url: "https://github.com/mahainc/UMPClient.git", branch: "main"),
        .package(url: "https://github.com/mahainc/AdjustClient.git", branch: "master"),
        .package(url: "https://github.com/mahainc/AnalyticClient.git", branch: "master"),
        .package(url: "https://github.com/firebase/firebase-ios-sdk.git", branch: "main"),
        .package(url: "https://github.com/facebook/facebook-ios-sdk.git", from: "17.0.0"),
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
            ],
            linkerSettings: [
                // Force the host app's link step to pull `APMPlatformIdentitySupport.o` out
                // of the GoogleAppMeasurementIdentitySupport static archive. Without this
                // reference the linker dead-strips the whole archive (no symbol from it is
                // used by Swift code), and Firebase Analytics logs I-ACS044003 / "IDFA will
                // not be accessible" at runtime.
                .unsafeFlags([
                    "-Xlinker", "-u",
                    "-Xlinker", "_OBJC_CLASS_$_APMPlatformIdentitySupport",
                ]),
            ]
        ),
    ]
)

extension Product {
    static func singleTargetLibrary(_ name: String) -> Product {
        .library(name: name, targets: [name])
    }
}
