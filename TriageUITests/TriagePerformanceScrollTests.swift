import Foundation
import XCTest

/// Opt-in 10k-row native List acceptance. XCTest owns the scrolling and hitch
/// metrics; this test records only aggregate gesture timing, never row text or
/// other fixture content. A baseline threshold is intentionally not asserted.
@MainActor
final class TriagePerformanceScrollTests: XCTestCase {
    private enum Configuration {
        static let itemCount = 10_000
        static let warmupSampleCount = 3
        static let measuredSampleCount = 11
        static let gesturesPerIteration = 2
    }

    func testOptInTenThousandRowScrollingAndHitchMetrics() throws {
        guard ProcessInfo.processInfo.environment["TRIAGE_PERFORMANCE_UI_BENCHMARK"] == "1" else { return }

        let app = XCUIApplication()
        app.launchArguments = ["-triage-ui-fixture"]
        app.launchEnvironment = [
            "TRIAGE_UI_TEST_MODE": "1",
            "TRIAGE_UI_TEST_SCENARIO": "performance-workspace",
            "TRIAGE_UI_TEST_SESSION": "performance-scroll-\(UUID().uuidString.lowercased())",
            "TRIAGE_UI_TEST_RESET": "1"
        ]
        app.launch()

        let workList = app.outlines["Inbox work"]
        XCTAssertTrue(workList.waitForExistence(timeout: 15), "The 10k-row fixture must reach its native work list.")
        // Every XCUITest query snapshots the whole accessibility tree, which
        // includes all 10,000 rows, so the benchmark avoids extra queries.

        // XCTest's `measure` executes its closure once as a discarded warmup.
        // These two manual pairs therefore make the declared total exactly
        // three warmups before the eleven retained iterations.
        for _ in 0..<2 {
            performMeasuredGesturePair(in: workList)
        }

        var durationSamples = [Double]()
        let options = XCTMeasureOptions.default
        options.iterationCount = Configuration.measuredSampleCount
        measure(
            metrics: [
                XCTOSSignpostMetric.scrollingAndDecelerationMetric,
                XCTHitchMetric(application: app)
            ],
            options: options
        ) {
            let started = DispatchTime.now().uptimeNanoseconds
            performMeasuredGesturePair(in: workList)
            let elapsed = DispatchTime.now().uptimeNanoseconds - started
            durationSamples.append(Double(elapsed) / 1_000_000)
        }

        // XCTest invokes the measure closure once extra as the third discarded
        // warmup. Preserve only aggregates from the eleven reported iterations.
        let measuredSamples = Array(durationSamples.dropFirst())
        XCTAssertEqual(measuredSamples.count, Configuration.measuredSampleCount)
        try writeAggregateReport(samples: measuredSamples)
    }

    private func performMeasuredGesturePair(in workList: XCUIElement) {
        workList.swipeUp()
        workList.swipeDown()
    }

    private func writeAggregateReport(samples: [Double]) throws {
        guard let path = ProcessInfo.processInfo.environment["TRIAGE_PERFORMANCE_UI_SCROLL_RESULT_PATH"] else {
            return
        }
        guard let benchmarkSession = ProcessInfo.processInfo.environment[
            "TRIAGE_PERFORMANCE_BENCHMARK_SESSION"
        ], !benchmarkSession.isEmpty else {
            throw ScrollAcceptanceError.missingBenchmarkSession
        }
        let sorted = samples.sorted()
        let report = TriageScrollAcceptanceReport(
            schemaVersion: TriageScrollAcceptanceReport.currentSchemaVersion,
            status: "measured-unbaselined",
            benchmarkSession: benchmarkSession,
            fixtureItemCount: Configuration.itemCount,
            warmupSampleCount: Configuration.warmupSampleCount,
            samplesGesturePairMilliseconds: samples,
            gesturesPerIteration: Configuration.gesturesPerIteration,
            medianGesturePairMilliseconds: percentile(sorted, fraction: 0.5),
            p95GesturePairMilliseconds: percentile(sorted, fraction: 0.95),
            requestedMetricIdentifiers: TriageScrollAcceptanceReport.expectedMetricIdentifiers,
            systemMetrics: []
        )
        try JSONEncoder().encode(report).write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    private func percentile(_ sorted: [Double], fraction: Double) -> Double {
        let index = Int((Double(sorted.count - 1) * fraction).rounded(.up))
        return sorted[index]
    }
}

private struct TriageScrollAcceptanceReport: Codable {
    static let currentSchemaVersion = 1
    /// These are the only XCTest metric identifiers the runner may retain from
    /// the result bundle. Unknown metrics are rejected instead of being copied.
    static let expectedMetricIdentifiers = [
        "com.apple.dt.XCTOSSignpostMetric.scrollingAndDeceleration",
        "com.apple.dt.XCTHitchMetric"
    ]

    let schemaVersion: Int
    let status: String
    let benchmarkSession: String
    let fixtureItemCount: Int
    let warmupSampleCount: Int
    let samplesGesturePairMilliseconds: [Double]
    let gesturesPerIteration: Int
    let medianGesturePairMilliseconds: Double
    let p95GesturePairMilliseconds: Double
    let requestedMetricIdentifiers: [String]
    let systemMetrics: [TriageScrollSystemMetric]
}

private struct TriageScrollSystemMetric: Codable {
    let identifier: String
    let unit: String
    let count: Int
    let minimum: Double
    let median: Double
    let p95: Double
    let maximum: Double
}

private enum ScrollAcceptanceError: Error {
    case missingBenchmarkSession
}
