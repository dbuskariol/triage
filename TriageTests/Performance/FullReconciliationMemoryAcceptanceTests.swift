import Darwin
import Foundation
import GRDB
import XCTest
@testable import Triage

/// A privacy-safe sidecar for the opt-in full-reconciliation measurement. It
/// deliberately contains only aggregate memory and bounded-stream metadata;
/// no vault paths, account identifiers, source content, or request data.
struct FullReconciliationMemoryReport: Codable, Equatable {
    static let currentSchemaVersion = 1
    static let unbaselinedStatus = "measured-unbaselined"

    let schemaVersion: Int
    let status: String
    let benchmarkSession: String?
    let baselineBytes: UInt64?
    let peakBytes: UInt64?
    let deltaBytes: Int64?
    let postRunBytes: UInt64?
    let pageCount: Int?
    let maximumPageSize: Int?
    let persistenceBatchCount: Int?
    let maximumPersistenceBatchSize: Int?
    let reconciliationKind: String?
    let reason: String?

    enum ValidationError: Error, Equatable {
        case unsupportedSchemaVersion(Int)
        case incorrectStatus(String)
        case missingBenchmarkSession
        case staleBenchmarkSession
        case invalidMemoryValues
        case invalidFixtureShape
        case invalidReconciliationKind
        case invalidReason
    }

    static func notMeasured(_ reason: String) -> Self {
        Self(
            schemaVersion: Self.currentSchemaVersion,
            status: "not-measured",
            benchmarkSession: nil,
            baselineBytes: nil,
            peakBytes: nil,
            deltaBytes: nil,
            postRunBytes: nil,
            pageCount: nil,
            maximumPageSize: nil,
            persistenceBatchCount: nil,
            maximumPersistenceBatchSize: nil,
            reconciliationKind: nil,
            reason: reason
        )
    }

    static func fromEnvironment() throws -> Self {
        guard let path = ProcessInfo.processInfo.environment[
            "TRIAGE_FULL_RECONCILIATION_MEMORY_RESULT_PATH"
        ] else {
            return .notMeasured("No full-reconciliation memory sidecar was requested.")
        }
        guard let expectedBenchmarkSession = ProcessInfo.processInfo.environment[
            "TRIAGE_PERFORMANCE_BENCHMARK_SESSION"
        ], !expectedBenchmarkSession.isEmpty else {
            throw ValidationError.missingBenchmarkSession
        }
        let report = try JSONDecoder().decode(
            Self.self,
            from: Data(contentsOf: URL(fileURLWithPath: path))
        )
        try report.validate(expectedBenchmarkSession: expectedBenchmarkSession)
        return report
    }

    func validate(expectedBenchmarkSession: String) throws {
        try validateIntrinsic()
        guard benchmarkSession == expectedBenchmarkSession else {
            throw ValidationError.staleBenchmarkSession
        }
    }

    private func validateIntrinsic() throws {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw ValidationError.unsupportedSchemaVersion(schemaVersion)
        }
        guard status == Self.unbaselinedStatus else {
            throw ValidationError.incorrectStatus(status)
        }
        guard let benchmarkSession, !benchmarkSession.isEmpty else {
            throw ValidationError.missingBenchmarkSession
        }
        guard let baselineBytes,
              let peakBytes,
              let deltaBytes,
              postRunBytes != nil,
              peakBytes >= baselineBytes,
              deltaBytes == Int64(clamping: peakBytes) - Int64(clamping: baselineBytes)
        else {
            throw ValidationError.invalidMemoryValues
        }
        let expectedBatchCount = (PerformanceFixtureScale.workItems + PerformanceFixtureScale.batchSize - 1)
            / PerformanceFixtureScale.batchSize
        guard pageCount == expectedBatchCount,
              maximumPageSize == PerformanceFixtureScale.batchSize,
              persistenceBatchCount == expectedBatchCount,
              maximumPersistenceBatchSize == PerformanceFixtureScale.batchSize
        else {
            throw ValidationError.invalidFixtureShape
        }
        guard reconciliationKind == "fullReconciliation" else {
            throw ValidationError.invalidReconciliationKind
        }
        guard reason == "No approved per-profile physical-footprint budget is configured." else {
            throw ValidationError.invalidReason
        }
    }

    func write(to url: URL?) throws {
        guard let url else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}

extension FullReconciliationMemoryReport {
    enum CodingKeys: String, CodingKey {
        case schemaVersion
        case status
        case benchmarkSession
        case baselineBytes
        case peakBytes
        case deltaBytes
        case postRunBytes
        case pageCount
        case maximumPageSize
        case persistenceBatchCount
        case maximumPersistenceBatchSize
        case reconciliationKind
        case reason
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decoded = Self(
            schemaVersion: try container.decode(Int.self, forKey: .schemaVersion),
            status: try container.decode(String.self, forKey: .status),
            benchmarkSession: try container.decodeIfPresent(String.self, forKey: .benchmarkSession),
            baselineBytes: try container.decodeIfPresent(UInt64.self, forKey: .baselineBytes),
            peakBytes: try container.decodeIfPresent(UInt64.self, forKey: .peakBytes),
            deltaBytes: try container.decodeIfPresent(Int64.self, forKey: .deltaBytes),
            postRunBytes: try container.decodeIfPresent(UInt64.self, forKey: .postRunBytes),
            pageCount: try container.decodeIfPresent(Int.self, forKey: .pageCount),
            maximumPageSize: try container.decodeIfPresent(Int.self, forKey: .maximumPageSize),
            persistenceBatchCount: try container.decodeIfPresent(Int.self, forKey: .persistenceBatchCount),
            maximumPersistenceBatchSize: try container.decodeIfPresent(Int.self, forKey: .maximumPersistenceBatchSize),
            reconciliationKind: try container.decodeIfPresent(String.self, forKey: .reconciliationKind),
            reason: try container.decodeIfPresent(String.self, forKey: .reason)
        )
        try decoded.validateIntrinsic()
        self = decoded
    }
}

final class FullReconciliationMemoryAcceptanceTests: XCTestCase {
    func testMemorySidecarRejectsStaleMalformedAndInconsistentValues() throws {
        let expectedBatchCount = (PerformanceFixtureScale.workItems + PerformanceFixtureScale.batchSize - 1)
            / PerformanceFixtureScale.batchSize
        let valid = FullReconciliationMemoryReport(
            schemaVersion: FullReconciliationMemoryReport.currentSchemaVersion,
            status: FullReconciliationMemoryReport.unbaselinedStatus,
            benchmarkSession: "current-session",
            baselineBytes: 100,
            peakBytes: 160,
            deltaBytes: 60,
            postRunBytes: 120,
            pageCount: expectedBatchCount,
            maximumPageSize: PerformanceFixtureScale.batchSize,
            persistenceBatchCount: expectedBatchCount,
            maximumPersistenceBatchSize: PerformanceFixtureScale.batchSize,
            reconciliationKind: "fullReconciliation",
            reason: "No approved per-profile physical-footprint budget is configured."
        )
        XCTAssertNoThrow(try valid.validate(expectedBenchmarkSession: "current-session"))
        XCTAssertThrowsError(try valid.validate(expectedBenchmarkSession: "stale-session"))
        XCTAssertThrowsError(try FullReconciliationMemoryReport(
            schemaVersion: 0,
            status: valid.status,
            benchmarkSession: valid.benchmarkSession,
            baselineBytes: valid.baselineBytes,
            peakBytes: valid.peakBytes,
            deltaBytes: valid.deltaBytes,
            postRunBytes: valid.postRunBytes,
            pageCount: valid.pageCount,
            maximumPageSize: valid.maximumPageSize,
            persistenceBatchCount: valid.persistenceBatchCount,
            maximumPersistenceBatchSize: valid.maximumPersistenceBatchSize,
            reconciliationKind: valid.reconciliationKind,
            reason: valid.reason
        ).validate(expectedBenchmarkSession: "current-session"))
        XCTAssertThrowsError(try FullReconciliationMemoryReport(
            schemaVersion: valid.schemaVersion,
            status: valid.status,
            benchmarkSession: valid.benchmarkSession,
            baselineBytes: valid.baselineBytes,
            peakBytes: valid.peakBytes,
            deltaBytes: 61,
            postRunBytes: valid.postRunBytes,
            pageCount: valid.pageCount,
            maximumPageSize: valid.maximumPageSize,
            persistenceBatchCount: valid.persistenceBatchCount,
            maximumPersistenceBatchSize: valid.maximumPersistenceBatchSize,
            reconciliationKind: valid.reconciliationKind,
            reason: valid.reason
        ).validate(expectedBenchmarkSession: "current-session"))
        XCTAssertThrowsError(try JSONDecoder().decode(
            FullReconciliationMemoryReport.self,
            from: Data("not a memory sidecar".utf8)
        ))
    }

    func testDeterministicPagedSourceRemainsBoundedDuringFullReconciliation() async throws {
        let fixture = try await PerformanceFixtureStore(generator: .init(counts: [
            .repository: 2,
            .workItem: 17,
            .timelineEvent: 0,
            .project: 0,
            .projectItem: 0,
            .discussion: 0,
            .discussionReply: 0,
            .searchableComment: 0,
            .actionableItem: 0
        ]))
        defer { Task { await fixture.close() } }
        _ = try await fixture.seed(maximumBatchSize: 4)

        let sampler = FullReconciliationMemorySampler()
        let pipeline = DeterministicPagedFullReconciliationPipeline(
            vault: fixture.vault,
            itemCount: 17,
            sourcePageSize: 5,
            persistenceBatchSize: 3,
            sampler: sampler
        )
        let operation = AccountOrganizationRefreshOperation(
            vault: fixture.vault,
            refreshPipelineFactory: { _ in
                { _, _, _, _, intent in
                    try await pipeline.run(intent: intent)
                }
            }
        )

        _ = try await operation.refresh(fullReconciliationRequest())
        let metrics = await pipeline.metrics()
        XCTAssertEqual(metrics.kind, .fullReconciliation)
        XCTAssertEqual(metrics.pageCount, 4)
        XCTAssertEqual(metrics.maximumPageSize, 5)
        XCTAssertEqual(metrics.persistenceBatchCount, 7)
        XCTAssertEqual(metrics.maximumPersistenceBatchSize, 3)
        XCTAssertEqual(metrics.persistedRecordCount, 17)
    }

    func testOptInFullReconciliationMemoryMeasurementIsUnbaselined() async throws {
        guard ProcessInfo.processInfo.environment["TRIAGE_FULL_RECONCILIATION_MEMORY_BENCHMARK"] == "1" else {
            return
        }

        let fixture = try await PerformanceFixtureStore()
        defer { Task { await fixture.close() } }
        _ = try await fixture.seed()

        let sampler = FullReconciliationMemorySampler()
        await sampler.sample()
        let pipeline = DeterministicPagedFullReconciliationPipeline(
            vault: fixture.vault,
            itemCount: PerformanceFixtureScale.workItems,
            sourcePageSize: PerformanceFixtureScale.batchSize,
            persistenceBatchSize: PerformanceFixtureScale.batchSize,
            sampler: sampler
        )
        let operation = AccountOrganizationRefreshOperation(
            vault: fixture.vault,
            refreshPipelineFactory: { _ in
                { _, _, _, _, intent in
                    try await pipeline.run(intent: intent)
                }
            }
        )

        _ = try await operation.refresh(fullReconciliationRequest())
        let metrics = await pipeline.metrics()
        guard let benchmarkSession = ProcessInfo.processInfo.environment[
            "TRIAGE_PERFORMANCE_BENCHMARK_SESSION"
        ], !benchmarkSession.isEmpty else {
            throw FullReconciliationMemoryReport.ValidationError.missingBenchmarkSession
        }
        let report = await sampler.report(metrics: metrics, benchmarkSession: benchmarkSession)
        XCTAssertEqual(report.status, "measured-unbaselined")
        XCTAssertEqual(report.reconciliationKind, "fullReconciliation")
        XCTAssertEqual(report.pageCount, metrics.pageCount)
        XCTAssertEqual(report.maximumPageSize, metrics.maximumPageSize)
        try report.write(to: ProcessInfo.processInfo.environment[
            "TRIAGE_FULL_RECONCILIATION_MEMORY_RESULT_PATH"
        ].map(URL.init(fileURLWithPath:)))
    }
}

private actor FullReconciliationMemorySampler {
    private var baselineBytes: UInt64?
    private var peakBytes: UInt64 = 0

    func sample() {
        let footprint = Self.physicalFootprint()
        if baselineBytes == nil {
            baselineBytes = footprint
        }
        peakBytes = max(peakBytes, footprint)
    }

    func report(
        metrics: DeterministicPagedFullReconciliationPipeline.Metrics,
        benchmarkSession: String
    ) -> FullReconciliationMemoryReport {
        sample()
        let baseline = baselineBytes ?? peakBytes
        return FullReconciliationMemoryReport(
            schemaVersion: FullReconciliationMemoryReport.currentSchemaVersion,
            status: FullReconciliationMemoryReport.unbaselinedStatus,
            benchmarkSession: benchmarkSession,
            baselineBytes: baseline,
            peakBytes: peakBytes,
            deltaBytes: Int64(clamping: peakBytes) - Int64(clamping: baseline),
            postRunBytes: Self.physicalFootprint(),
            pageCount: metrics.pageCount,
            maximumPageSize: metrics.maximumPageSize,
            persistenceBatchCount: metrics.persistenceBatchCount,
            maximumPersistenceBatchSize: metrics.maximumPersistenceBatchSize,
            reconciliationKind: "fullReconciliation",
            reason: "No approved per-profile physical-footprint budget is configured."
        )
    }

    private static func physicalFootprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : 0
    }
}

private func fullReconciliationRequest() -> AccountOrganizationRefreshRequest {
    let accountID = AccountID(rawValue: "00000000-0000-4000-8000-000000000501")!
    let organizationID = OrganizationID(rawValue: "performance-organization")!
    let scope = SynchronizationScope(
        accountID: accountID,
        organizationID: organizationID,
        credentialRevision: CredentialRevision(rawValue: "performance-revision")!,
        capabilityRevision: CapabilityRevision(rawValue: "performance-capability")!
    )
    return AccountOrganizationRefreshRequest(
        synchronizationScope: scope,
        scope: AccountOrganizationScope(accountID: accountID, organizationID: organizationID),
        token: AccountOrganizationRequestToken(rawValue: 1),
        priority: .fullReconciliation,
        requestPriority: .fullReconciliation,
        reconciliationIntent: .fullReconciliation
    )
}

private actor DeterministicPagedFullReconciliationPipeline {
    struct Metrics: Equatable, Sendable {
        let kind: SynchronizationReconciliationIntent
        let pageCount: Int
        let maximumPageSize: Int
        let persistenceBatchCount: Int
        let maximumPersistenceBatchSize: Int
        let persistedRecordCount: Int
    }

    private let vault: AccountVault
    private let itemCount: Int
    private let sourcePageSize: Int
    private let persistenceBatchSize: Int
    private let sampler: FullReconciliationMemorySampler
    private var currentMetrics = Metrics(
        kind: .incremental,
        pageCount: 0,
        maximumPageSize: 0,
        persistenceBatchCount: 0,
        maximumPersistenceBatchSize: 0,
        persistedRecordCount: 0
    )

    init(
        vault: AccountVault,
        itemCount: Int,
        sourcePageSize: Int,
        persistenceBatchSize: Int,
        sampler: FullReconciliationMemorySampler
    ) {
        self.vault = vault
        self.itemCount = itemCount
        self.sourcePageSize = sourcePageSize
        self.persistenceBatchSize = persistenceBatchSize
        self.sampler = sampler
    }

    func run(intent: SynchronizationReconciliationIntent) async throws {
        guard intent == .fullReconciliation else {
            throw CancellationError()
        }
        var offset = 0
        while offset < itemCount {
            let upperBound = min(offset + sourcePageSize, itemCount)
            // This is the fake source's entire retained page. It is discarded
            // before the next source read and never accumulated across pages.
            let page = Array(offset..<upperBound)
            currentMetrics = Metrics(
                kind: intent,
                pageCount: currentMetrics.pageCount + 1,
                maximumPageSize: max(currentMetrics.maximumPageSize, page.count),
                persistenceBatchCount: currentMetrics.persistenceBatchCount,
                maximumPersistenceBatchSize: currentMetrics.maximumPersistenceBatchSize,
                persistedRecordCount: currentMetrics.persistedRecordCount
            )
            await sampler.sample()

            var batchStart = 0
            while batchStart < page.count {
                let batch = Array(page[batchStart..<min(batchStart + persistenceBatchSize, page.count)])
                try await vault.write { database in
                    for ordinal in batch {
                        try database.execute(
                            sql: "UPDATE work_items SET updated_at_ms = updated_at_ms + 1 WHERE id = ?",
                            arguments: ["work-item-\(ordinal)"]
                        )
                    }
                }
                currentMetrics = Metrics(
                    kind: intent,
                    pageCount: currentMetrics.pageCount,
                    maximumPageSize: currentMetrics.maximumPageSize,
                    persistenceBatchCount: currentMetrics.persistenceBatchCount + 1,
                    maximumPersistenceBatchSize: max(currentMetrics.maximumPersistenceBatchSize, batch.count),
                    persistedRecordCount: currentMetrics.persistedRecordCount + batch.count
                )
                await sampler.sample()
                batchStart += batch.count
            }
            offset = upperBound
        }
    }

    func metrics() -> Metrics { currentMetrics }
}
