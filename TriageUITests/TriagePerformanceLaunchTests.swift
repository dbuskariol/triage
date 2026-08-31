import Foundation
import XCTest

/// Opt-in UI launch benchmark. It is deliberately separate from the normal
/// smoke suite: ordinary UI tests must never be converted into wall-clock
/// assertions, and this benchmark needs an XCUITest-capable baseline host.
@MainActor
final class TriagePerformanceLaunchTests: XCTestCase {
    func testOptInLaunchBudget() throws {
        guard ProcessInfo.processInfo.environment["TRIAGE_PERFORMANCE_UI_BENCHMARK"] == "1" else { return }

        var samples = [Double]()
        let benchmarkSession = UUID().uuidString.lowercased()
        for warmup in 0..<LaunchMeasurement.warmupSampleCount {
            _ = try launchSample(session: "performance-\(benchmarkSession)-warmup-\(warmup)")
        }
        for sample in 0..<LaunchMeasurement.measuredSampleCount {
            samples.append(try launchSample(session: "performance-\(benchmarkSession)-\(sample)"))
        }
        let result = try LaunchMeasurement(
            samplesMilliseconds: samples,
            budgetMilliseconds: 1_000,
            p95BudgetMilliseconds: 1_200
        )
        if let path = ProcessInfo.processInfo.environment["TRIAGE_PERFORMANCE_UI_RESULT_PATH"] {
            try JSONEncoder().encode(result).write(to: URL(fileURLWithPath: path), options: .atomic)
        }
        XCTAssertLessThanOrEqual(result.medianMilliseconds, result.budgetMilliseconds)
        XCTAssertLessThanOrEqual(result.p95Milliseconds, result.p95BudgetMilliseconds)
    }

    private func launchSample(session: String) throws -> Double {
        let app = XCUIApplication()
        app.launchArguments = ["-triage-ui-fixture"]
        app.launchEnvironment = [
            "TRIAGE_UI_TEST_MODE": "1",
            "TRIAGE_UI_TEST_SCENARIO": "workspace",
            "TRIAGE_UI_TEST_SESSION": session,
            "TRIAGE_UI_TEST_RESET": "1"
        ]
        let started = DispatchTime.now().uptimeNanoseconds
        app.launch()
        XCTAssertTrue(
            app.descendants(matching: .any)["Triage sidebar"].waitForExistence(timeout: 10),
            "Fixture launch must reach interactive seeded workspace content."
        )
        let elapsed = DispatchTime.now().uptimeNanoseconds - started
        app.terminate()
        return Double(elapsed) / 1_000_000
    }
}

private struct LaunchMeasurement: Codable {
    static let currentSchemaVersion = 1
    static let warmupSampleCount = 3
    static let measuredSampleCount = 11

    let schemaVersion: Int
    let warmupSampleCount: Int
    let samplesMilliseconds: [Double]
    let medianMilliseconds: Double
    let p95Milliseconds: Double
    let budgetMilliseconds: Double
    let p95BudgetMilliseconds: Double

    init(
        samplesMilliseconds: [Double],
        budgetMilliseconds: Double,
        p95BudgetMilliseconds: Double
    ) throws {
        guard samplesMilliseconds.count == Self.measuredSampleCount,
              samplesMilliseconds.allSatisfy(\.isFinite),
              samplesMilliseconds.allSatisfy({ $0 >= 0 })
        else {
            throw LaunchMeasurementError.invalidSamples
        }
        let sorted = samplesMilliseconds.sorted()
        schemaVersion = Self.currentSchemaVersion
        warmupSampleCount = Self.warmupSampleCount
        self.samplesMilliseconds = samplesMilliseconds
        medianMilliseconds = Self.percentile(sorted, fraction: 0.5)
        p95Milliseconds = Self.percentile(sorted, fraction: 0.95)
        self.budgetMilliseconds = budgetMilliseconds
        self.p95BudgetMilliseconds = p95BudgetMilliseconds
    }

    private static func percentile(_ sorted: [Double], fraction: Double) -> Double {
        let rank = max(1, Int((fraction * Double(sorted.count)).rounded(.up)))
        return sorted[rank - 1]
    }
}

private enum LaunchMeasurementError: Error {
    case invalidSamples
}
