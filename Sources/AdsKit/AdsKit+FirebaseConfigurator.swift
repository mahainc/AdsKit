import Dependencies

/// Injectable surface for `FirebaseApp.configure(...)`. The live impl in
/// `AdsKitLive` does the actual Firebase + Bundle.main work; the test impl
/// raises a test failure if invoked without override so tests must be
/// explicit about what they expect.
///
/// Closures return `AdsKit.StepStatus` so failure reasons (e.g. missing plist)
/// flow directly into the coordinator without a Bool-→-status conversion step.
public struct FirebaseConfigurator: Sendable {
    /// Configure Firebase from a named plist file in `Bundle.main`. Returns
    /// `.succeeded` on success, `.failed(reason:)` if the plist is missing
    /// or invalid.
    public var configureWithPlist: @Sendable (_ plistName: String) -> AdsKit.StepStatus

    /// Configure Firebase using the default `GoogleService-Info.plist` lookup.
    public var configureDefault: @Sendable () -> AdsKit.StepStatus

    public init(
        configureWithPlist: @escaping @Sendable (_ plistName: String) -> AdsKit.StepStatus,
        configureDefault: @escaping @Sendable () -> AdsKit.StepStatus
    ) {
        self.configureWithPlist = configureWithPlist
        self.configureDefault = configureDefault
    }
}

extension FirebaseConfigurator: TestDependencyKey {
    public static let testValue = FirebaseConfigurator(
        configureWithPlist: { plistName in
            reportIssue("FirebaseConfigurator.configureWithPlist(\(plistName)) called without test override")
            return .failed(reason: "test value invoked without override")
        },
        configureDefault: {
            reportIssue("FirebaseConfigurator.configureDefault called without test override")
            return .failed(reason: "test value invoked without override")
        }
    )
}

extension DependencyValues {
    public var firebaseConfigurator: FirebaseConfigurator {
        get { self[FirebaseConfigurator.self] }
        set { self[FirebaseConfigurator.self] = newValue }
    }
}

extension AdsKit {
    /// Pure mapping from `LaunchConfiguration.Firebase?` → `StepStatus`,
    /// routed through an injectable `FirebaseConfigurator`. Returns:
    /// - `.skipped` when no Firebase source is configured.
    /// - The configurator's verdict otherwise (`.succeeded` or `.failed(reason:)`).
    public static func resolveFirebaseOutcome(
        _ source: LaunchConfiguration.Firebase?,
        using configurator: FirebaseConfigurator
    ) -> StepStatus {
        guard let source else { return .skipped }
        switch source {
        case .defaultPlist:
            return configurator.configureDefault()
        case .plistName(let name):
            return configurator.configureWithPlist(name)
        }
    }
}
