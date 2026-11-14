import Core
import Foundation
import MetricKit

/// OBS-2: subscribes to MetricKit and keeps the last diagnostic and metric payloads as JSON in
/// Application Support (`AppConfig.lastDiagnosticPayloadURL`, `lastMetricPayloadURL`). Nothing
/// leaves the device; the debug screen in Settings shows the files. No third-party SDK.
final class MetricsCollector: NSObject, MXMetricManagerSubscriber, Sendable {
    static let shared = MetricsCollector()

    /// Called once at launch.
    @MainActor
    static func start() {
        MXMetricManager.shared.add(shared)
    }

    func didReceive(_ payloads: [MXMetricPayload]) {
        guard let last = payloads.last else { return }
        store(last.jsonRepresentation(), at: AppConfig.lastMetricPayloadURL)
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        guard let last = payloads.last else { return }
        store(last.jsonRepresentation(), at: AppConfig.lastDiagnosticPayloadURL)
    }

    private func store(_ data: Data, at url: URL) {
        do {
            try FileManager.default.createDirectory(at: AppConfig.metricKitDirectory, withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        } catch {
            // Diagnostics are best effort; a failed write keeps the previous payload.
        }
    }
}
