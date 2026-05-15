//
//  AdsKitLog — OSLog categories used across AdsKit / AdsKitLive.
//
//  Filter in Console.app or `log show` with `subsystem:com.mahainc.AdsKit`.
//  Two categories scope the noise: `configure` is launch-time (one-shot),
//  `bootstrap` is splash-time (per-launch sequence).
//

import OSLog

extension Logger {
    /// Launch-time orchestration (`AdsKit.configure(...)`).
    public static let adsKitConfigure = Logger(subsystem: "com.mahainc.AdsKit", category: "configure")

    /// Splash-time bootstrap sequence (`AdsKit.Bootstrap` reducer).
    public static let adsKitBootstrap = Logger(subsystem: "com.mahainc.AdsKit", category: "bootstrap")
}
