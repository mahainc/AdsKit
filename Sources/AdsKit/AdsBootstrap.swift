//
//  AdsBootstrap.swift
//  AdsKit
//
//  TCA reducer that replaces the imperative `SplashView.task { await … }` chain.
//  Each phase is explicit in state, individually testable with `TestStore`, and
//  observable so the splash UI can render progress labels.
//
//  Sequence is fixed: ATT → preload → UMP → Adjust → revenue bridge → show splash ad.
//  Remote Config is the caller's responsibility — fetch + gate before starting.
//

import ComposableArchitecture
import MobileAdsClient
import UMPClient
import AdjustClient
import AnalyticClient

@Reducer
public struct AdsBootstrap: Sendable {

    @ObservableState
    public struct State: Equatable, Sendable {
        public enum Phase: Equatable, Sendable, CustomStringConvertible {
            case idle
            case requestingATT
            case preloading
            case requestingUMP
            case initializingAdjust
            case installingRevenueBridge
            case showingSplashAd
            case done
            case failed(reason: String)

            public var description: String {
                switch self {
                case .idle: return "idle"
                case .requestingATT: return "requestingATT"
                case .preloading: return "preloading"
                case .requestingUMP: return "requestingUMP"
                case .initializingAdjust: return "initializingAdjust"
                case .installingRevenueBridge: return "installingRevenueBridge"
                case .showingSplashAd: return "showingSplashAd"
                case .done: return "done"
                case let .failed(reason): return "failed(\(reason))"
                }
            }
        }

        public var phase: Phase
        public var consentStatus: UMPConsentStatus

        public init(phase: Phase = .idle, consentStatus: UMPConsentStatus = .unknown) {
            self.phase = phase
            self.consentStatus = consentStatus
        }
    }

    public struct Config: Sendable {
        /// Discriminated choice of the ad shown at splash end. Awaited in-band —
        /// `phase` does not advance to `.done` until the ad dismisses.
        public enum SplashAd: Sendable {
            case appOpen(String)
            case interstitial(String)
            case none
        }

        public let adjust: AdjustConfig
        /// Forwarded to `UMPClient.requestConsentIfNeeded(_:)`. Defaults to
        /// `UMPConfig()` (production: no forced EEA, no test devices). Pass a
        /// custom `UMPConfig(testDeviceIdentifiers: […])` for per-device QA on
        /// Release builds, or `UMPConfig(forceConsentFormForQA: true)` as a
        /// temporary global kill-switch for TestFlight UMP verification. Ignored
        /// when `enableUMP` is `false`.
        public let ump: UMPConfig
        /// Splash-end ad. Pass `.none` to skip the show phase.
        public let splashAd: SplashAd
        /// Caller-supplied closure that preloads every ad the app will need
        /// during and after the session (splash ad + resume + reward + inter
        /// pool, etc.). Runs during `.preloading`, awaited in-band so UMP and
        /// the splash show only start after preloads settle.
        public let preloads: @Sendable () async -> Void
        /// When `false`, skip UMP consent entirely (useful in regions where UMP isn't required).
        public let enableUMP: Bool
        /// When `false`, skip `AdjustClient.initialize(_:)`. The RevenueBridge step still runs;
        /// calls to `adjustClient.trackRevenue` will no-op if Adjust wasn't initialised.
        public let enableAdjust: Bool
        /// When `false`, don't register as the ads_swift `AdRevenueDelegate`. Revenue events
        /// from ad impressions won't be forwarded to Adjust / Analytics.
        public let enableRevenueBridge: Bool

        public init(
            adjust: AdjustConfig,
            ump: UMPConfig = UMPConfig(),
            splashAd: SplashAd = .none,
            preloads: @escaping @Sendable () async -> Void = {},
            enableUMP: Bool = true,
            enableAdjust: Bool = true,
            enableRevenueBridge: Bool = true
        ) {
            self.adjust = adjust
            self.ump = ump
            self.splashAd = splashAd
            self.preloads = preloads
            self.enableUMP = enableUMP
            self.enableAdjust = enableAdjust
            self.enableRevenueBridge = enableRevenueBridge
        }
    }

    public enum Action: Sendable {
        case start(Config)
        /// Advance to the next phase after the previous phase's async work completed.
        /// The payload is the phase that is *about to start* (or `.done` when finished).
        case advance(State.Phase)
        case consentResolved(UMPConsentStatus)
        /// Abort the in-flight bootstrap effect. State is not mutated — consumer views
        /// typically dismiss after sending this.
        case cancel
        case didFail(String)
    }

    private enum CancelID: Hashable { case bootstrap }

    public init() {}

    @Dependency(\.mobileAdsClient) var mobileAdsClient
    @Dependency(\.umpClient) var umpClient
    @Dependency(\.adjustClient) var adjustClient

    public var body: some ReducerOf<Self> {
        Reduce { state, action in
            switch action {
            case let .start(config):
                state.phase = .requestingATT
                return .run { send in
                    await mobileAdsClient.requestTrackingAuthorizationIfNeeded()
                    await send(.advance(.preloading))

                    await config.preloads()

                    if config.enableUMP {
                        await send(.advance(.requestingUMP))
                        let consent: UMPConsentStatus
                        do {
                            consent = try await umpClient.requestConsentIfNeeded(config.ump)
                        } catch {
                            consent = .unknown
                        }
                        await send(.consentResolved(consent))
                    }

                    if config.enableAdjust {
                        await send(.advance(.initializingAdjust))
                        await adjustClient.initialize(config.adjust)
                    }

                    if config.enableRevenueBridge {
                        await send(.advance(.installingRevenueBridge))
                        await mobileAdsClient.installRevenueBridge()
                    }

                    await send(.advance(.showingSplashAd))
                    // `shouldShowAd` auto-loads into the actor's ad cache that
                    // `showAd` reads from. The caller's `preloads` closure uses
                    // a different (legacy ads_swift) pool that `showAd` doesn't
                    // see, so without this gate the splash ad would throw
                    // `adNotReady` and `try?` would silently swallow it.
                    switch config.splashAd {
                    case let .appOpen(unitID):
                        if await mobileAdsClient.shouldShowAd(.appOpen(unitID), []) {
                            try? await mobileAdsClient.showAd(.appOpen(unitID))
                        }
                    case let .interstitial(unitID):
                        if await mobileAdsClient.shouldShowAd(.interstitial(unitID), []) {
                            try? await mobileAdsClient.showAd(.interstitial(unitID))
                        }
                    case .none:
                        break
                    }

                    await send(.advance(.done))
                }
                .cancellable(id: CancelID.bootstrap)

            case let .advance(phase):
                // Advance only if we haven't failed out of the flow.
                if case .failed = state.phase { return .none }
                state.phase = phase
                return .none

            case let .consentResolved(status):
                state.consentStatus = status
                return .none

            case .cancel:
                return .cancel(id: CancelID.bootstrap)

            case let .didFail(reason):
                state.phase = .failed(reason: reason)
                return .cancel(id: CancelID.bootstrap)
            }
        }
    }
}
