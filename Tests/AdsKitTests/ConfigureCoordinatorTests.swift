import XCTest
@testable import AdsKit

final class ConfigureCoordinatorTests: XCTestCase {

    // MARK: - State

    func test_initialState_isNotStartedWithEmptyOutcome() async {
        let coordinator = AdsKit.ConfigureCoordinator()
        let state = await coordinator.currentChainState()
        let outcome = await coordinator.snapshot()
        XCTAssertEqual(state, .notStarted)
        XCTAssertEqual(outcome, AdsKit.ConfigureOutcome())
    }

    func test_awaitChain_beforeStart_returnsCurrentSnapshot() async {
        let coordinator = AdsKit.ConfigureCoordinator()
        let outcome = await coordinator.awaitChain()
        XCTAssertEqual(outcome, AdsKit.ConfigureOutcome())
    }

    // MARK: - Outcome writes

    func test_setFirebase_updatesSnapshot() async {
        let coordinator = AdsKit.ConfigureCoordinator()
        await coordinator.setFirebase(.succeeded)
        let outcome = await coordinator.snapshot()
        XCTAssertEqual(outcome.firebase, .succeeded)
    }

    func test_setFirebase_failed_recordsReason() async {
        let coordinator = AdsKit.ConfigureCoordinator()
        await coordinator.setFirebase(.failed(reason: "missing plist"))
        let outcome = await coordinator.snapshot()
        XCTAssertEqual(outcome.firebase, .failed(reason: "missing plist"))
        XCTAssertFalse(outcome.noStepFailed)
    }

    func test_setAllSteps_accumulateInSnapshot() async {
        let coordinator = AdsKit.ConfigureCoordinator()
        await coordinator.setFirebase(.succeeded)
        await coordinator.setFacebook(.succeeded)
        await coordinator.setAnalytics(.succeeded)
        await coordinator.setAdjust(.succeeded)
        await coordinator.setRevenueBridge(.succeeded)
        await coordinator.setRemoteConfig(.succeeded)
        let outcome = await coordinator.snapshot()
        XCTAssertEqual(outcome.firebase, .succeeded)
        XCTAssertEqual(outcome.facebook, .succeeded)
        XCTAssertEqual(outcome.analytics, .succeeded)
        XCTAssertEqual(outcome.adjust, .succeeded)
        XCTAssertEqual(outcome.revenueBridge, .succeeded)
        XCTAssertEqual(outcome.remoteConfig, .succeeded)
        XCTAssertTrue(outcome.noStepFailed)
    }

    // MARK: - Chain idempotency

    func test_ensureChainStarted_runsWorkExactlyOnce_serial() async {
        let coordinator = AdsKit.ConfigureCoordinator()
        let counter = CallCounter()

        let task1 = await coordinator.ensureChainStarted {
            await counter.increment()
            return AdsKit.ConfigureOutcome(adjust: .succeeded)
        }
        _ = await task1.value

        let task2 = await coordinator.ensureChainStarted {
            await counter.increment()
            return AdsKit.ConfigureOutcome(adjust: .failed(reason: "should not run"))
        }
        _ = await task2.value

        let count = await counter.value
        XCTAssertEqual(count, 1, "second call must reuse the existing task; work closure runs once")
    }

    func test_ensureChainStarted_runsWorkExactlyOnce_concurrent() async {
        let coordinator = AdsKit.ConfigureCoordinator()
        let counter = CallCounter()

        async let t1 = coordinator.ensureChainStarted {
            await counter.increment()
            try? await Task.sleep(nanoseconds: 50_000_000)   // 50ms hold so racer can land
            return AdsKit.ConfigureOutcome(adjust: .succeeded)
        }
        async let t2 = coordinator.ensureChainStarted {
            await counter.increment()
            return AdsKit.ConfigureOutcome(adjust: .failed(reason: "should not run"))
        }
        let _ = await (t1, t2)

        let count = await counter.value
        XCTAssertEqual(count, 1, "concurrent callers see the same task; only the first work closure runs")
    }

    // MARK: - Chain lifecycle

    func test_chainState_transitionsToCompleted() async {
        let coordinator = AdsKit.ConfigureCoordinator()
        let task = await coordinator.ensureChainStarted {
            AdsKit.ConfigureOutcome(firebase: .succeeded, adjust: .succeeded)
        }
        _ = await task.value
        // Allow the markCompleted hook (a sibling Task) to run.
        for _ in 0..<10 { await Task.yield() }

        let state = await coordinator.currentChainState()
        if case let .completed(outcome) = state {
            XCTAssertEqual(outcome.firebase, .succeeded)
            XCTAssertEqual(outcome.adjust, .succeeded)
        } else {
            XCTFail("expected .completed, got \(state)")
        }
    }

    func test_awaitChain_afterStart_returnsChainOutcome() async {
        let coordinator = AdsKit.ConfigureCoordinator()
        let expected = AdsKit.ConfigureOutcome(firebase: .succeeded, revenueBridge: .succeeded)
        _ = await coordinator.ensureChainStarted { expected }
        let actual = await coordinator.awaitChain()
        XCTAssertEqual(actual, expected)
    }

    // MARK: - Reset

    func test_resetForTesting_clearsAllState() async {
        let coordinator = AdsKit.ConfigureCoordinator()
        _ = await coordinator.ensureChainStarted { AdsKit.ConfigureOutcome(adjust: .succeeded) }
        for _ in 0..<10 { await Task.yield() }
        await coordinator.resetForTesting()
        let state = await coordinator.currentChainState()
        let outcome = await coordinator.snapshot()
        XCTAssertEqual(state, .notStarted)
        XCTAssertEqual(outcome, AdsKit.ConfigureOutcome())
    }
}

// MARK: - Helpers

actor CallCounter {
    private(set) var value: Int = 0
    func increment() { value += 1 }
}
