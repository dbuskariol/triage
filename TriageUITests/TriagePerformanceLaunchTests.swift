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
        for sample in 0..<11 {
            let app = XCUIApplication()
            app.launchArguments = ["-triage-ui-fixture"]
            app.launchEnvironment = [
                "TRIAGE_UI_TEST_MODE": "1",
                "TRIAGE_UI_TEST_SCENARIO": "workspace",
                "TRIAGE_UI_TEST_SESSION": "performance-\(benchmarkSession)-\(sample)",
                "TRIAGE_UI_TEST_RESET": "1"
            ]
            let started = DispatchTime.now().uptimeNanoseconds
            app.launch()
            XCTAssertTrue(
                app.descendants(matching: .any)["Triage sidebar"].waitForExistence(timeout: 10),
                "Fixture launch must reach interactive seeded workspace content."
            )
            let elapsed = DispatchTime.now().uptimeNanoseconds - started
            samples.append(Double(elapsed) / 1_000_000)
            app.terminate()
        }
        let sorted = samples.sorted()
        let result = LaunchMeasurement(
            medianMilliseconds: percentile(sorted, fraction: 0.5),
            p95Milliseconds: percentile(sorted, fraction: 0.95),
            budgetMilliseconds: 1_000,
            p95BudgetMilliseconds: 1_200
        )
        if let path = ProcessInfo.processInfo.environment["TRIAGE_PERFORMANCE_UI_RESULT_PATH"] {
            try JSONEncoder().encode(result).write(to: URL(fileURLWithPath: path), options: .atomic)
        }
        XCTAssertLessThanOrEqual(result.medianMilliseconds, result.budgetMilliseconds)
        XCTAssertLessThanOrEqual(result.p95Milliseconds, result.p95BudgetMilliseconds)
    }

    private func percentile(_ sorted: [Double], fraction: Double) -> Double {
        let index = Int((Double(sorted.count - 1) * fraction).rounded(.up))
        return sorted[index]
    }
}

private struct LaunchMeasurement: Codable {
    let medianMilliseconds: Double
    let p95Milliseconds: Double
    let budgetMilliseconds: Double
    let p95BudgetMilliseconds: Double
}
