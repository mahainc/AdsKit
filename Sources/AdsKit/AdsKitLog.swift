//
//  AdsKitLog — OSLog categories used across AdsKit / AdsKitLive.
//
//  Filter in Console.app or `log show` with `subsystem:com.mahainc.AdsKit`.
//  Two categories scope the noise: `configure` is launch-time (one-shot),
//  `bootstrap` is splash-time (per-launch sequence).
//
//  Level convention (apply consistently across both categories):
//    - `.debug`   — internal state transitions of no operational interest (e.g. "already configured, skipping").
//    - `.info`    — phase entry / step dispatched (the steady-state happy-path narrative).
//    - `.notice`  — telemetry emission + non-fatal recoveries the operator should see.
//    - `.error`   — failures that abort the current flow.
//

import OSLog

extension Logger {
    /// Launch-time orchestration (`AdsKit.configure(...)`).
    public static let adsKitConfigure = Logger(subsystem: "com.mahainc.AdsKit", category: "configure")

    /// Splash-time bootstrap sequence (`AdsBootstrap` reducer).
    public static let adsKitBootstrap = Logger(subsystem: "com.mahainc.AdsKit", category: "bootstrap")
}
