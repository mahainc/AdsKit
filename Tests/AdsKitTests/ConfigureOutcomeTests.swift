import XCTest
@testable import AdsKit

final class ConfigureOutcomeTests: XCTestCase {

    // MARK: - StepStatus accessors

    func test_stepStatus_isAccessors_correctlyDiscriminate() {
        XCTAssertTrue(AdsKit.StepStatus.skipped.isSkipped)
        XCTAssertFalse(AdsKit.StepStatus.skipped.isSucceeded)
        XCTAssertFalse(AdsKit.StepStatus.skipped.isFailed)

        XCTAssertFalse(AdsKit.StepStatus.succeeded.isSkipped)
        XCTAssertTrue(AdsKit.StepStatus.succeeded.isSucceeded)
        XCTAssertFalse(AdsKit.StepStatus.succeeded.isFailed)

        let failed = AdsKit.StepStatus.failed(reason: "boom")
        XCTAssertFalse(failed.isSkipped)
        XCTAssertFalse(failed.isSucceeded)
        XCTAssertTrue(failed.isFailed)
    }

    func test_stepStatus_telemetryName_dropsReason() {
        XCTAssertEqual(AdsKit.StepStatus.skipped.telemetryName, "skipped")
        XCTAssertEqual(AdsKit.StepStatus.succeeded.telemetryName, "succeeded")
        XCTAssertEqual(AdsKit.StepStatus.failed(reason: "missing plist").telemetryName, "failed")
    }

    func test_stepStatus_failedReason_isEquatableByReason() {
        let a = AdsKit.StepStatus.failed(reason: "one")
        let b = AdsKit.StepStatus.failed(reason: "one")
        let c = AdsKit.StepStatus.failed(reason: "two")
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
    }

    // MARK: - noStepFailed

    func test_noStepFailed_whenAllSkipped_returnsTrue() {
        let outcome = AdsKit.ConfigureOutcome()
        XCTAssertTrue(outcome.noStepFailed)
    }

    func test_noStepFailed_whenAllSucceeded_returnsTrue() {
        let outcome = AdsKit.ConfigureOutcome(
            firebase: .succeeded,
            facebook: .succeeded,
            analytics: .succeeded,
            adjust: .succeeded,
            revenueBridge: .succeeded,
            remoteConfig: .succeeded
        )
        XCTAssertTrue(outcome.noStepFailed)
    }

    func test_noStepFailed_whenMixedSucceededAndSkipped_returnsTrue() {
        let outcome = AdsKit.ConfigureOutcome(
            firebase: .succeeded,
            adjust: .skipped,
            revenueBridge: .succeeded
        )
        XCTAssertTrue(outcome.noStepFailed)
    }

    func test_noStepFailed_whenFirebaseFailed_returnsFalse() {
        let outcome = AdsKit.ConfigureOutcome(firebase: .failed(reason: "missing plist"))
        XCTAssertFalse(outcome.noStepFailed)
    }

    func test_noStepFailed_whenFacebookFailed_returnsFalse() {
        let outcome = AdsKit.ConfigureOutcome(facebook: .failed(reason: "fb error"))
        XCTAssertFalse(outcome.noStepFailed)
    }

    func test_noStepFailed_whenAnalyticsFailed_returnsFalse() {
        let outcome = AdsKit.ConfigureOutcome(analytics: .failed(reason: "Firebase not configured"))
        XCTAssertFalse(outcome.noStepFailed)
    }

    func test_noStepFailed_whenAdjustFailed_returnsFalse() {
        let outcome = AdsKit.ConfigureOutcome(adjust: .failed(reason: "adjust err"))
        XCTAssertFalse(outcome.noStepFailed)
    }

    func test_noStepFailed_whenRevenueBridgeFailed_returnsFalse() {
        let outcome = AdsKit.ConfigureOutcome(revenueBridge: .failed(reason: "rb err"))
        XCTAssertFalse(outcome.noStepFailed)
    }

    func test_noStepFailed_whenRemoteConfigFailed_returnsFalse() {
        let outcome = AdsKit.ConfigureOutcome(remoteConfig: .failed(reason: "rc err"))
        XCTAssertFalse(outcome.noStepFailed)
    }

    func test_noStepFailed_whenAnyStepFailedAmongstSuccesses_returnsFalse() {
        let outcome = AdsKit.ConfigureOutcome(
            firebase: .succeeded,
            adjust: .succeeded,
            revenueBridge: .failed(reason: "rb err"),
            remoteConfig: .succeeded
        )
        XCTAssertFalse(outcome.noStepFailed)
    }

    // MARK: - Init

    func test_init_defaultsAllStepsToSkipped() {
        let outcome = AdsKit.ConfigureOutcome()
        XCTAssertEqual(outcome.firebase, .skipped)
        XCTAssertEqual(outcome.facebook, .skipped)
        XCTAssertEqual(outcome.analytics, .skipped)
        XCTAssertEqual(outcome.adjust, .skipped)
        XCTAssertEqual(outcome.revenueBridge, .skipped)
        XCTAssertEqual(outcome.remoteConfig, .skipped)
    }

    func test_init_storesAllFields() {
        let outcome = AdsKit.ConfigureOutcome(
            firebase: .succeeded,
            facebook: .failed(reason: "fb"),
            analytics: .skipped,
            adjust: .succeeded,
            revenueBridge: .succeeded,
            remoteConfig: .succeeded
        )
        XCTAssertEqual(outcome.firebase, .succeeded)
        XCTAssertEqual(outcome.facebook, .failed(reason: "fb"))
        XCTAssertEqual(outcome.analytics, .skipped)
    }

    func test_equatable_distinguishesSkippedFromFailed() {
        let skipped = AdsKit.ConfigureOutcome(firebase: .skipped)
        let failed = AdsKit.ConfigureOutcome(firebase: .failed(reason: "x"))
        XCTAssertNotEqual(skipped, failed)
    }
}
