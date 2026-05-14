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
                // Wrapper target — drags `GoogleAppMeasurementIdentitySupport.framework`
                // into the bundle so the linker flag below can find it.
                .product(name: "FirebaseAnalyticsIdentitySupport", package: "firebase-ios-sdk"),
                .product(name: "FacebookCore", package: "facebook-ios-sdk"),
                "AdsKit",
            ],
            linkerSettings: [
                // Force-link `GoogleAppMeasurementIdentitySupport.framework` so
                // dyld actually loads it at startup. Without this, the framework
                // is bundled into Frameworks/ but has no `LC_LOAD_DYLIB` entry —
                // Firebase Analytics then logs `I-ACS044003: IDFA will not be
                // accessible`. The `import` route doesn't work because the
                // wrapper module exposes no Swift symbols.
                .linkedFramework("GoogleAppMeasurementIdentitySupport"),
            ]
        ),
    ]
)

extension Product {
    static func singleTargetLibrary(_ name: String) -> Product {
        .library(name: name, targets: [name])
    }
}
