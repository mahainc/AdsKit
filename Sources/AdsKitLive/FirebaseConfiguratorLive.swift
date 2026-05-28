import AdsKit
import Dependencies
import FirebaseCore
import Foundation
import OSLog

extension FirebaseConfigurator: DependencyKey {
    public static let liveValue: FirebaseConfigurator = FirebaseConfigurator(
        configureWithPlist: { plistName in
            guard
                let path = Bundle.main.path(forResource: plistName, ofType: "plist"),
                let options = FirebaseOptions(contentsOfFile: path)
            else {
                Logger.adsKitConfigure.fault(
                    "firebase — MISSING \(plistName, privacy: .public).plist in main bundle"
                )
                assertionFailure("[AdsKit] Missing \(plistName).plist in main bundle")
                return .failed(reason: "missing \(plistName).plist in main bundle")
            }
            FirebaseApp.configure(options: options)
            Logger.adsKitConfigure.info(
                "firebase — configured with \(plistName, privacy: .public).plist (projectID=\(options.projectID ?? "?", privacy: .public))"
            )
            return .succeeded
        },
        configureDefault: {
            FirebaseApp.configure()
            Logger.adsKitConfigure.info("firebase — configured with default GoogleService-Info.plist")
            return .succeeded
        }
    )
}
