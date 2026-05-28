extension AdsKit {

    /// Per-step lifecycle for `AdsKit.configure(...)`'s init phases.
    ///
    /// Replaces the prior `Bool?` shape (`nil`/`true`/`false`) so:
    /// - failure reasons are first-class (`.failed(reason:)` carries the why)
    /// - every step has the same shape (Firebase used to be the only step that
    ///   could meaningfully express failure)
    /// - call sites don't have to remember the ternary semantics
    public enum StepStatus: Sendable, Equatable {
        /// Step was not requested (the corresponding configuration field was nil
        /// or otherwise opted out) — distinguishes "skipped" from "ran and succeeded".
        case skipped

        /// Step ran to completion. For non-throwing SDK calls this means the
        /// `await` returned; for throwing calls it means no error was raised.
        case succeeded

        /// Step ran but reported failure. `reason` is a human-readable summary
        /// suitable for logs and dashboards (e.g. "missing GoogleService-Info-Debug.plist").
        case failed(reason: String)

        public var isSkipped: Bool {
            if case .skipped = self { return true } else { return false }
        }

        public var isSucceeded: Bool {
            if case .succeeded = self { return true } else { return false }
        }

        public var isFailed: Bool {
            if case .failed = self { return true } else { return false }
        }

        /// Stable token used in telemetry payloads ("skipped" / "succeeded" /
        /// "failed"). Failure reasons are intentionally NOT included here; emit
        /// them as a sibling field (e.g. `<step>_failure_reason`) when needed
        /// to keep param cardinality bounded.
        public var telemetryName: String {
            switch self {
            case .skipped: return "skipped"
            case .succeeded: return "succeeded"
            case .failed: return "failed"
            }
        }
    }

    /// Per-step outcome of `AdsKit.configure(...)`. Surfaced to Bootstrap via
    /// `Bootstrap.Config.configureGate` and stored on
    /// `Bootstrap.State.configureOutcome` for host view layers to inspect.
    public struct ConfigureOutcome: Sendable, Equatable {
        public var firebase: StepStatus
        public var facebook: StepStatus
        public var analytics: StepStatus
        public var adjust: StepStatus
        public var revenueBridge: StepStatus
        public var remoteConfig: StepStatus

        /// `true` when no step is in `.failed`. Skipped + succeeded both count
        /// as "not failed".
        public var noStepFailed: Bool {
            !firebase.isFailed
                && !facebook.isFailed
                && !analytics.isFailed
                && !adjust.isFailed
                && !revenueBridge.isFailed
                && !remoteConfig.isFailed
        }

        public init(
            firebase: StepStatus = .skipped,
            facebook: StepStatus = .skipped,
            analytics: StepStatus = .skipped,
            adjust: StepStatus = .skipped,
            revenueBridge: StepStatus = .skipped,
            remoteConfig: StepStatus = .skipped
        ) {
            self.firebase = firebase
            self.facebook = facebook
            self.analytics = analytics
            self.adjust = adjust
            self.revenueBridge = revenueBridge
            self.remoteConfig = remoteConfig
        }
    }
}
