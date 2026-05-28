import AnalyticClient
import Foundation

/// Captures every `trackEvent(_:_:)` call so reducer tests can assert on
/// emitted telemetry name + payload without round-tripping through Firebase.
actor AnalyticRecorder {
    struct Call: Equatable {
        let name: String
        let params: [String: AnalyticClient.Param]
    }

    private(set) var calls: [Call] = []

    func record(_ name: String, _ params: [String: AnalyticClient.Param]) {
        calls.append(Call(name: name, params: params))
    }

    func names() -> [String] { calls.map(\.name) }

    func payload(for name: String) -> [String: AnalyticClient.Param]? {
        calls.first(where: { $0.name == name })?.params
    }
}

extension AnalyticClient {
    /// Recording client — every call writes to the recorder, never throws.
    static func recording(_ recorder: AnalyticRecorder) -> Self {
        .init(
            initialize:                     { _ in },
            trackScreen:                    { name, params in await recorder.record(name, params) },
            trackEvent:                     { name, params in await recorder.record(name, params) },
            setUserID:                      { _ in },
            setUserProperty:                { _, _ in },
            setAnalyticsCollectionEnabled:  { _ in },
            log:                            { _ in },
            recordError:                    { _, _ in }
        )
    }
}
