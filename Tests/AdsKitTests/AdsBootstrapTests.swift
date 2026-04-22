import Foundation
import Testing
import ComposableArchitecture
@testable import AdsKit

@Suite("AdsBootstrap reducer")
struct AdsBootstrapTests {

    @Test("default config drives phases idle → … → done")
    @MainActor
    func phasesProgress() async throws {
        let store = TestStore(initialState: AdsBootstrap.State()) {
            AdsBootstrap()
        } withDependencies: {
            $0.mobileAdsClient = .testValue
            $0.remoteConfigClient = .happyPath
            $0.umpClient = .alwaysObtained
            $0.adjustClient = .noop
            $0.analyticClient = .noop
        }

        let config = AdsBootstrap.Config(
            adjust: AdjustConfig(appToken: "", environment: .sandbox)
        )

        await store.send(.start(config)) { $0.phase = .requestingATT }
        await store.receive(\.advance) { $0.phase = .requestingUMP }
        await store.receive(\.consentResolved) { $0.consentStatus = .obtained }
        await store.receive(\.advance) { $0.phase = .fetchingRemoteConfig }
        await store.receive(\.advance) { $0.phase = .initializingAdjust }
        await store.receive(\.advance) { $0.phase = .installingRevenueBridge }
        await store.receive(\.advance) { $0.phase = .preloading }
        await store.receive(\.advance) { $0.phase = .showingSplashInterstitial }
        await store.receive(\.advance) { $0.phase = .done }
    }

    @Test("enableUMP=false skips UMP phase — no consentResolved action")
    @MainActor
    func skipUMP() async {
        let store = TestStore(initialState: AdsBootstrap.State()) {
            AdsBootstrap()
        } withDependencies: {
            $0.mobileAdsClient = .testValue
            $0.remoteConfigClient = .happyPath
            $0.umpClient = .alwaysObtained        // should never be consulted
            $0.adjustClient = .noop
            $0.analyticClient = .noop
        }

        let config = AdsBootstrap.Config(
            adjust: AdjustConfig(appToken: "", environment: .sandbox),
            enableUMP: false
        )

        await store.send(.start(config)) { $0.phase = .requestingATT }
        await store.receive(\.advance) { $0.phase = .requestingUMP }
        // No consentResolved — skipped.
        await store.receive(\.advance) { $0.phase = .fetchingRemoteConfig }
        await store.receive(\.advance) { $0.phase = .initializingAdjust }
        await store.receive(\.advance) { $0.phase = .installingRevenueBridge }
        await store.receive(\.advance) { $0.phase = .preloading }
        await store.receive(\.advance) { $0.phase = .showingSplashInterstitial }
        await store.receive(\.advance) { $0.phase = .done }
    }

    @Test("useTolerantFetch=false surfaces fetch error via .didFail")
    @MainActor
    func strictFetchFailure() async {
        struct FetchError: LocalizedError, Sendable {
            var errorDescription: String? { "boom" }
        }

        let store = TestStore(initialState: AdsBootstrap.State()) {
            AdsBootstrap()
        } withDependencies: {
            $0.mobileAdsClient = .testValue
            $0.umpClient = .alwaysObtained
            $0.adjustClient = .noop
            $0.analyticClient = .noop
            $0.remoteConfigClient = .happyPath
            $0.remoteConfigClient.fetchAndActivate = { throw FetchError() }
        }

        let config = AdsBootstrap.Config(
            adjust: AdjustConfig(appToken: "", environment: .sandbox),
            useTolerantFetch: false
        )

        await store.send(.start(config)) { $0.phase = .requestingATT }
        await store.receive(\.advance) { $0.phase = .requestingUMP }
        await store.receive(\.consentResolved) { $0.consentStatus = .obtained }
        await store.receive(\.advance) { $0.phase = .fetchingRemoteConfig }
        await store.receive(\.didFail) {
            $0.phase = .failed(reason: "remote config: boom")
        }
        // No further advances — didFail cancels the effect.
    }

    @Test("cancel stops the in-flight effect — no further phases received")
    @MainActor
    func cancelStopsEffect() async {
        // Make ATT hang forever so we can cancel while in .requestingATT.
        let store = TestStore(initialState: AdsBootstrap.State()) {
            AdsBootstrap()
        } withDependencies: {
            $0.mobileAdsClient = .testValue
            $0.mobileAdsClient.requestTrackingAuthorizationIfNeeded = {
                // Suspend indefinitely; the task will be cancelled before this finishes.
                try? await Task.sleep(nanoseconds: .max)
            }
            $0.remoteConfigClient = .happyPath
            $0.umpClient = .alwaysObtained
            $0.adjustClient = .noop
            $0.analyticClient = .noop
        }

        let config = AdsBootstrap.Config(
            adjust: AdjustConfig(appToken: "", environment: .sandbox)
        )

        await store.send(.start(config)) { $0.phase = .requestingATT }
        // Effect is blocked inside ATT. Send cancel to stop it.
        await store.send(.cancel)
        // No unexpected actions should arrive. TestStore's exhaustive mode enforces this.
    }

    @Test("didFail transitions state to .failed and blocks further phase advances")
    @MainActor
    func failStopsProgress() async {
        let store = TestStore(initialState: AdsBootstrap.State(phase: .requestingATT)) {
            AdsBootstrap()
        }
        await store.send(.didFail("network offline")) {
            $0.phase = .failed(reason: "network offline")
        }
        await store.send(.advance(.done))   // no state change — guard in reducer
    }
}
