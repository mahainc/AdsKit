import ComposableArchitecture
import MobileAdsClient
import UMPClient
import AnalyticClient
import OSLog

extension AdsKit {

    @Reducer
    public struct Bootstrap: Sendable {

        @ObservableState
        public struct State: Equatable, Sendable {
            public enum Phase: Equatable, Sendable, CustomStringConvertible {
                case idle
                case requestingATT
                case preloading
                case requestingUMP
                case showingLaunchAd
                case done
                case failed(reason: String)

                public var description: String {
                    switch self {
                    case .idle: return "idle"
                    case .requestingATT: return "requestingATT"
                    case .preloading: return "preloading"
                    case .requestingUMP: return "requestingUMP"
                    case .showingLaunchAd: return "showingLaunchAd"
                    case .done: return "done"
                    case let .failed(reason): return "failed(\(reason))"
                    }
                }
            }

            public var phase: Phase
            public var configureOutcome: ConfigureOutcome?
            public var consent: UMPConsentStatus

            public init(
                phase: Phase = .idle,
                configureOutcome: ConfigureOutcome? = nil,
                consent: UMPConsentStatus = .unknown
            ) {
                self.phase = phase
                self.configureOutcome = configureOutcome
                self.consent = consent
            }
        }

        public struct Config: Sendable {
            public enum LaunchAd: Sendable {
                case appOpen(String)
                case interstitial(String)
                case none
            }

            public let ump: UMPConfig
            public let launchAd: LaunchAd
            public let preloads: @Sendable () async -> Void
            public let enableUMP: Bool
            /// Awaited between ATT and UMP — gives the Configure-side Adjust →
            /// revenue-bridge → resume-handler chain a chance to land before the
            /// UMP form blocks. Default returns an empty outcome so this target
            /// stays SDK-free; live hosts pass `{ await AdsKit.adRevenueChainReady() }`.
            public let configureGate: @Sendable () async -> ConfigureOutcome
            /// Max time `.showingLaunchAd` waits for the launch ad to land before
            /// giving up. On first install the UMP form eats most of the budget,
            /// leaving too little for AdMob to fetch a fresh interstitial; the
            /// poll-and-wait covers that case. Set to `0` to disable polling.
            public let launchAdLoadTimeout: TimeInterval
            /// Fire-and-forget `remoteConfigClient.fetchAndActivateOrUseCache()`
            /// at the start of the bootstrap effect. Firebase dedupes concurrent
            /// fetches, so this is safe even when the host has its own prime path.
            /// Set to `false` for hosts that handle priming themselves or never
            /// read Remote Config.
            public let primeRemoteConfig: Bool

            public init(
                ump: UMPConfig = UMPConfig(),
                launchAd: LaunchAd = .none,
                preloads: @escaping @Sendable () async -> Void = {},
                enableUMP: Bool = true,
                configureGate: @escaping @Sendable () async -> ConfigureOutcome = { ConfigureOutcome() },
                launchAdLoadTimeout: TimeInterval = 2.0,
                primeRemoteConfig: Bool = true
            ) {
                self.ump = ump
                self.launchAd = launchAd
                self.preloads = preloads
                self.enableUMP = enableUMP
                self.configureGate = configureGate
                self.launchAdLoadTimeout = launchAdLoadTimeout
                self.primeRemoteConfig = primeRemoteConfig
            }
        }

        public enum Action: Sendable {
            case start(Config)
            case advance(State.Phase)
            case configureOutcomeReceived(ConfigureOutcome)
            case consentResolved(UMPConsentStatus)
            case cancel
            case didFail(String)
        }

        private enum CancelID: Hashable { case bootstrap }

        public init() {}

        @Dependency(\.mobileAdsClient) var mobileAdsClient
        @Dependency(\.umpClient) var umpClient
        @Dependency(\.analyticClient) var analyticClient
        @Dependency(\.remoteConfigClient) var remoteConfigClient

        private static func stateString(_ value: Bool?) -> String {
            switch value {
            case .none: return "skipped"
            case .some(true): return "succeeded"
            case .some(false): return "failed"
            }
        }

        public var body: some ReducerOf<Self> {
            Reduce { state, action in
                switch action {
                case let .start(config):
                    state.phase = .preloading
                    Logger.adsKitBootstrap.info("phase=preloading")
                    return .run { send in
                        let startedAt = Date()
                        var lastPhase: State.Phase = .preloading
                        var splashAdShown = false
                        var consent: UMPConsentStatus = .unknown
                        var configureOutcome = ConfigureOutcome()

                        do {
                            // Reachability for the outer catch + early-cancel exit.
                            try Task.checkCancellation()

                            // Step 1 — Remote Config. Serial await so all downstream steps
                            // see the freshly-activated values. The host's preloads closure
                            // is built from `ad_config_v2`, so this must complete first.
                            // Hosts that prime RC themselves can disable via primeRemoteConfig=false.
                            if config.primeRemoteConfig {
                                Logger.adsKitBootstrap.info("remoteConfig — prime dispatched")
                                await remoteConfigClient.fetchAndActivateOrUseCache()
                                Logger.adsKitBootstrap.info("remoteConfig — prime completed")
                            }

                            // Step 2 — Preloads. Kicks the launch ad + back-interstitial +
                            // app-open resume + rewarded loads. In EEA test geography
                            // canRequestAds is false until UMP completes, so the load may
                            // be queued or silently dropped here — the bounded wait at
                            // .showingLaunchAd is the safety net. Non-EEA hosts get a
                            // fully-loaded launch ad by the time .showingLaunchAd fires.
                            await config.preloads()

                            // Step 3 — ATT prompt.
                            lastPhase = .requestingATT
                            Logger.adsKitBootstrap.info("phase=requestingATT")
                            await send(.advance(.requestingATT))
                            await mobileAdsClient.requestTrackingAuthorizationIfNeeded()

                            // Between ATT and UMP — await the configure-side Adjust →
                            // revenue-bridge → resume-handler chain to land so ad-revenue
                            // events fired during the launch ad are forwarded correctly.
                            configureOutcome = await config.configureGate()
                            await send(.configureOutcomeReceived(configureOutcome))

                            // Step 4 — UMP form.
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

                            // Step 5 — Show launch ad (with bounded-wait safety net for
                            // first-install when preloads fired pre-UMP and the load is
                            // still in flight).
                            //
                            // `shouldShowAd` auto-loads into the actor cache that `showAd`
                            // reads from. On first install the preload from `config.preloads`
                            // may still be in flight when this phase fires, so we poll for
                            // up to `config.launchAdLoadTimeout` before giving up.
                            lastPhase = .showingLaunchAd
                            Logger.adsKitBootstrap.info("phase=showingLaunchAd")
                            await send(.advance(.showingLaunchAd))
                            let loadDeadline = Date().addingTimeInterval(config.launchAdLoadTimeout)
                            let pollInterval: UInt64 = 200_000_000   // 200ms
                            let (kind, adType): (String, MobileAdsClient.AdType?) = {
                                switch config.launchAd {
                                case let .appOpen(unitID): return ("appOpen", .appOpen(unitID))
                                case let .interstitial(unitID): return ("interstitial", .interstitial(unitID))
                                case .none: return ("none", nil)
                                }
                            }()
                            if let adType {
                                var ready = await mobileAdsClient.shouldShowAd(adType, [])
                                while !ready && Date() < loadDeadline {
                                    try await Task.sleep(nanoseconds: pollInterval)
                                    ready = await mobileAdsClient.shouldShowAd(adType, [])
                                }
                                if ready {
                                    do {
                                        try await mobileAdsClient.showAd(adType)
                                        splashAdShown = true
                                    } catch {
                                        Logger.adsKitBootstrap.notice(
                                            "launch ad \(kind, privacy: .public) show failed (non-fatal): \(error.localizedDescription, privacy: .public)"
                                        )
                                    }
                                } else {
                                    Logger.adsKitBootstrap.notice(
                                        "launch ad \(kind, privacy: .public) not ready after \(config.launchAdLoadTimeout)s, skipping"
                                    )
                                }
                            }

                            lastPhase = .done
                            Logger.adsKitBootstrap.info("phase=done")
                            await send(.advance(.done))

                            let durationMs = Int(Date().timeIntervalSince(startedAt) * 1000)
                            await analyticClient.trackEvent("adskit_bootstrap_success", [
                                "duration_ms": .int(durationMs),
                                "ump_enabled": .bool(config.enableUMP),
                                "splash_ad_shown": .bool(splashAdShown),
                                "consent": .string(String(describing: consent)),
                                "configure_firebase": .string(Self.stateString(configureOutcome.firebase)),
                                "configure_adjust": .string(Self.stateString(configureOutcome.adjust)),
                                "configure_revenue_bridge": .string(Self.stateString(configureOutcome.revenueBridge)),
                                "configure_resume_handler": .string(Self.stateString(configureOutcome.resumeHandler)),
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
                                "configure_firebase": .string(Self.stateString(configureOutcome.firebase)),
                                "configure_adjust": .string(Self.stateString(configureOutcome.adjust)),
                                "configure_revenue_bridge": .string(Self.stateString(configureOutcome.revenueBridge)),
                                "configure_resume_handler": .string(Self.stateString(configureOutcome.resumeHandler)),
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

                case let .configureOutcomeReceived(outcome):
                    state.configureOutcome = outcome
                    return .none

                case let .consentResolved(status):
                    state.consent = status
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
}
