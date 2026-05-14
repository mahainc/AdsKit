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
                // Linker-only — enables IDFA collection for Firebase Analytics
                // when ATT is granted. No `import` needed in source files.
                .product(name: "FirebaseAnalyticsIdentitySupport", package: "firebase-ios-sdk"),
                .product(name: "FacebookCore", package: "facebook-ios-sdk"),
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
