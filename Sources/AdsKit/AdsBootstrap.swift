//
//  AdsBootstrap.swift
//  AdsKit
//
//  TCA reducer that replaces the imperative `SplashView.task { await … }` chain.
//  Each phase is explicit in state, individually testable with `TestStore`, and
//  observable so the splash UI can render progress labels.
//
//  Parameterisation:  `Config` flags let consumers opt out of UMP / Adjust / the
//  revenue bridge, and choose between tolerant vs. strict Remote Config fetch.
//  Cancellation:     `.cancel` stops the in-flight `.start` effect without
//  changing state so consumer views can dismiss mid-flow.
//

import ComposableArchitecture
import MobileAdsClient
import RemoteConfigClient
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
            case requestingUMP
            case fetchingRemoteConfig
            case initializingAdjust
            case installingRevenueBridge
            case preloading
            case showingSplashInterstitial
            case done
            case failed(reason: String)

            public var description: String {
                switch self {
                case .idle: return "idle"
                case .requestingATT: return "requestingATT"
                case .requestingUMP: return "requestingUMP"
                case .fetchingRemoteConfig: return "fetchingRemoteConfig"
                case .initializingAdjust: return "initializingAdjust"
                case .installingRevenueBridge: return "installingRevenueBridge"
                case .preloading: return "preloading"
                case .showingSplashInterstitial: return "showingSplashInterstitial"
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
        public let adjust: AdjustConfig
        /// Forwarded to `UMPClient.requestConsentIfNeeded(_:)`. Defaults to
        /// `UMPConfig()` (production: no forced EEA, no test devices). Pass a
        /// custom `UMPConfig(testDeviceIdentifiers: […])` for per-device QA on
        /// Release builds, or `UMPConfig(forceConsentFormForQA: true)` as a
        /// temporary global kill-switch for TestFlight UMP verification. Ignored
        /// when `enableUMP` is `false`.
        public let ump: UMPConfig
        /// Optional app-open ad unit to preload before the splash interstitial. Pass `nil` to skip.
        public let appOpenUnitID: String?
        /// Optional splash interstitial ad unit to show before navigating. Pass `nil` to skip.
        public let splashInterstitialUnitID: String?
        /// When `false`, skip UMP consent entirely (useful in regions where UMP isn't required).
        public let enableUMP: Bool
        /// When `false`, skip `AdjustClient.initialize(_:)`. The RevenueBridge step still runs;
        /// calls to `adjustClient.trackRevenue` will no-op if Adjust wasn't initialised.
        public let enableAdjust: Bool
        /// When `false`, don't register as the ads_swift `AdRevenueDelegate`. Revenue events
        /// from ad impressions won't be forwarded to Adjust / Analytics.
        public let enableRevenueBridge: Bool
        /// When `true` (default), Remote Config fetch errors are swallowed and cached values
        /// are used instead. When `false`, fetch errors bubble via `.didFail` and abort the
        /// remaining phases.
        public let useTolerantFetch: Bool

        public init(
            adjust: AdjustConfig,
            ump: UMPConfig = UMPConfig(),
            appOpenUnitID: String? = nil,
            splashInterstitialUnitID: String? = nil,
            enableUMP: Bool = true,
            enableAdjust: Bool = true,
            enableRevenueBridge: Bool = true,
            useTolerantFetch: Bool = true
        ) {
            self.adjust = adjust
            self.ump = ump
            self.appOpenUnitID = appOpenUnitID
            self.splashInterstitialUnitID = splashInterstitialUnitID
            self.enableUMP = enableUMP
            self.enableAdjust = enableAdjust
            self.enableRevenueBridge = enableRevenueBridge
            self.useTolerantFetch = useTolerantFetch
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
    @Dependency(\.remoteConfigClient) var remoteConfigClient
    @Dependency(\.umpClient) var umpClient
    @Dependency(\.adjustClient) var adjustClient

    public var body: some ReducerOf<Self> {
        Reduce { state, action in
            switch action {
            case let .start(config):
                state.phase = .requestingATT
                return .run { send in
                    await mobileAdsClient.requestTrackingAuthorizationIfNeeded()
                    await send(.advance(.requestingUMP))

                    if config.enableUMP {
                        let consent: UMPConsentStatus
                        do {
                            consent = try await umpClient.requestConsentIfNeeded(config.ump)
                        } catch {
                            consent = .unknown
                        }
                        await send(.consentResolved(consent))
                    }
                    await send(.advance(.fetchingRemoteConfig))

                    if config.useTolerantFetch {
                        await remoteConfigClient.fetchAndActivateOrUseCache()
                    } else {
                        do {
                            try await remoteConfigClient.fetchAndActivate()
                        } catch {
                            await send(.didFail("remote config: \(error.localizedDescription)"))
                            return
                        }
                    }
                    await send(.advance(.initializingAdjust))

                    if config.enableAdjust {
                        await adjustClient.initialize(config.adjust)
                    }
                    await send(.advance(.installingRevenueBridge))

                    if config.enableRevenueBridge {
                        await mobileAdsClient.installRevenueBridge()
                    }
                    await send(.advance(.preloading))

                    if let unitID = config.appOpenUnitID {
                        await mobileAdsClient.preloadAd(.appOpen(unitID))
                    }
                    await send(.advance(.showingSplashInterstitial))

                    if let unitID = config.splashInterstitialUnitID {
                        try? await mobileAdsClient.showAd(.interstitial(unitID))
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
