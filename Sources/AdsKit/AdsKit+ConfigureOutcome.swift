extension AdsKit {

    /// Per-step outcome of `AdsKit.configure(...)`'s init phases. Surfaced to
    /// Bootstrap via `Bootstrap.Config.configureGate` and stored on
    /// `Bootstrap.State.configureOutcome` for host view layers to inspect.
    ///
    /// For each step:
    /// - `nil`   — step was not requested (e.g. `firebase = nil` in config)
    /// - `true`  — the underlying client `await` returned
    /// - `false` — step ran but failed (currently only reachable for `firebase`;
    ///             the other three are non-throwing in their upstream client
    ///             interfaces today)
    public struct ConfigureOutcome: Sendable, Equatable {
        public var firebase: Bool?
        public var adjust: Bool?
        public var revenueBridge: Bool?
        public var resumeHandler: Bool?

        /// `true` when no step is in a `.false` state. Both `nil` (not requested)
        /// and `.some(true)` (succeeded) count as "not failed."
        public var noStepFailed: Bool {
            firebase != false
                && adjust != false
                && revenueBridge != false
                && resumeHandler != false
        }

        public init(
            firebase: Bool? = nil,
            adjust: Bool? = nil,
            revenueBridge: Bool? = nil,
            resumeHandler: Bool? = nil
        ) {
            self.firebase = firebase
            self.adjust = adjust
            self.revenueBridge = revenueBridge
            self.resumeHandler = resumeHandler
        }
    }
}
