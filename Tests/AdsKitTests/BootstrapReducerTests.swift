import XCTest
import ComposableArchitecture
@testable import AdsKit
import AnalyticClient
import MobileAdsClient
import RemoteConfigClient
import UMPClient

@MainActor
final class BootstrapReducerTests: XCTestCase {

    // MARK: - Happy path

    func test_happyPath_umpEnabled_noLaunchAd_progressesToDone() async {
        let recorder = AnalyticRecorder()
        let store = TestStore(initialState: AdsKit.Bootstrap.State()) {
            AdsKit.Bootstrap()
        } withDependencies: {
            $0.mobileAdsClient = .bootstrapTest()
            $0.umpClient = .alwaysObtained
            $0.analyticClient = .recording(recorder)
            $0.remoteConfigClient = .bootstrapNoop
        }

        let config = AdsKit.Bootstrap.Config(
            launchAd: .none,
            enableUMP: true,
            primeRemoteConfig: false
        )

        await store.send(.start(config)) {
            $0.phase = .preloading
        }
        await store.receive(\.advance) {
            $0.phase = .requestingATT
        }
        await store.receive(\.configureOutcomeReceived) {
            $0.configureOutcome = AdsKit.ConfigureOutcome()
        }
        await store.receive(\.advance) {
            $0.phase = .requestingUMP
        }
        await store.receive(\.consentResolved) {
            $0.consent = .obtained
        }
        await store.receive(\.advance) {
            $0.phase = .showingLaunchAd
        }
        await store.receive(\.advance) {
            $0.phase = .done
        }
        await store.finish()

        let names = await recorder.names()
        XCTAssertEqual(names, ["adskit_bootstrap_success"])
    }

    func test_telemetryPayload_skippedSteps_emitSkippedString() async {
        let recorder = AnalyticRecorder()
        let store = TestStore(initialState: AdsKit.Bootstrap.State()) {
            AdsKit.Bootstrap()
        } withDependencies: {
            $0.mobileAdsClient = .bootstrapTest()
            $0.umpClient = .alwaysObtained
            $0.analyticClient = .recording(recorder)
            $0.remoteConfigClient = .bootstrapNoop
        }

        let config = AdsKit.Bootstrap.Config(
            launchAd: .none,
            enableUMP: false,
            primeRemoteConfig: false
        )

        await store.send(.start(config)) {
            $0.phase = .preloading
        }
        await store.receive(\.advance) { $0.phase = .requestingATT }
        await store.receive(\.configureOutcomeReceived) { $0.configureOutcome = AdsKit.ConfigureOutcome() }
        await store.receive(\.advance) { $0.phase = .showingLaunchAd }
        await store.receive(\.advance) { $0.phase = .done }
        await store.finish()

        let payload = await recorder.payload(for: "adskit_bootstrap_success")
        XCTAssertEqual(payload?["configure_firebase"], .string("skipped"))
        XCTAssertEqual(payload?["configure_facebook"], .string("skipped"))
        XCTAssertEqual(payload?["configure_analytics"], .string("skipped"))
        XCTAssertEqual(payload?["configure_adjust"], .string("skipped"))
        XCTAssertEqual(payload?["configure_revenue_bridge"], .string("skipped"))
        XCTAssertEqual(payload?["configure_remote_config"], .string("skipped"))
        XCTAssertEqual(payload?["ump_enabled"], .bool(false))
        XCTAssertEqual(payload?["splash_ad_shown"], .bool(false))
    }

    func test_telemetryPayload_successfulSteps_emitSucceededString() async {
        let recorder = AnalyticRecorder()
        let successOutcome = AdsKit.ConfigureOutcome(
            firebase: .succeeded,
            facebook: .succeeded,
            analytics: .succeeded,
            adjust: .succeeded,
            revenueBridge: .succeeded,
            remoteConfig: .succeeded
        )
        let store = TestStore(initialState: AdsKit.Bootstrap.State()) {
            AdsKit.Bootstrap()
        } withDependencies: {
            $0.mobileAdsClient = .bootstrapTest()
            $0.umpClient = .alwaysObtained
            $0.analyticClient = .recording(recorder)
            $0.remoteConfigClient = .bootstrapNoop
        }

        let config = AdsKit.Bootstrap.Config(
            launchAd: .none,
            enableUMP: false,
            configureGate: { successOutcome },
            primeRemoteConfig: false
        )

        await store.send(.start(config)) { $0.phase = .preloading }
        await store.receive(\.advance) { $0.phase = .requestingATT }
        await store.receive(\.configureOutcomeReceived) { $0.configureOutcome = successOutcome }
        await store.receive(\.advance) { $0.phase = .showingLaunchAd }
        await store.receive(\.advance) { $0.phase = .done }
        await store.finish()

        let payload = await recorder.payload(for: "adskit_bootstrap_success")
        XCTAssertEqual(payload?["configure_firebase"], .string("succeeded"))
        XCTAssertEqual(payload?["configure_facebook"], .string("succeeded"))
        XCTAssertEqual(payload?["configure_analytics"], .string("succeeded"))
        XCTAssertEqual(payload?["configure_adjust"], .string("succeeded"))
        XCTAssertEqual(payload?["configure_revenue_bridge"], .string("succeeded"))
        XCTAssertEqual(payload?["configure_remote_config"], .string("succeeded"))
    }

    func test_telemetryPayload_failedFirebase_emitsFailedString() async {
        let recorder = AnalyticRecorder()
        let failedOutcome = AdsKit.ConfigureOutcome(firebase: .failed(reason: "missing plist"))
        let store = TestStore(initialState: AdsKit.Bootstrap.State()) {
            AdsKit.Bootstrap()
        } withDependencies: {
            $0.mobileAdsClient = .bootstrapTest()
            $0.umpClient = .alwaysObtained
            $0.analyticClient = .recording(recorder)
            $0.remoteConfigClient = .bootstrapNoop
        }

        let config = AdsKit.Bootstrap.Config(
            launchAd: .none,
            enableUMP: false,
            configureGate: { failedOutcome },
            primeRemoteConfig: false
        )

        await store.send(.start(config)) { $0.phase = .preloading }
        await store.receive(\.advance) { $0.phase = .requestingATT }
        await store.receive(\.configureOutcomeReceived) { $0.configureOutcome = failedOutcome }
        await store.receive(\.advance) { $0.phase = .showingLaunchAd }
        await store.receive(\.advance) { $0.phase = .done }
        await store.finish()

        let payload = await recorder.payload(for: "adskit_bootstrap_success")
        XCTAssertEqual(payload?["configure_firebase"], .string("failed"))
        XCTAssertEqual(payload?["configure_adjust"], .string("skipped"))
    }

    // MARK: - UMP error path (caught internally → consent = .unknown)

    func test_umpThrows_consentFallsBackToUnknown() async {
        let recorder = AnalyticRecorder()
        // Seed initial consent to .obtained so the fallback-to-.unknown transition is observable.
        let store = TestStore(initialState: AdsKit.Bootstrap.State(consent: .obtained)) {
            AdsKit.Bootstrap()
        } withDependencies: {
            $0.mobileAdsClient = .bootstrapTest()
            $0.umpClient = .alwaysThrows
            $0.analyticClient = .recording(recorder)
            $0.remoteConfigClient = .bootstrapNoop
        }

        let config = AdsKit.Bootstrap.Config(
            launchAd: .none,
            enableUMP: true,
            primeRemoteConfig: false
        )

        await store.send(.start(config)) { $0.phase = .preloading }
        await store.receive(\.advance) { $0.phase = .requestingATT }
        await store.receive(\.configureOutcomeReceived) { $0.configureOutcome = AdsKit.ConfigureOutcome() }
        await store.receive(\.advance) { $0.phase = .requestingUMP }
        await store.receive(\.consentResolved) { $0.consent = .unknown }
        await store.receive(\.advance) { $0.phase = .showingLaunchAd }
        await store.receive(\.advance) { $0.phase = .done }
        await store.finish()

        let names = await recorder.names()
        XCTAssertEqual(names, ["adskit_bootstrap_success"], "UMP error is caught internally; bootstrap still succeeds")
    }

    // MARK: - UMP disabled

    func test_umpDisabled_skipsConsentPhase() async {
        let recorder = AnalyticRecorder()
        let store = TestStore(initialState: AdsKit.Bootstrap.State()) {
            AdsKit.Bootstrap()
        } withDependencies: {
            $0.mobileAdsClient = .bootstrapTest()
            $0.umpClient = .alwaysObtained
            $0.analyticClient = .recording(recorder)
            $0.remoteConfigClient = .bootstrapNoop
        }

        let config = AdsKit.Bootstrap.Config(
            launchAd: .none,
            enableUMP: false,
            primeRemoteConfig: false
        )

        await store.send(.start(config)) { $0.phase = .preloading }
        await store.receive(\.advance) { $0.phase = .requestingATT }
        await store.receive(\.configureOutcomeReceived) { $0.configureOutcome = AdsKit.ConfigureOutcome() }
        await store.receive(\.advance) { $0.phase = .showingLaunchAd }
        await store.receive(\.advance) { $0.phase = .done }
        await store.finish()
    }

    // MARK: - Cancellation

    func test_cancel_stopsEffectAndDoesNotReachDone() async {
        let recorder = AnalyticRecorder()
        let store = TestStore(initialState: AdsKit.Bootstrap.State()) {
            AdsKit.Bootstrap()
        } withDependencies: {
            $0.mobileAdsClient = .bootstrapTest()
            $0.umpClient = .neverReturns          // parks the effect at .requestingUMP
            $0.analyticClient = .recording(recorder)
            $0.remoteConfigClient = .bootstrapNoop
        }
        // Non-exhaustive — actions emitted before .cancel lands are out of scope; we only
        // care that .cancel halts the effect and final state is not .done.
        store.exhaustivity = .off

        let config = AdsKit.Bootstrap.Config(
            launchAd: .none,
            enableUMP: true,                       // engages the UMP step which will hang
            primeRemoteConfig: false
        )

        await store.send(.start(config))
        // Yield a few times so the effect actually reaches the UMP await and parks before we cancel.
        for _ in 0..<5 { await Task.yield() }
        await store.send(.cancel)
        await store.finish()

        XCTAssertNotEqual(store.state.phase, .done, "cancel should prevent the effect from reaching .done")
        let names = await recorder.names()
        XCTAssertFalse(names.contains("adskit_bootstrap_success"), "success telemetry must not fire after cancel")
    }

    // MARK: - Idempotency of phase transitions after .failed

    func test_advance_isNoOpWhenPhaseAlreadyFailed() async {
        let store = TestStore(initialState: AdsKit.Bootstrap.State(phase: .failed(reason: "boom"))) {
            AdsKit.Bootstrap()
        }

        await store.send(.advance(.done))   // no state change expected
        await store.send(.advance(.idle))   // no state change expected
    }

    func test_didFail_setsFailedPhase() async {
        let store = TestStore(initialState: AdsKit.Bootstrap.State()) {
            AdsKit.Bootstrap()
        }

        await store.send(.didFail("network error")) {
            $0.phase = .failed(reason: "network error")
        }
    }

    func test_consentResolved_updatesConsent() async {
        let store = TestStore(initialState: AdsKit.Bootstrap.State()) {
            AdsKit.Bootstrap()
        }

        await store.send(.consentResolved(.obtained)) {
            $0.consent = .obtained
        }
    }

    func test_configureOutcomeReceived_updatesState() async {
        let store = TestStore(initialState: AdsKit.Bootstrap.State()) {
            AdsKit.Bootstrap()
        }

        let outcome = AdsKit.ConfigureOutcome(firebase: .succeeded, adjust: .succeeded)
        await store.send(.configureOutcomeReceived(outcome)) {
            $0.configureOutcome = outcome
        }
    }
}
