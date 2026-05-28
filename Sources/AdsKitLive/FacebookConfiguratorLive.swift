import AdsKit
import Dependencies
import Foundation
import OSLog
import UIKit

#if canImport(FacebookCore)
import FacebookCore
#endif

extension FacebookConfigurator: DependencyKey {
    public static let liveValue: FacebookConfigurator = FacebookConfigurator(
        activate: { application, launchOptions in
            #if canImport(FacebookCore)
            // Forward Info.plist values into FB SDK's in-memory settings BEFORE
            // `activateApp` runs its startup `logWarnings()` — the SDK reads the
            // backing field directly there, not the Info.plist, so without this
            // hand-off it warns "currently set to FALSE" even when the plist says TRUE.
            if let enabled = Bundle.main.object(forInfoDictionaryKey: "FacebookAdvertiserIDCollectionEnabled") as? Bool {
                Settings.shared.isAdvertiserIDCollectionEnabled = enabled
            }
            if let enabled = Bundle.main.object(forInfoDictionaryKey: "FacebookAutoLogAppEventsEnabled") as? Bool {
                Settings.shared.isAutoLogAppEventsEnabled = enabled
            }
            ApplicationDelegate.shared.application(
                application,
                didFinishLaunchingWithOptions: launchOptions
            )
            Logger.adsKitConfigure.info("facebook — activateApp dispatched (FacebookCore linked)")
            #else
            Logger.adsKitConfigure.info("facebook — FacebookCore not linked, skipped")
            #endif
        }
    )
}
