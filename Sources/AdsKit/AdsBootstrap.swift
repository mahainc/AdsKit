import ComposableArchitecture
import MobileAdsClient
import UMPClient
import AdjustClient
import AnalyticClient
import OSLog

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
            case installingResumeAdHandler
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
                case .installingResumeAdHandler: return "installingResumeAdHandler"
                case .showingSplashAd: return "showingSplashAd"
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
        public enum SplashAd: Sendable {
            case appOpen(String)
            case interstitial(String)
            case none
        }

        public let adjust: AdjustConfig
        public let ump: UMPConfig
        public let splashAd: SplashAd
        public let preloads: @Sendable () async -> Void
        public let enableUMP: Bool
        public let enableAdjust: Bool
        public let enableRevenueBridge: Bool
        public let enableResumeAdHandler: Bool
        /// Read on each willEnterForeground — not captured — so in-session upgrades are respected.
        public let isPremium: @Sendable () -> Bool

        public init(
            adjust: AdjustConfig,
            ump: UMPConfig = UMPConfig(),
            splashAd: SplashAd = .none,
            preloads: @escaping @Sendable () async -> Void = {},
            enableUMP: Bool = true,
            enableAdjust: Bool = true,
            enableRevenueBridge: Bool = true,
            enableResumeAdHandler: Bool = true,
            isPremium: @escaping @Sendable () -> Bool = { false }
        ) {
            self.adjust = adjust
            self.ump = ump
            self.splashAd = splashAd
            self.preloads = preloads
            self.enableUMP = enableUMP
            self.enableAdjust = enableAdjust
            self.enableRevenueBridge = enableRevenueBridge
            self.enableResumeAdHandler = enableResumeAdHandler
            self.isPremium = isPremium
        }
    }

    public enum Action: Sendable {
        case start(Config)
        case advance(State.Phase)
        case consentResolved(UMPConsentStatus)
        case cancel
        case didFail(String)
    }

    private enum CancelID: Hashable { case bootstrap }

    public init() {}

    @Dependency(\.mobileAdsClient) var mobileAdsClient
    @Dependency(\.umpClient) var umpClient
    @Dependency(\.adjustClient) var adjustClient
    @Dependency(\.analyticClient) var analyticClient

    public var body: some ReducerOf<Self> {
        Reduce { state, action in
            switch action {
            case let .start(config):
                state.phase = .requestingATT
                Logger.adsKitBootstrap.info("phase=requestingATT")
                return .run { send in
                    let startedAt = Date()
                    var lastPhase: State.Phase = .requestingATT
                    var splashAdShown = false
                    var consent: UMPConsentStatus = .unknown

                    do {
                        // Reachability for the outer catch + early-cancel exit.
                        try Task.checkCancellation()

                        await mobileAdsClient.requestTrackingAuthorizationIfNeeded()
                        lastPhase = .preloading
                        Logger.adsKitBootstrap.info("phase=preloading")
                        await send(.advance(.preloading))

                        await config.preloads()

                        if config.enableUMP {
                            lastPhase = .requestingUMP
                            Logger.adsKitBootstrap.info("phase=requestingUMP")
                            await send(.advance(.requestingUMP))
                            do {
                                consent = try await umpClient.requestConsentIfNeeded(config.ump)
                            } catch {
                                Logger.adsKitBootstrap.notice(
                                    "UMP form failed, defaulting to .unknown: \(error.localizedDescription, privacy: .public)"
                                )
                                consent = .unknown
                            }
                            await send(.consentResolved(consent))
                        }

                        if config.enableAdjust {
                            lastPhase = .initializingAdjust
                            Logger.adsKitBootstrap.info("phase=initializingAdjust")
                            await send(.advance(.initializingAdjust))
                            await adjustClient.initialize(config.adjust)
                        }

                        if config.enableRevenueBridge {
                            lastPhase = .installingRevenueBridge
                            Logger.adsKitBootstrap.info("phase=installingRevenueBridge")
                            await send(.advance(.installingRevenueBridge))
                            await mobileAdsClient.installRevenueBridge()
                        }

                        if config.enableResumeAdHandler {
                            lastPhase = .installingResumeAdHandler
                            Logger.adsKitBootstrap.info("phase=installingResumeAdHandler")
                            await send(.advance(.installingResumeAdHandler))
                            await mobileAdsClient.installResumeAdHandler(config.isPremium)
                        }

                        lastPhase = .showingSplashAd
                        Logger.adsKitBootstrap.info("phase=showingSplashAd")
                        await send(.advance(.showingSplashAd))
                        // `shouldShowAd` auto-loads into the actor cache that `showAd` reads from;
                        // `config.preloads` uses a different (legacy ads_swift) pool that `showAd`
                        // does not see, so without this gate the splash ad throws `.adNotReady`.
                        switch config.splashAd {
                        case let .appOpen(unitID):
                            if await mobileAdsClient.shouldShowAd(.appOpen(unitID), []) {
                                do {
                                    try await mobileAdsClient.showAd(.appOpen(unitID))
                                    splashAdShown = true
                                } catch {
                                    Logger.adsKitBootstrap.notice(
                                        "splash appOpen show failed (non-fatal): \(error.localizedDescription, privacy: .public)"
                                    )
                                }
                            }
                        case let .interstitial(unitID):
                            if await mobileAdsClient.shouldShowAd(.interstitial(unitID), []) {
                                do {
                                    try await mobileAdsClient.showAd(.interstitial(unitID))
                                    splashAdShown = true
                                } catch {
                                    Logger.adsKitBootstrap.notice(
                                        "splash interstitial show failed (non-fatal): \(error.localizedDescription, privacy: .public)"
                                    )
                                }
                            }
                        case .none:
                            break
                        }

                        lastPhase = .done
                        Logger.adsKitBootstrap.info("phase=done")
                        await send(.advance(.done))

                        let durationMs = Int(Date().timeIntervalSince(startedAt) * 1000)
                        await analyticClient.trackEvent("adskit_bootstrap_success", [
                            "duration_ms": .int(durationMs),
                            "ump_enabled": .bool(config.enableUMP),
                            "adjust_enabled": .bool(config.enableAdjust),
                            "splash_ad_shown": .bool(splashAdShown),
                            "consent": .string(String(describing: consent)),
                        ])
                        Logger.adsKitBootstrap.notice(
                            "telemetry: adskit_bootstrap_success emitted (duration_ms=\(durationMs), splash_ad_shown=\(splashAdShown))"
                        )
                    } catch is CancellationError {
                        Logger.adsKitBootstrap.debug("bootstrap cancelled")
                    } catch {
                        Logger.adsKitBootstrap.error(
                            "bootstrap failed at phase=\(lastPhase.description, privacy: .public): \(error.localizedDescription, privacy: .public)"
                        )
                        // Emit before `.didFail` so the event captures the phase active at the throw site.
                        await analyticClient.trackEvent("adskit_bootstrap_failed", [
                            "phase": .string(lastPhase.description),
                            "reason": .string(error.localizedDescription),
                        ])
                        Logger.adsKitBootstrap.notice(
                            "telemetry: adskit_bootstrap_failed emitted (phase=\(lastPhase.description, privacy: .public))"
                        )
                        await send(.didFail(error.localizedDescription))
                    }
                }
                .cancellable(id: CancelID.bootstrap)

            case let .advance(phase):
                if case .failed = state.phase { return .none }
                state.phase = phase
                return .none

            case .consentResolved:
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
