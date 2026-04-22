// swift-tools-version: 6.0
//
// SampleApp — SPM-resolution smoke test for AdsKit.
//
// This package depends on AdsKit by path. Building it proves that:
//   1. The umbrella's path-based deps resolve correctly from an external consumer.
//   2. `@_exported import AdsKit` re-exports every interface symbol.
//   3. `@_exported import AdsKitLive` wires every `DependencyKey.liveValue`.
//
// Build:  cd Example/SampleApp && xcodebuild -scheme SampleApp \
//           -destination 'generic/platform=iOS Simulator' -skipMacroValidation build
//

import PackageDescription

let package = Package(
    name: "SampleApp",
    platforms: [.iOS(.v16)],
    products: [
        .library(name: "SampleApp", targets: ["SampleApp"])
    ],
    dependencies: [
        .package(path: "../.."),
    ],
    targets: [
        .target(
            name: "SampleApp",
            dependencies: [
                .product(name: "AdsKitLive", package: "AdsKit"),
            ]
        )
    ]
)
