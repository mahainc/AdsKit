import XCTest
@testable import AdsKit

final class FirebaseConfiguratorTests: XCTestCase {

    // MARK: - resolveFirebaseOutcome

    func test_resolveFirebaseOutcome_nilSource_returnsSkipped() {
        let configurator = FirebaseConfigurator(
            configureWithPlist: { _ in .succeeded },
            configureDefault: { .succeeded }
        )
        XCTAssertEqual(AdsKit.resolveFirebaseOutcome(nil, using: configurator), .skipped)
    }

    func test_resolveFirebaseOutcome_defaultPlist_callsConfigureDefault() {
        let plistCalled = Box(false)
        let defaultCalled = Box(false)
        let configurator = FirebaseConfigurator(
            configureWithPlist: { _ in plistCalled.value = true; return .failed(reason: "nope") },
            configureDefault: { defaultCalled.value = true; return .succeeded }
        )

        let result = AdsKit.resolveFirebaseOutcome(.defaultPlist, using: configurator)

        XCTAssertEqual(result, .succeeded)
        XCTAssertFalse(plistCalled.value)
        XCTAssertTrue(defaultCalled.value)
    }

    func test_resolveFirebaseOutcome_plistName_forwardsName() {
        let nameSeen = Box<String?>(nil)
        let configurator = FirebaseConfigurator(
            configureWithPlist: { name in nameSeen.value = name; return .succeeded },
            configureDefault: { .failed(reason: "nope") }
        )

        _ = AdsKit.resolveFirebaseOutcome(.plistName("GoogleService-Info-Debug"), using: configurator)

        XCTAssertEqual(nameSeen.value, "GoogleService-Info-Debug")
    }

    func test_resolveFirebaseOutcome_plistMissing_passesThroughFailureReason() {
        let configurator = FirebaseConfigurator(
            configureWithPlist: { name in .failed(reason: "missing \(name).plist") },
            configureDefault: { .succeeded }
        )

        let result = AdsKit.resolveFirebaseOutcome(.plistName("absent"), using: configurator)

        XCTAssertEqual(result, .failed(reason: "missing absent.plist"))
    }

    func test_resolveFirebaseOutcome_plistSuccess_returnsSucceeded() {
        let configurator = FirebaseConfigurator(
            configureWithPlist: { _ in .succeeded },
            configureDefault: { .failed(reason: "nope") }
        )

        let result = AdsKit.resolveFirebaseOutcome(.plistName("ok"), using: configurator)

        XCTAssertEqual(result, .succeeded)
    }

    // MARK: - Coordinator integration

    func test_resolveFirebaseOutcome_failedResult_writesFailedToCoordinator() async {
        let coordinator = AdsKit.ConfigureCoordinator()
        let configurator = FirebaseConfigurator(
            configureWithPlist: { _ in .failed(reason: "plist-missing") },
            configureDefault: { .failed(reason: "nope") }
        )

        let result = AdsKit.resolveFirebaseOutcome(.plistName("missing"), using: configurator)
        await coordinator.setFirebase(result)

        let snapshot = await coordinator.snapshot()
        XCTAssertEqual(snapshot.firebase, .failed(reason: "plist-missing"))
        XCTAssertFalse(snapshot.noStepFailed, ".failed must propagate to noStepFailed=false")
    }

    func test_resolveFirebaseOutcome_succeededResult_writesSucceededToCoordinator() async {
        let coordinator = AdsKit.ConfigureCoordinator()
        let configurator = FirebaseConfigurator(
            configureWithPlist: { _ in .succeeded },
            configureDefault: { .succeeded }
        )

        let result = AdsKit.resolveFirebaseOutcome(.defaultPlist, using: configurator)
        await coordinator.setFirebase(result)

        let snapshot = await coordinator.snapshot()
        XCTAssertEqual(snapshot.firebase, .succeeded)
    }
}

// MARK: - Helpers

/// Minimal reference-cell so closures can write captured state in tests.
private final class Box<T>: @unchecked Sendable {
    var value: T
    init(_ value: T) { self.value = value }
}
