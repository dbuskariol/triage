import Darwin
import Foundation
import XCTest
@testable import Triage

final class PerformanceBudgetTests: XCTestCase {
    func testLaunchMeasurementRejectsInvalidSchemaAndSamples() throws {
        let samples = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11].map(Double.init)
        let valid = try PerformanceLaunchMeasurement(
            benchmarkSession: "current-session",
            warmupSampleCount: PerformanceBenchmarkSampling.warmupSampleCount,
            samplesMilliseconds: samples,
            budgetMilliseconds: 1_000,
            p95BudgetMilliseconds: 1_200
        )
        XCTAssertEqual(valid.medianMilliseconds, 6)
        XCTAssertEqual(valid.p95Milliseconds, 11)

        XCTAssertThrowsError(
            try PerformanceLaunchMeasurement(
                benchmarkSession: "",
                warmupSampleCount: PerformanceBenchmarkSampling.warmupSampleCount,
                samplesMilliseconds: samples,
                budgetMilliseconds: 1_000,
                p95BudgetMilliseconds: 1_200
            )
        )

        XCTAssertThrowsError(
            try PerformanceLaunchMeasurement(
                schemaVersion: 0,
                benchmarkSession: "current-session",
                warmupSampleCount: PerformanceBenchmarkSampling.warmupSampleCount,
                samplesMilliseconds: samples,
                medianMilliseconds: 6,
                p95Milliseconds: 11,
                budgetMilliseconds: 1_000,
                p95BudgetMilliseconds: 1_200
            )
        )
        XCTAssertThrowsError(
            try PerformanceLaunchMeasurement(
                benchmarkSession: "current-session",
                warmupSampleCount: 2,
                samplesMilliseconds: samples,
                budgetMilliseconds: 1_000,
                p95BudgetMilliseconds: 1_200
            )
        )
        XCTAssertThrowsError(
            try PerformanceLaunchMeasurement(
                benchmarkSession: "current-session",
                warmupSampleCount: PerformanceBenchmarkSampling.warmupSampleCount,
                samplesMilliseconds: Array(samples.dropLast()),
                budgetMilliseconds: 1_000,
                p95BudgetMilliseconds: 1_200
            )
        )
        XCTAssertThrowsError(
            try PerformanceLaunchMeasurement(
                schemaVersion: PerformanceLaunchMeasurement.currentSchemaVersion,
                benchmarkSession: "current-session",
                warmupSampleCount: PerformanceBenchmarkSampling.warmupSampleCount,
                samplesMilliseconds: samples,
                medianMilliseconds: 7,
                p95Milliseconds: 11,
                budgetMilliseconds: 1_000,
                p95BudgetMilliseconds: 1_200
            )
        )
        XCTAssertThrowsError(
            try PerformanceLaunchMeasurement(
                benchmarkSession: "current-session",
                warmupSampleCount: PerformanceBenchmarkSampling.warmupSampleCount,
                samplesMilliseconds: Array(samples.dropLast()) + [.infinity],
                budgetMilliseconds: 1_000,
                p95BudgetMilliseconds: 1_200
            )
        )
        XCTAssertThrowsError(
            try PerformanceLaunchMeasurement(
                benchmarkSession: "current-session",
                warmupSampleCount: PerformanceBenchmarkSampling.warmupSampleCount,
                samplesMilliseconds: samples,
                budgetMilliseconds: 1_001,
                p95BudgetMilliseconds: 1_201.2
            )
        )
        XCTAssertThrowsError(
            try JSONDecoder().decode(
                PerformanceLaunchMeasurement.self,
                from: Data("not a launch report".utf8)
            )
        )
        XCTAssertThrowsError(try valid.validate(expectedBenchmarkSession: "stale-session"))
        XCTAssertThrowsError(
            try JSONDecoder().decode(
                PerformanceLaunchMeasurement.self,
                from: Data(
                    """
                    {"schemaVersion":0,"warmupSampleCount":3,"samplesMilliseconds":[1,2,3,4,5,6,7,8,9,10,11],"medianMilliseconds":6,"p95Milliseconds":11,"budgetMilliseconds":1000,"p95BudgetMilliseconds":1200}
                    """.utf8
                )
            )
        )
    }

    func testScrollMeasurementRejectsStaleMalformedAndInconsistentSidecars() throws {
        let samples = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11].map(Double.init)
        let metric = PerformanceScrollMeasurement.SystemMetric(
            identifier: PerformanceScrollMeasurement.expectedMetricIdentifiers[0],
            unit: "ms",
            count: PerformanceBenchmarkSampling.measuredSampleCount,
            minimum: 1,
            median: 6,
            p95: 11,
            maximum: 11
        )
        let hitchMetric = PerformanceScrollMeasurement.SystemMetric(
            identifier: PerformanceScrollMeasurement.expectedMetricIdentifiers[1],
            unit: "ms",
            count: PerformanceBenchmarkSampling.measuredSampleCount,
            minimum: 0,
            median: 0,
            p95: 1,
            maximum: 1
        )
        let valid = PerformanceScrollMeasurement(
            schemaVersion: PerformanceScrollMeasurement.currentSchemaVersion,
            status: "measured-unbaselined",
            benchmarkSession: "current-session",
            fixtureItemCount: 10_000,
            warmupSampleCount: PerformanceBenchmarkSampling.warmupSampleCount,
            samplesGesturePairMilliseconds: samples,
            gesturesPerIteration: 2,
            medianGesturePairMilliseconds: 6,
            p95GesturePairMilliseconds: 11,
            requestedMetricIdentifiers: PerformanceScrollMeasurement.expectedMetricIdentifiers,
            systemMetrics: [metric, hitchMetric]
        )
        XCTAssertNoThrow(try valid.validate(expectedBenchmarkSession: "current-session"))

        XCTAssertThrowsError(try valid.validate(expectedBenchmarkSession: "stale-session"))
        XCTAssertThrowsError(try PerformanceScrollMeasurement(
            schemaVersion: 0,
            status: valid.status,
            benchmarkSession: valid.benchmarkSession,
            fixtureItemCount: valid.fixtureItemCount,
            warmupSampleCount: valid.warmupSampleCount,
            samplesGesturePairMilliseconds: valid.samplesGesturePairMilliseconds,
            gesturesPerIteration: valid.gesturesPerIteration,
            medianGesturePairMilliseconds: valid.medianGesturePairMilliseconds,
            p95GesturePairMilliseconds: valid.p95GesturePairMilliseconds,
            requestedMetricIdentifiers: valid.requestedMetricIdentifiers,
            systemMetrics: valid.systemMetrics
        ).validate(expectedBenchmarkSession: "current-session"))
        XCTAssertThrowsError(try PerformanceScrollMeasurement(
            schemaVersion: valid.schemaVersion,
            status: valid.status,
            benchmarkSession: valid.benchmarkSession,
            fixtureItemCount: valid.fixtureItemCount,
            warmupSampleCount: valid.warmupSampleCount,
            samplesGesturePairMilliseconds: valid.samplesGesturePairMilliseconds,
            gesturesPerIteration: valid.gesturesPerIteration,
            medianGesturePairMilliseconds: 7,
            p95GesturePairMilliseconds: valid.p95GesturePairMilliseconds,
            requestedMetricIdentifiers: valid.requestedMetricIdentifiers,
            systemMetrics: valid.systemMetrics
        ).validate(expectedBenchmarkSession: "current-session"))
        XCTAssertThrowsError(try JSONDecoder().decode(
            PerformanceScrollMeasurement.self,
            from: Data("not a scrolling report".utf8)
        ))
    }

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

        // Decode and validate all requested sidecars before costly fixture
        // setup. A nonempty stale or custom file is never evidence of a run.
        let launchAndInteractivity = try PerformanceLaunchAndInteractivity.fromEnvironment()
        let fullReconciliationMemory = try FullReconciliationMemoryReport.fromEnvironment()
        let scrollingAndHitch = try PerformanceScrollingAndHitch.fromEnvironment()

        let fixture = try await PerformanceFixtureStore()
        do {
            let seedMetrics = try await fixture.seed()
            XCTAssertGreaterThan(seedMetrics.batchCount, 0)
            XCTAssertLessThanOrEqual(
                seedMetrics.largestBatchSize,
                PerformanceFixtureScale.batchSize,
                "The production-scale fixture must be streamed in bounded seed batches."
            )
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
            // Memory sampling currently has no approved per-profile ceiling.
            // Preserve its measured-unbaselined status in the report, but do
            // not allow that host to produce a green aggregate benchmark.
            let hasUnbaselinedFullReconciliationMemory = fullReconciliationMemory.status
                == "measured-unbaselined"
            let report = PerformanceBenchmarkReport(
                profile: profile,
                fixture: .expected(seedMetrics: seedMetrics),
                measurements: measurements,
                launchAndInteractivity: launchAndInteractivity,
                fullReconciliationMemory: fullReconciliationMemory,
                scrollingAndHitch: scrollingAndHitch,
                passed: passesDatabaseBudgets
                    && passesLaunchBudget
                    && !hasUnbaselinedFullReconciliationMemory
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

enum PerformanceLaunchAndInteractivity: Codable {
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
            throw PerformanceLaunchMeasurementError.missingResult
        }
        guard let benchmarkSession = ProcessInfo.processInfo.environment[
            "TRIAGE_PERFORMANCE_BENCHMARK_SESSION"
        ], !benchmarkSession.isEmpty else {
            throw PerformanceLaunchMeasurementError.missingBenchmarkSession
        }
        let measurement = try JSONDecoder().decode(
            PerformanceLaunchMeasurement.self,
            from: Data(contentsOf: url)
        )
        try measurement.validate(expectedBenchmarkSession: benchmarkSession)
        return .measured(measurement)
    }
}

enum PerformanceLaunchMeasurementError: Error, Equatable {
    case unsupportedSchemaVersion(Int)
    case missingBenchmarkSession
    case staleBenchmarkSession
    case missingResult
    case incorrectWarmupCount(Int)
    case incorrectSampleCount(Int)
    case nonFiniteValue
    case negativeSample
    case invalidBudget
    case unexpectedBudget
    case inconsistentMedian
    case inconsistentP95
    case inconsistentP95Budget
}

struct PerformanceLaunchMeasurement: Codable, Equatable {
    static let currentSchemaVersion = 1
    static let expectedBudgetMilliseconds = 1_000.0
    static let expectedP95BudgetMilliseconds = 1_200.0

    let schemaVersion: Int
    let benchmarkSession: String
    let warmupSampleCount: Int
    let samplesMilliseconds: [Double]
    let medianMilliseconds: Double
    let p95Milliseconds: Double
    let budgetMilliseconds: Double
    let p95BudgetMilliseconds: Double

    init(
        benchmarkSession: String,
        warmupSampleCount: Int,
        samplesMilliseconds: [Double],
        budgetMilliseconds: Double,
        p95BudgetMilliseconds: Double
    ) throws {
        guard samplesMilliseconds.count == PerformanceBenchmarkSampling.measuredSampleCount else {
            throw PerformanceLaunchMeasurementError.incorrectSampleCount(samplesMilliseconds.count)
        }
        guard samplesMilliseconds.allSatisfy(\.isFinite) else {
            throw PerformanceLaunchMeasurementError.nonFiniteValue
        }
        let sorted = samplesMilliseconds.sorted()
        try self.init(
            schemaVersion: Self.currentSchemaVersion,
            benchmarkSession: benchmarkSession,
            warmupSampleCount: warmupSampleCount,
            samplesMilliseconds: samplesMilliseconds,
            medianMilliseconds: PerformanceBenchmarkSampling.percentile(sorted, fraction: 0.5),
            p95Milliseconds: PerformanceBenchmarkSampling.percentile(sorted, fraction: 0.95),
            budgetMilliseconds: budgetMilliseconds,
            p95BudgetMilliseconds: p95BudgetMilliseconds
        )
    }

    init(
        schemaVersion: Int,
        benchmarkSession: String,
        warmupSampleCount: Int,
        samplesMilliseconds: [Double],
        medianMilliseconds: Double,
        p95Milliseconds: Double,
        budgetMilliseconds: Double,
        p95BudgetMilliseconds: Double
    ) throws {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw PerformanceLaunchMeasurementError.unsupportedSchemaVersion(schemaVersion)
        }
        guard !benchmarkSession.isEmpty else {
            throw PerformanceLaunchMeasurementError.missingBenchmarkSession
        }
        guard warmupSampleCount == PerformanceBenchmarkSampling.warmupSampleCount else {
            throw PerformanceLaunchMeasurementError.incorrectWarmupCount(warmupSampleCount)
        }
        guard samplesMilliseconds.count == PerformanceBenchmarkSampling.measuredSampleCount else {
            throw PerformanceLaunchMeasurementError.incorrectSampleCount(samplesMilliseconds.count)
        }
        guard samplesMilliseconds.allSatisfy(\.isFinite),
              medianMilliseconds.isFinite,
              p95Milliseconds.isFinite,
              budgetMilliseconds.isFinite,
              p95BudgetMilliseconds.isFinite
        else {
            throw PerformanceLaunchMeasurementError.nonFiniteValue
        }
        guard samplesMilliseconds.allSatisfy({ $0 >= 0 }) else {
            throw PerformanceLaunchMeasurementError.negativeSample
        }
        guard budgetMilliseconds > 0 else {
            throw PerformanceLaunchMeasurementError.invalidBudget
        }
        guard budgetMilliseconds == Self.expectedBudgetMilliseconds,
              p95BudgetMilliseconds == Self.expectedP95BudgetMilliseconds
        else {
            throw PerformanceLaunchMeasurementError.unexpectedBudget
        }
        guard p95BudgetMilliseconds == budgetMilliseconds * 1.2 else {
            throw PerformanceLaunchMeasurementError.inconsistentP95Budget
        }
        let sorted = samplesMilliseconds.sorted()
        guard medianMilliseconds == PerformanceBenchmarkSampling.percentile(sorted, fraction: 0.5) else {
            throw PerformanceLaunchMeasurementError.inconsistentMedian
        }
        guard p95Milliseconds == PerformanceBenchmarkSampling.percentile(sorted, fraction: 0.95) else {
            throw PerformanceLaunchMeasurementError.inconsistentP95
        }

        self.schemaVersion = schemaVersion
        self.benchmarkSession = benchmarkSession
        self.warmupSampleCount = warmupSampleCount
        self.samplesMilliseconds = samplesMilliseconds
        self.medianMilliseconds = medianMilliseconds
        self.p95Milliseconds = p95Milliseconds
        self.budgetMilliseconds = budgetMilliseconds
        self.p95BudgetMilliseconds = p95BudgetMilliseconds
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            schemaVersion: container.decode(Int.self, forKey: .schemaVersion),
            benchmarkSession: container.decode(String.self, forKey: .benchmarkSession),
            warmupSampleCount: container.decode(Int.self, forKey: .warmupSampleCount),
            samplesMilliseconds: container.decode([Double].self, forKey: .samplesMilliseconds),
            medianMilliseconds: container.decode(Double.self, forKey: .medianMilliseconds),
            p95Milliseconds: container.decode(Double.self, forKey: .p95Milliseconds),
            budgetMilliseconds: container.decode(Double.self, forKey: .budgetMilliseconds),
            p95BudgetMilliseconds: container.decode(Double.self, forKey: .p95BudgetMilliseconds)
        )
    }

    func validate(expectedBenchmarkSession: String) throws {
        guard benchmarkSession == expectedBenchmarkSession else {
            throw PerformanceLaunchMeasurementError.staleBenchmarkSession
        }
    }
}

enum PerformanceScrollingAndHitch: Codable {
    case measured(PerformanceScrollMeasurement)
    case notMeasured(String)

    enum CodingKeys: String, CodingKey { case status, reason, scrolling }
    enum Status: String, Codable { case measured, notMeasured }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .measured(scrolling):
            try container.encode(Status.measured, forKey: .status)
            try container.encode(scrolling, forKey: .scrolling)
        case let .notMeasured(reason):
            try container.encode(Status.notMeasured, forKey: .status)
            try container.encode(reason, forKey: .reason)
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Status.self, forKey: .status) {
        case .measured:
            self = .measured(try container.decode(PerformanceScrollMeasurement.self, forKey: .scrolling))
        case .notMeasured:
            self = .notMeasured(try container.decode(String.self, forKey: .reason))
        }
    }

    static func fromEnvironment() throws -> Self {
        guard let path = ProcessInfo.processInfo.environment[
            "TRIAGE_PERFORMANCE_UI_SCROLL_RESULT_PATH"
        ] else {
            return .notMeasured("Requires the opt-in 10k native scrolling benchmark.")
        }
        guard let benchmarkSession = ProcessInfo.processInfo.environment[
            "TRIAGE_PERFORMANCE_BENCHMARK_SESSION"
        ], !benchmarkSession.isEmpty else {
            throw PerformanceScrollMeasurementError.missingBenchmarkSession
        }
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw PerformanceScrollMeasurementError.missingResult
        }
        let measurement = try JSONDecoder().decode(
            PerformanceScrollMeasurement.self,
            from: Data(contentsOf: url)
        )
        try measurement.validate(expectedBenchmarkSession: benchmarkSession)
        return .measured(measurement)
    }
}

enum PerformanceScrollMeasurementError: Error, Equatable {
    case unsupportedSchemaVersion(Int)
    case incorrectStatus(String)
    case missingBenchmarkSession
    case staleBenchmarkSession
    case missingResult
    case incorrectFixtureItemCount(Int)
    case incorrectWarmupCount(Int)
    case incorrectSampleCount(Int)
    case nonFiniteValue
    case negativeSample
    case incorrectGestureCount(Int)
    case inconsistentMedian
    case inconsistentP95
    case unexpectedMetricIdentifiers
    case incorrectSystemMetricCount
    case invalidSystemMetric
}

struct PerformanceScrollMeasurement: Codable, Equatable {
    static let currentSchemaVersion = 1
    static let expectedFixtureItemCount = 10_000
    static let expectedGesturePairsPerSample = 2
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
    let systemMetrics: [SystemMetric]

    struct SystemMetric: Codable, Equatable {
        let identifier: String
        let unit: String
        let count: Int
        let minimum: Double
        let median: Double
        let p95: Double
        let maximum: Double

        func validate() throws {
            guard !identifier.isEmpty,
                  !unit.isEmpty,
                  count == PerformanceBenchmarkSampling.measuredSampleCount,
                  minimum.isFinite,
                  median.isFinite,
                  p95.isFinite,
                  maximum.isFinite,
                  minimum >= 0,
                  median >= minimum,
                  p95 >= median,
                  maximum >= p95
            else {
                throw PerformanceScrollMeasurementError.invalidSystemMetric
            }
        }
    }

    func validate(expectedBenchmarkSession: String) throws {
        try validateIntrinsic()
        guard benchmarkSession == expectedBenchmarkSession else {
            throw PerformanceScrollMeasurementError.staleBenchmarkSession
        }
    }

    private func validateIntrinsic() throws {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw PerformanceScrollMeasurementError.unsupportedSchemaVersion(schemaVersion)
        }
        guard status == "measured-unbaselined" else {
            throw PerformanceScrollMeasurementError.incorrectStatus(status)
        }
        guard !benchmarkSession.isEmpty else {
            throw PerformanceScrollMeasurementError.missingBenchmarkSession
        }
        guard fixtureItemCount == Self.expectedFixtureItemCount else {
            throw PerformanceScrollMeasurementError.incorrectFixtureItemCount(fixtureItemCount)
        }
        guard warmupSampleCount == PerformanceBenchmarkSampling.warmupSampleCount else {
            throw PerformanceScrollMeasurementError.incorrectWarmupCount(warmupSampleCount)
        }
        guard samplesGesturePairMilliseconds.count == PerformanceBenchmarkSampling.measuredSampleCount else {
            throw PerformanceScrollMeasurementError.incorrectSampleCount(samplesGesturePairMilliseconds.count)
        }
        guard samplesGesturePairMilliseconds.allSatisfy(\.isFinite),
              medianGesturePairMilliseconds.isFinite,
              p95GesturePairMilliseconds.isFinite
        else {
            throw PerformanceScrollMeasurementError.nonFiniteValue
        }
        guard samplesGesturePairMilliseconds.allSatisfy({ $0 >= 0 }) else {
            throw PerformanceScrollMeasurementError.negativeSample
        }
        guard gesturesPerIteration == Self.expectedGesturePairsPerSample else {
            throw PerformanceScrollMeasurementError.incorrectGestureCount(gesturesPerIteration)
        }
        let sorted = samplesGesturePairMilliseconds.sorted()
        guard medianGesturePairMilliseconds == PerformanceBenchmarkSampling.percentile(sorted, fraction: 0.5) else {
            throw PerformanceScrollMeasurementError.inconsistentMedian
        }
        guard p95GesturePairMilliseconds == PerformanceBenchmarkSampling.percentile(sorted, fraction: 0.95) else {
            throw PerformanceScrollMeasurementError.inconsistentP95
        }
        guard requestedMetricIdentifiers == Self.expectedMetricIdentifiers else {
            throw PerformanceScrollMeasurementError.unexpectedMetricIdentifiers
        }
        guard systemMetrics.count == Self.expectedMetricIdentifiers.count,
              systemMetrics.map(\.identifier) == Self.expectedMetricIdentifiers
        else {
            throw PerformanceScrollMeasurementError.incorrectSystemMetricCount
        }
        try systemMetrics.forEach { try $0.validate() }
    }
}

extension PerformanceScrollMeasurement {
    enum CodingKeys: String, CodingKey {
        case schemaVersion
        case status
        case benchmarkSession
        case fixtureItemCount
        case warmupSampleCount
        case samplesGesturePairMilliseconds
        case gesturesPerIteration
        case medianGesturePairMilliseconds
        case p95GesturePairMilliseconds
        case requestedMetricIdentifiers
        case systemMetrics
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decoded = Self(
            schemaVersion: try container.decode(Int.self, forKey: .schemaVersion),
            status: try container.decode(String.self, forKey: .status),
            benchmarkSession: try container.decode(String.self, forKey: .benchmarkSession),
            fixtureItemCount: try container.decode(Int.self, forKey: .fixtureItemCount),
            warmupSampleCount: try container.decode(Int.self, forKey: .warmupSampleCount),
            samplesGesturePairMilliseconds: try container.decode([Double].self, forKey: .samplesGesturePairMilliseconds),
            gesturesPerIteration: try container.decode(Int.self, forKey: .gesturesPerIteration),
            medianGesturePairMilliseconds: try container.decode(Double.self, forKey: .medianGesturePairMilliseconds),
            p95GesturePairMilliseconds: try container.decode(Double.self, forKey: .p95GesturePairMilliseconds),
            requestedMetricIdentifiers: try container.decode([String].self, forKey: .requestedMetricIdentifiers),
            systemMetrics: try container.decode([SystemMetric].self, forKey: .systemMetrics)
        )
        try decoded.validateIntrinsic()
        self = decoded
    }
}

private struct PerformanceBenchmarkReport: Codable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let status: String
    let profile: String?
    let hostModel: String
    let architecture: String
    let fixture: PerformanceFixtureReportMetadata
    let measurements: [PerformanceMeasurement]
    let launchAndInteractivity: PerformanceLaunchAndInteractivity?
    let fullReconciliationMemory: FullReconciliationMemoryReport?
    let scrollingAndHitch: PerformanceScrollingAndHitch?
    let expectedProfile: String?

    private init(
        status: String,
        profile: String?,
        hostModel: String,
        architecture: String,
        fixture: PerformanceFixtureReportMetadata,
        measurements: [PerformanceMeasurement],
        launchAndInteractivity: PerformanceLaunchAndInteractivity?,
        fullReconciliationMemory: FullReconciliationMemoryReport?,
        scrollingAndHitch: PerformanceScrollingAndHitch?,
        expectedProfile: String?
    ) {
        schemaVersion = Self.currentSchemaVersion
        self.status = status
        self.profile = profile
        self.hostModel = hostModel
        self.architecture = architecture
        self.fixture = fixture
        self.measurements = measurements
        self.launchAndInteractivity = launchAndInteractivity
        self.fullReconciliationMemory = fullReconciliationMemory
        self.scrollingAndHitch = scrollingAndHitch
        self.expectedProfile = expectedProfile
    }

    init(
        profile: PerformanceBaselineProfile,
        fixture: PerformanceFixtureReportMetadata,
        measurements: [PerformanceMeasurement],
        launchAndInteractivity: PerformanceLaunchAndInteractivity,
        fullReconciliationMemory: FullReconciliationMemoryReport,
        scrollingAndHitch: PerformanceScrollingAndHitch,
        passed: Bool
    ) {
        schemaVersion = Self.currentSchemaVersion
        status = passed ? "passed" : "failed"
        self.profile = profile.rawValue
        hostModel = PerformanceBaselineProfile.currentModel
        architecture = PerformanceBaselineProfile.currentArchitecture
        self.fixture = fixture
        self.measurements = measurements
        self.launchAndInteractivity = launchAndInteractivity
        self.fullReconciliationMemory = fullReconciliationMemory
        self.scrollingAndHitch = scrollingAndHitch
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
            fixture: .expected(),
            measurements: [],
            launchAndInteractivity: nil,
            fullReconciliationMemory: .notMeasured(
                "A full-reconciliation memory benchmark was not run for this unsupported baseline."
            ),
            scrollingAndHitch: .notMeasured(
                "The 10k native scrolling benchmark was not run for this unsupported baseline."
            ),
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
