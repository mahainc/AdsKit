import Dependencies
import UIKit

/// Injectable surface for the Facebook SDK launch hooks. The live impl in
/// `AdsKitLive` reads `Settings.shared` overrides from `Bundle.main` and calls
/// `ApplicationDelegate.shared.application(_:didFinishLaunchingWithOptions:)`.
/// The test impl raises a test failure if invoked without override.
public struct FacebookConfigurator: Sendable {
    /// Activate the Facebook SDK at launch. Implementations are responsible for
    /// reading any `Settings.shared` overrides (e.g. `FacebookAdvertiserIDCollectionEnabled`)
    /// and forwarding the launch options to `ApplicationDelegate.activateApp`.
    public var activate: @Sendable @MainActor (
        _ application: UIApplication,
        _ launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Void

    public init(
        activate: @escaping @Sendable @MainActor (
            _ application: UIApplication,
            _ launchOptions: [UIApplication.LaunchOptionsKey: Any]?
        ) -> Void
    ) {
        self.activate = activate
    }
}

extension FacebookConfigurator: TestDependencyKey {
    public static let testValue = FacebookConfigurator(
        activate: { _, _ in
            reportIssue("FacebookConfigurator.activate called without test override")
        }
    )

    /// Silent no-op — useful when a test doesn't care about Facebook activation.
    public static let noop = FacebookConfigurator(activate: { _, _ in })
}

extension DependencyValues {
    public var facebookConfigurator: FacebookConfigurator {
        get { self[FacebookConfigurator.self] }
        set { self[FacebookConfigurator.self] = newValue }
    }
}
