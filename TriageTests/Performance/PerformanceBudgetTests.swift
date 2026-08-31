import Darwin
import Foundation
import XCTest
@testable import Triage

final class PerformanceBudgetTests: XCTestCase {
    func testOptInDatabaseBudgets() async throws {
        guard PerformanceBenchmarkConfiguration.current.isEnabled else { return }

        let configuration = PerformanceBenchmarkConfiguration.current
        guard let profile = PerformanceBaselineProfile.recognizedCurrentHost else {
            let report = PerformanceBenchmarkReport.unsupportedBaseline(
                model: PerformanceBaselineProfile.currentModel,
                architecture: PerformanceBaselineProfile.currentArchitecture
            )
            try report.write(to: configuration.resultURL)
            XCTFail(report.statusMessage)
            return
        }
        if let expectedProfile = configuration.expectedProfile, expectedProfile != profile.rawValue {
            let report = PerformanceBenchmarkReport.unsupportedBaseline(
                model: PerformanceBaselineProfile.currentModel,
                architecture: PerformanceBaselineProfile.currentArchitecture,
                expectedProfile: expectedProfile
            )
            try report.write(to: configuration.resultURL)
            XCTFail(report.statusMessage)
            return
        }

        let fixture = try await PerformanceFixtureStore()
        do {
            try await fixture.seed()
            assertFullScaleCounts(try await fixture.recordCounts())

            let measurements = try await [
                PerformanceMeasurement.measure(name: "cachedWorkspaceSwitch", budgetMilliseconds: 150) {
                    _ = try await fixture.cachedWorkspaceSnapshot()
                },
                PerformanceMeasurement.measure(name: "inboxFirstPage", budgetMilliseconds: 100) {
                    _ = try await fixture.inboxFirstPage()
                },
                PerformanceMeasurement.measure(name: "localSearchFirstPage", budgetMilliseconds: 150) {
                    _ = try await fixture.searchFirstPage()
                },
                PerformanceMeasurement.measure(name: "detailInitialPage", budgetMilliseconds: 100) {
                    _ = try await fixture.detailInitialPresentation()
                }
            ]
            let launchAndInteractivity = try PerformanceLaunchAndInteractivity.fromEnvironment()
            let passesDatabaseBudgets = measurements.allSatisfy {
                $0.medianMilliseconds <= $0.budgetMilliseconds
                    && $0.p95Milliseconds <= $0.p95BudgetMilliseconds
            }
            let passesLaunchBudget: Bool
            if case let .measured(launch) = launchAndInteractivity {
                passesLaunchBudget = launch.medianMilliseconds <= launch.budgetMilliseconds
                    && launch.p95Milliseconds <= launch.p95BudgetMilliseconds
            } else {
                passesLaunchBudget = true
            }
            let report = PerformanceBenchmarkReport(
                profile: profile,
                measurements: measurements,
                launchAndInteractivity: launchAndInteractivity,
                passed: passesDatabaseBudgets && passesLaunchBudget
            )
            try report.write(to: configuration.resultURL)

            for measurement in measurements {
                XCTAssertLessThanOrEqual(
                    measurement.medianMilliseconds,
                    measurement.budgetMilliseconds,
                    "\(measurement.name) median exceeded its §24 budget."
                )
                XCTAssertLessThanOrEqual(
                    measurement.p95Milliseconds,
                    measurement.p95BudgetMilliseconds,
                    "\(measurement.name) p95 exceeded its documented 20% tolerance."
                )
            }
            if case let .measured(launch) = launchAndInteractivity {
                XCTAssertLessThanOrEqual(
                    launch.medianMilliseconds,
                    launch.budgetMilliseconds,
                    "Launch median exceeded its §24 budget."
                )
                XCTAssertLessThanOrEqual(
                    launch.p95Milliseconds,
                    launch.p95BudgetMilliseconds,
                    "Launch p95 exceeded its documented 20% tolerance."
                )
            }
            await fixture.close()
        } catch {
            await fixture.close()
            throw error
        }
    }

    private func assertFullScaleCounts(_ counts: [String: Int]) {
        XCTAssertEqual(counts["repositories"], PerformanceFixtureScale.repositories)
        XCTAssertEqual(counts["work_items"], PerformanceFixtureScale.workItems)
        XCTAssertEqual(counts["timeline_events"], PerformanceFixtureScale.timelineEvents)
        XCTAssertEqual(counts["projects"], PerformanceFixtureScale.projects)
        XCTAssertEqual(counts["project_items"], PerformanceFixtureScale.projectItems)
        XCTAssertEqual(counts["discussions"], PerformanceFixtureScale.discussions)
        XCTAssertEqual(counts["discussion_replies"], PerformanceFixtureScale.discussionReplies)
        XCTAssertEqual(counts["searchable_comments"], PerformanceFixtureScale.searchableComments)
        XCTAssertEqual(counts["actionable_items"], PerformanceFixtureScale.actionableItems)
    }
}

struct PerformanceBenchmarkConfiguration {
    let isEnabled: Bool
    let resultURL: URL?
    let expectedProfile: String?

    static var current: Self {
        from(environment: ProcessInfo.processInfo.environment)
    }

    static func from(environment: [String: String]) -> Self {
        return Self(
            isEnabled: environment["TRIAGE_PERFORMANCE_BENCHMARK"] == "1",
            resultURL: environment["TRIAGE_PERFORMANCE_RESULT_PATH"].map(URL.init(fileURLWithPath:)),
            expectedProfile: environment["TRIAGE_PERFORMANCE_BASELINE_PROFILE"]
        )
    }
}

private enum PerformanceBaselineProfile: String {
    /// Entry Apple silicon profile used for the macOS 26 support window.
    case entryAppleSilicon = "entry-apple-silicon-macbookair10,1"
    /// Oldest Intel profile used for the macOS 26 support window.
    case oldestIntel = "oldest-intel-macmini9,1"

    static var recognizedCurrentHost: Self? {
        switch (currentArchitecture, currentModel) {
        case ("arm64", "MacBookAir10,1"): .entryAppleSilicon
        case ("x86_64", "Macmini9,1"): .oldestIntel
        default: nil
        }
    }

    static var currentArchitecture: String {
        var value = utsname()
        uname(&value)
        return withUnsafePointer(to: &value.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) { String(cString: $0) }
        }
    }

    static var currentModel: String {
        var size = 0
        guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 0 else {
            return "unknown"
        }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("hw.model", &buffer, &size, nil, 0) == 0 else {
            return "unknown"
        }
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }
}

private struct PerformanceMeasurement: Codable {
    let name: String
    let samplesMilliseconds: [Double]
    let medianMilliseconds: Double
    let p95Milliseconds: Double
    let budgetMilliseconds: Double
    let p95BudgetMilliseconds: Double

    static func measure(
        name: String,
        budgetMilliseconds: Double,
        operation: () async throws -> Void
    ) async throws -> Self {
        // Warm-up keeps schema caches and prepared statements out of the sample
        // distribution. Measurements remain wall-clock observations, never a
        // normal unit-test assertion.
        for _ in 0..<PerformanceBenchmarkSampling.warmupSampleCount { try await operation() }
        var samples = [Double]()
        for _ in 0..<PerformanceBenchmarkSampling.measuredSampleCount {
            let started = DispatchTime.now().uptimeNanoseconds
            try await operation()
            let elapsed = DispatchTime.now().uptimeNanoseconds - started
            samples.append(Double(elapsed) / 1_000_000)
        }
        let sorted = samples.sorted()
        return Self(
            name: name,
            samplesMilliseconds: samples,
            medianMilliseconds: PerformanceBenchmarkSampling.percentile(sorted, fraction: 0.5),
            p95Milliseconds: PerformanceBenchmarkSampling.percentile(sorted, fraction: 0.95),
            budgetMilliseconds: budgetMilliseconds,
            p95BudgetMilliseconds: budgetMilliseconds * 1.2
        )
    }

}

enum PerformanceBenchmarkSampling {
    static let warmupSampleCount = 3
    static let measuredSampleCount = 11

    /// Uses nearest-rank percentiles on a sorted sample set. With eleven
    /// observations this makes the median the sixth value and p95 the slowest
    /// value, deliberately avoiding an interpolated value that was never seen.
    static func percentile(_ sorted: [Double], fraction: Double) -> Double {
        precondition(!sorted.isEmpty)
        precondition((0...1).contains(fraction))
        let rank = max(1, Int((fraction * Double(sorted.count)).rounded(.up)))
        return sorted[rank - 1]
    }
}

private enum PerformanceLaunchAndInteractivity: Codable {
    case measured(PerformanceLaunchMeasurement)
    case notMeasured(String)

    enum CodingKeys: String, CodingKey { case status, reason, launch }
    enum Status: String, Codable { case measured, notMeasured }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .measured(launch):
            try container.encode(Status.measured, forKey: .status)
            try container.encode(launch, forKey: .launch)
        case let .notMeasured(reason):
            try container.encode(Status.notMeasured, forKey: .status)
            try container.encode(reason, forKey: .reason)
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Status.self, forKey: .status) {
        case .measured:
            self = .measured(try container.decode(PerformanceLaunchMeasurement.self, forKey: .launch))
        case .notMeasured:
            self = .notMeasured(try container.decode(String.self, forKey: .reason))
        }
    }

    static func fromEnvironment() throws -> Self {
        guard let path = ProcessInfo.processInfo.environment["TRIAGE_PERFORMANCE_UI_RESULT_PATH"] else {
            return .notMeasured(
                "Requires an XCUITest-capable host with a deterministic seeded workspace."
            )
        }
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return .notMeasured("The requested XCUITest launch benchmark did not produce a result.")
        }
        return .measured(try JSONDecoder().decode(PerformanceLaunchMeasurement.self, from: Data(contentsOf: url)))
    }
}

private struct PerformanceLaunchMeasurement: Codable {
    let medianMilliseconds: Double
    let p95Milliseconds: Double
    let budgetMilliseconds: Double
    let p95BudgetMilliseconds: Double
}

private struct PerformanceBenchmarkReport: Codable {
    let status: String
    let profile: String?
    let hostModel: String
    let architecture: String
    let measurements: [PerformanceMeasurement]
    let launchAndInteractivity: PerformanceLaunchAndInteractivity?
    let expectedProfile: String?

    private init(
        status: String,
        profile: String?,
        hostModel: String,
        architecture: String,
        measurements: [PerformanceMeasurement],
        launchAndInteractivity: PerformanceLaunchAndInteractivity?,
        expectedProfile: String?
    ) {
        self.status = status
        self.profile = profile
        self.hostModel = hostModel
        self.architecture = architecture
        self.measurements = measurements
        self.launchAndInteractivity = launchAndInteractivity
        self.expectedProfile = expectedProfile
    }

    init(
        profile: PerformanceBaselineProfile,
        measurements: [PerformanceMeasurement],
        launchAndInteractivity: PerformanceLaunchAndInteractivity,
        passed: Bool
    ) {
        status = passed ? "passed" : "failed"
        self.profile = profile.rawValue
        hostModel = PerformanceBaselineProfile.currentModel
        architecture = PerformanceBaselineProfile.currentArchitecture
        self.measurements = measurements
        self.launchAndInteractivity = launchAndInteractivity
        expectedProfile = nil
    }

    static func unsupportedBaseline(
        model: String,
        architecture: String,
        expectedProfile: String? = nil
    ) -> Self {
        // An unsupported machine must produce a machine-readable non-measured
        // result, never a report that could be mistaken for a passing baseline.
        Self(
            status: "unsupported-baseline",
            profile: nil,
            hostModel: model,
            architecture: architecture,
            measurements: [],
            launchAndInteractivity: nil,
            expectedProfile: expectedProfile
        )
    }

    var statusMessage: String {
        "Unsupported performance baseline: \(architecture) / \(hostModel). "
            + "Run only on a declared §24 baseline profile."
    }

    func write(to url: URL?) throws {
        guard let url else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}
