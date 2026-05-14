//
//  AdsBootstrap — thin TCA Reducer over `AdsKitClient.runBootstrap`.
//
//  Owns observable `State.phase` for splash UIs. All orchestration (ATT, UMP,
//  preloads, revenue bridge, resume-ad handler, splash ad, telemetry) lives
//  in `AdsKitClient.liveValue.runBootstrap`. This file is intentionally
//  small — it's the TCA wrapper, not the engine.
//

import ComposableArchitecture
import OSLog

@Reducer
public struct AdsBootstrap: Sendable {

    @ObservableState
    public struct State: Equatable, Sendable {
        /// Back-compat alias — `AdsBootstrap.State.Phase` continues to resolve
        /// for existing call sites that referenced the nested enum.
        public typealias Phase = BootstrapPhase

        public var phase: BootstrapPhase

        public init(phase: BootstrapPhase = .idle) {
            self.phase = phase
        }
    }

    /// Back-compat aliases for consumers that referenced the nested types.
    public typealias Config = BootstrapConfig
    public typealias Result = BootstrapResult

    public enum Action: Sendable {
        case start(BootstrapConfig)
        case advance(BootstrapPhase)
        case finished(BootstrapResult)
        case cancel
        case didFail(String)
    }

    private enum CancelID: Hashable { case bootstrap }

    public init() {}

    @Dependency(\.adsKitClient) var adsKitClient

    public var body: some ReducerOf<Self> {
        Reduce { state, action in
            switch action {
            case let .start(config):
                state.phase = .requestingATT
                Logger.adsKitBootstrap.info("phase=requestingATT")
                return .run { send in
                    let result = await adsKitClient.runBootstrap(config) { phase in
                        await send(.advance(phase))
                    }
                    await send(.finished(result))
                }
                .cancellable(id: CancelID.bootstrap)

            case let .advance(phase):
                if case .failed = state.phase { return .none }
                state.phase = phase
                // `failed` is delivered via `.didFail` so the live engine can
                // emit telemetry first; surface other phases here so UI binds
                // without the client needing to know about TCA.
                if case let .failed(reason) = phase {
                    return .send(.didFail(reason))
                }
                return .none

            case .finished:
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
