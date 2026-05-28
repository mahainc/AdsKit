extension AdsKit {

    /// Lifecycle of the launch-time Adjust → revenue-bridge chain owned by
    /// `AdsKit.configure(...)`. Surfaced so callers can distinguish
    /// "never started" (host hasn't called `configure` yet) from
    /// "ran with no work" (called but every step was disabled or already done).
    public enum ChainState: Sendable, Equatable {
        case notStarted
        case running
        case completed(ConfigureOutcome)
    }

    /// Serializes outcome reads/writes and ensures the Adjust chain runs at
    /// most once per process. Lives in the SDK-free target so unit tests can
    /// exercise it without linking Firebase/Adjust/Facebook.
    ///
    /// `shared` is the singleton wired into `AdsKit.configure(...)`. Test
    /// targets construct fresh instances via `init()` to avoid cross-test
    /// pollution.
    public actor ConfigureCoordinator {

        public static let shared = ConfigureCoordinator()

        private var outcome = ConfigureOutcome()
        private var chainState: ChainState = .notStarted
        private var chainTask: Task<ConfigureOutcome, Never>?

        public init() {}

        // MARK: - Outcome

        public func snapshot() -> ConfigureOutcome { outcome }

        public func setFirebase(_ value: StepStatus)       { outcome.firebase = value }
        public func setFacebook(_ value: StepStatus)       { outcome.facebook = value }
        public func setAnalytics(_ value: StepStatus)      { outcome.analytics = value }
        public func setAdjust(_ value: StepStatus)         { outcome.adjust = value }
        public func setRevenueBridge(_ value: StepStatus)  { outcome.revenueBridge = value }
        public func setRemoteConfig(_ value: StepStatus)   { outcome.remoteConfig = value }

        // MARK: - Chain

        public func currentChainState() -> ChainState { chainState }

        /// First caller spawns `work` and stores the resulting task; subsequent
        /// callers return the existing task without re-running. Guarantees the
        /// chain body executes at most once per coordinator lifetime (or until
        /// `resetForTesting()`).
        @discardableResult
        public func ensureChainStarted(
            _ work: @Sendable @escaping () async -> ConfigureOutcome
        ) -> Task<ConfigureOutcome, Never> {
            if let existing = chainTask { return existing }
            let task = Task { await work() }
            chainTask = task
            chainState = .running
            Task { [weak self] in
                let result = await task.value
                await self?.markCompleted(result)
            }
            return task
        }

        /// Awaits the chain task's completion and returns the outcome. If
        /// `configure(...)` was never called, returns the current snapshot
        /// (default: an empty `ConfigureOutcome`).
        public func awaitChain() async -> ConfigureOutcome {
            if let task = chainTask { return await task.value }
            return outcome
        }

        private func markCompleted(_ result: ConfigureOutcome) {
            outcome = result
            chainState = .completed(result)
        }

        // MARK: - Testing

        /// Resets all state. **Test-only** — production code must never call this.
        public func resetForTesting() {
            outcome = ConfigureOutcome()
            chainState = .notStarted
            chainTask = nil
        }
    }
}
