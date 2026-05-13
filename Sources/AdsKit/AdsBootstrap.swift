//
//  AdsBootstrap.swift
//  AdsKit
//
//  TCA reducer that initialises the three *reporting* SDKs the app needs on
//  startup: Adjust (attribution), Analytic (Firebase Analytics + Crashlytics),
//  and the AdRevenue bridge (MobileAds → Adjust/Firebase via
//  `AdRevenueTracker.shared.delegate`).
//
//  Sequence is fixed: Adjust → Analytic → AdRevenue → done.
//
//  Everything else — ATT, UMP consent, remote-config fetch, ad preloads,
//  resume-ad observer, splash ad — is the caller's responsibility. The
//  bootstrap doesn't own UI-coupled or lifecycle-coupled work because those
//  decisions belong to the host app, not to a generic init reducer.
//

import ComposableArchitecture
import AdjustClient
import AnalyticClient
import MobileAdsClient // For `installRevenueBridge` only — see AdRevenue phase below.

@Reducer
public struct AdsBootstrap: Sendable {

    @ObservableState
    public struct State: Equatable, Sendable {
        public enum Phase: Equatable, Sendable, CustomStringConvertible {
            case idle
            case initializingAdjust
            case initializingAnalytic
            case installingAdRevenue
            case done
            case failed(reason: String)

            public var description: String {
                switch self {
                case .idle: return "idle"
                case .initializingAdjust: return "initializingAdjust"
                case .initializingAnalytic: return "initializingAnalytic"
                case .installingAdRevenue: return "installingAdRevenue"
                case .done: return "done"
                case let .failed(reason): return "failed(\(reason))"
                }
            }
        }

        public var phase: Phase

        public init(phase: Phase = .idle) {
            self.phase = phase
        }
    }

    public struct Config: Sendable {
        public let adjust: AdjustConfig
        public let analytic: AnalyticConfig
        /// When `false`, skip `AdjustClient.initialize(_:)`. Downstream
        /// `trackRevenue` calls will no-op silently.
        public let enableAdjust: Bool
        /// When `false`, skip `AnalyticClient.initialize(_:)`. Firebase still
        /// auto-initialises on first SDK call from elsewhere in the app.
        public let enableAnalytic: Bool
        /// When `false`, don't register as the ads_swift `AdRevenueDelegate`.
        /// Revenue events from ad impressions won't be forwarded to Adjust /
        /// Analytics.
        public let enableAdRevenue: Bool

        public init(
            adjust: AdjustConfig,
            analytic: AnalyticConfig = AnalyticConfig(),
            enableAdjust: Bool = true,
            enableAnalytic: Bool = true,
            enableAdRevenue: Bool = true
        ) {
            self.adjust = adjust
            self.analytic = analytic
            self.enableAdjust = enableAdjust
            self.enableAnalytic = enableAnalytic
            self.enableAdRevenue = enableAdRevenue
        }
    }

    public enum Action: Sendable {
        case start(Config)
        /// Advance to the next phase after the previous phase's async work completed.
        /// The payload is the phase that is *about to start* (or `.done` when finished).
        case advance(State.Phase)
        /// Abort the in-flight bootstrap effect. State is not mutated — consumer views
        /// typically dismiss after sending this.
        case cancel
        case didFail(String)
    }

    private enum CancelID: Hashable { case bootstrap }

    public init() {}

    @Dependency(\.adjustClient) var adjustClient
    @Dependency(\.analyticClient) var analyticClient
    @Dependency(\.mobileAdsClient) var mobileAdsClient

    public var body: some ReducerOf<Self> {
        Reduce { state, action in
            switch action {
            case let .start(config):
                return .run { send in
                    if config.enableAdjust {
                        await send(.advance(.initializingAdjust))
                        await adjustClient.initialize(config.adjust)
                    }
                    if config.enableAnalytic {
                        await send(.advance(.initializingAnalytic))
                        await analyticClient.initialize(config.analytic)
                    }
                    if config.enableAdRevenue {
                        await send(.advance(.installingAdRevenue))
                        await mobileAdsClient.installRevenueBridge()
                    }
                    await send(.advance(.done))
                }
                .cancellable(id: CancelID.bootstrap)

            case let .advance(phase):
                // Advance only if we haven't failed out of the flow.
                if case .failed = state.phase { return .none }
                state.phase = phase
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
